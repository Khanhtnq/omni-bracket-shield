// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { MockERC20 } from "../origin/MockERC20.sol";
import { OmniPricePool } from "../origin/OmniPricePool.sol";
import {
    OmniConstants,
    PositionStatus,
    ArmedPositionData,
    SettledEventData,
    IOmniBracketCallback
} from "../interfaces/IOmniBracketTypes.sol";

/**
 * @title OmniBracketVault
 * @notice Destination callback contract on Base Sepolia (84532) / Unichain Sepolia (1301) that
 *         custodies non-custodial OCO Stop-Loss / Trailing-Stop / Take-Profit / Cross-Pool Arb
 *         positions and settles them upon authenticated Reactive Omni callbacks.
 * @dev Strictly uses `block.timestamp` (never `block.number`) for all expirations, cooldowns, and
 *      end-to-end loop latency measurements per Base Sepolia 200ms Denim block rules.
 */
contract OmniBracketVault is AbstractCallback, IOmniBracketCallback {
    struct BracketPosition {
        address owner;
        bytes32 pairId;
        bool isBaseToQuote;
        PositionStatus status;
        uint256 amountIn;
        uint256 entryPriceE18;
        uint256 hardStopPriceE18;
        uint256 takeProfitPriceE18;
        uint16 trailingStopBps;
        uint16 maxDislocationBps;
        uint16 maxSlippageBps;
        bool enableCrossPoolArb;
        uint64 cooldownSec;
        uint64 createdAt;
        uint64 expiresAt;
        uint64 lastAttemptAt;
        uint64 settledAt;
        uint8 deferralCount;
        uint256 amountOut;
        uint256 lastLoopLatencySec;
    }

    struct OrderParams {
        bool isBaseToQuote;
        uint256 amountIn;
        uint256 hardStopPriceE18;
        uint256 takeProfitPriceE18;
        uint16 trailingStopBps;
        uint16 maxDislocationBps;
        uint16 maxSlippageBps;
        bool enableCrossPoolArb;
        uint64 cooldownSec;
        uint64 ttlSeconds;
    }

    uint256 public constant MIN_ORDER_AMOUNT = 1e15;
    uint64 public constant MIN_COOLDOWN_SEC = 2;
    uint16 public constant MIN_SLIPPAGE_BPS = 35;
    uint8 public constant MAX_DEFERRAL_RETRIES = 5;

    address public immutable owner;
    MockERC20 public immutable baseToken;
    MockERC20 public immutable quoteToken;
    OmniPricePool public immutable pool;
    bytes32 public immutable pairId;

    uint256 public nextPositionId = 1;
    uint256 public totalSettledCount;
    uint256 public totalDeferredCount;
    uint256 public cumulativeLatencySec;
    uint256 public minLoopLatencySec = type(uint256).max;
    uint256 public maxLoopLatencySec;

    mapping(uint256 => BracketPosition) public positions;

    event PositionArmed(
        uint256 indexed positionId,
        address indexed owner,
        bytes32 indexed pairId,
        ArmedPositionData config
    );

    event PositionCancelled(uint256 indexed positionId, address indexed owner);

    event BracketSettled(
        uint256 indexed positionId,
        address indexed owner,
        SettledEventData settlement
    );

    event SettlementDeferred(
        uint256 indexed positionId,
        uint8 triggerKind,
        uint256 quotedOut,
        uint256 minRequiredOut,
        uint256 deferredAtTimestamp
    );

    error InvalidOrderConfiguration();
    error NotPositionOwner();
    error PositionNotActive();
    error PositionNotExpired();
    error ERC20TransferFailed();
    error OnlyVaultOwner();
    error InvalidWithdrawal();

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert OnlyVaultOwner();
    }

    constructor(
        IPayable callbackProxy_,
        address callbackSender_,
        address baseToken_,
        address quoteToken_,
        address pool_,
        bytes32 pairId_
    ) payable AbstractCallback(callbackProxy_, callbackSender_) {
        owner = msg.sender;
        baseToken = MockERC20(baseToken_);
        quoteToken = MockERC20(quoteToken_);
        pool = OmniPricePool(pool_);
        pairId = pairId_;

        baseToken.approve(pool_, type(uint256).max);
        quoteToken.approve(pool_, type(uint256).max);
    }

    /**
     * @notice Arms an automated bracket / trailing-stop / cross-pool arb order using timestamp deadlines.
     */
    function openBracketPosition(OrderParams calldata p_) external returns (uint256 positionId) {
        if (p_.amountIn < MIN_ORDER_AMOUNT) revert InvalidOrderConfiguration();
        if (p_.cooldownSec < MIN_COOLDOWN_SEC) revert InvalidOrderConfiguration();
        if (
            p_.maxSlippageBps < MIN_SLIPPAGE_BPS ||
            p_.maxSlippageBps <= pool.SWAP_FEE_BPS() ||
            p_.maxSlippageBps > 5_000
        ) {
            revert InvalidOrderConfiguration();
        }
        if (p_.trailingStopBps >= OmniConstants.BPS_DENOMINATOR) revert InvalidOrderConfiguration();
        if (
            p_.hardStopPriceE18 == 0 &&
            p_.takeProfitPriceE18 == 0 &&
            p_.trailingStopBps == 0 &&
            !p_.enableCrossPoolArb
        ) {
            revert InvalidOrderConfiguration();
        }

        uint256 spot = pool.spotPriceE18();
        if (spot == 0) revert InvalidOrderConfiguration();

        if (p_.isBaseToQuote) {
            if (p_.hardStopPriceE18 != 0 && p_.hardStopPriceE18 >= spot) revert InvalidOrderConfiguration();
            if (p_.takeProfitPriceE18 != 0 && p_.takeProfitPriceE18 <= spot) revert InvalidOrderConfiguration();
            if (!baseToken.transferFrom(msg.sender, address(this), p_.amountIn)) revert ERC20TransferFailed();
        } else {
            if (p_.hardStopPriceE18 != 0 && p_.hardStopPriceE18 <= spot) revert InvalidOrderConfiguration();
            if (p_.takeProfitPriceE18 != 0 && p_.takeProfitPriceE18 >= spot) revert InvalidOrderConfiguration();
            if (!quoteToken.transferFrom(msg.sender, address(this), p_.amountIn)) revert ERC20TransferFailed();
        }

        uint64 nowTs = _toUint64(block.timestamp);
        uint64 expiresAt = p_.ttlSeconds == 0 ? 0 : nowTs + p_.ttlSeconds;

        positionId = nextPositionId++;
        BracketPosition storage pos = positions[positionId];
        pos.owner = msg.sender;
        pos.pairId = pairId;
        pos.isBaseToQuote = p_.isBaseToQuote;
        pos.status = PositionStatus.ACTIVE;
        pos.amountIn = p_.amountIn;
        pos.entryPriceE18 = spot;
        pos.hardStopPriceE18 = p_.hardStopPriceE18;
        pos.takeProfitPriceE18 = p_.takeProfitPriceE18;
        pos.trailingStopBps = p_.trailingStopBps;
        pos.maxDislocationBps = p_.maxDislocationBps;
        pos.maxSlippageBps = p_.maxSlippageBps;
        pos.enableCrossPoolArb = p_.enableCrossPoolArb;
        pos.cooldownSec = p_.cooldownSec;
        pos.createdAt = nowTs;
        pos.expiresAt = expiresAt;

        ArmedPositionData memory cfg;
        cfg.isBaseToQuote = p_.isBaseToQuote;
        cfg.amountIn = p_.amountIn;
        cfg.entryPriceE18 = spot;
        cfg.hardStopPriceE18 = p_.hardStopPriceE18;
        cfg.takeProfitPriceE18 = p_.takeProfitPriceE18;
        cfg.trailingStopBps = p_.trailingStopBps;
        cfg.maxDislocationBps = p_.maxDislocationBps;
        cfg.maxSlippageBps = p_.maxSlippageBps;
        cfg.enableCrossPoolArb = p_.enableCrossPoolArb;
        cfg.cooldownSec = p_.cooldownSec;
        cfg.expiresAt = expiresAt;

        emit PositionArmed(positionId, msg.sender, pairId, cfg);
    }

    function cancelPosition(uint256 positionId_) external {
        BracketPosition storage pos = positions[positionId_];
        if (pos.owner != msg.sender) revert NotPositionOwner();
        if (pos.status != PositionStatus.ACTIVE) revert PositionNotActive();

        pos.status = PositionStatus.CANCELLED;
        _refundEscrow(pos);

        emit PositionCancelled(positionId_, msg.sender);
    }

    function reclaimExpired(uint256 positionId_) external {
        BracketPosition storage pos = positions[positionId_];
        if (pos.status != PositionStatus.ACTIVE) revert PositionNotActive();
        if (pos.expiresAt == 0 || block.timestamp < pos.expiresAt) revert PositionNotExpired();

        pos.status = PositionStatus.EXPIRED;
        _refundEscrow(pos);

        emit PositionCancelled(positionId_, pos.owner);
    }

    /**
     * @notice Destination callback invoked by Reactive Omni's CallbackProxy.
     * @dev Guarded by both `onlyServiceProvider` (verifies msg.sender == CallbackProxy) and
     *      `onlyCallbackSender(reactiveSender_)` (verifies injected payload sender == OmniSentinelReactive).
     *      Never reverts on benign market drift or expired state so the contract avoids unnecessary
     *      `CallbackFailure` logs while emitting `SettlementDeferred` for closed-loop Reactive sync.
     */
    function executeBracketCallback(
        address reactiveSender_,
        uint256 positionId_,
        uint8 triggerKind_,
        uint256 referencePriceE18_,
        uint256 originEventTimestamp_
    ) external override onlyServiceProvider onlyCallbackSender(reactiveSender_) {
        BracketPosition storage pos = positions[positionId_];
        uint256 nowTs = block.timestamp;

        if (pos.status != PositionStatus.ACTIVE) {
            emit SettlementDeferred(positionId_, triggerKind_, 0, 0, nowTs);
            return;
        }

        if (pos.expiresAt != 0 && nowTs >= pos.expiresAt) {
            pos.status = PositionStatus.EXPIRED;
            _refundEscrow(pos);
            emit PositionCancelled(positionId_, pos.owner);
            return;
        }

        if (pos.lastAttemptAt != 0 && nowTs < uint256(pos.lastAttemptAt) + uint256(pos.cooldownSec)) {
            totalDeferredCount++;
            emit SettlementDeferred(positionId_, triggerKind_, 0, 0, nowTs);
            return;
        }

        uint256 minRequiredOut;
        {
            uint256 quotedOut;
            if (pos.isBaseToQuote) {
                quotedOut = pool.quoteBaseForQuote(pos.amountIn);
                uint256 idealOut = (pos.amountIn * referencePriceE18_) / OmniConstants.PRICE_SCALE;
                minRequiredOut =
                    (idealOut * (OmniConstants.BPS_DENOMINATOR - pos.maxSlippageBps)) /
                    OmniConstants.BPS_DENOMINATOR;
            } else {
                quotedOut = pool.quoteQuoteForBase(pos.amountIn);
                uint256 idealOut = referencePriceE18_ == 0
                    ? 0
                    : (pos.amountIn * OmniConstants.PRICE_SCALE) / referencePriceE18_;
                minRequiredOut =
                    (idealOut * (OmniConstants.BPS_DENOMINATOR - pos.maxSlippageBps)) /
                    OmniConstants.BPS_DENOMINATOR;
            }

            if (quotedOut == 0 || quotedOut < minRequiredOut) {
                pos.lastAttemptAt = _toUint64(nowTs);
                pos.deferralCount++;
                totalDeferredCount++;
                if (pos.deferralCount >= MAX_DEFERRAL_RETRIES) {
                    pos.status = PositionStatus.CANCELLED;
                    _refundEscrow(pos);
                    emit PositionCancelled(positionId_, pos.owner);
                    return;
                }
                emit SettlementDeferred(positionId_, triggerKind_, quotedOut, minRequiredOut, nowTs);
                return;
            }
        }

        pos.status = PositionStatus.SETTLED;
        pos.lastAttemptAt = _toUint64(nowTs);
        pos.settledAt = _toUint64(nowTs);

        uint256 amountIn = pos.amountIn;
        address posOwner = pos.owner;
        bool isBaseToQuote = pos.isBaseToQuote;

        uint256 actualOut = isBaseToQuote
            ? pool.swapExactBaseForQuote(amountIn, minRequiredOut, posOwner)
            : pool.swapExactQuoteForBase(amountIn, minRequiredOut, posOwner);

        uint256 execPriceE18 = isBaseToQuote
            ? (actualOut * OmniConstants.PRICE_SCALE) / amountIn
            : (amountIn * OmniConstants.PRICE_SCALE) / actualOut;

        uint256 loopLatencySec = nowTs >= originEventTimestamp_ ? nowTs - originEventTimestamp_ : 0;

        pos.amountOut = actualOut;
        pos.lastLoopLatencySec = loopLatencySec;

        totalSettledCount++;
        cumulativeLatencySec += loopLatencySec;
        if (loopLatencySec < minLoopLatencySec) minLoopLatencySec = loopLatencySec;
        if (loopLatencySec > maxLoopLatencySec) maxLoopLatencySec = loopLatencySec;

        _emitBracketSettled(positionId_, triggerKind_, execPriceE18, originEventTimestamp_);
    }

    function _emitBracketSettled(
        uint256 positionId_,
        uint8 triggerKind_,
        uint256 execPriceE18_,
        uint256 originEventTimestamp_
    ) internal {
        BracketPosition storage pos = positions[positionId_];
        SettledEventData memory s;
        s.triggerKind = triggerKind_;
        s.amountIn = pos.amountIn;
        s.amountOut = pos.amountOut;
        s.executionPriceE18 = execPriceE18_;
        s.originEventTimestamp = originEventTimestamp_;
        s.settledAtTimestamp = pos.settledAt;
        s.loopLatencySec = pos.lastLoopLatencySec;
        emit BracketSettled(positionId_, pos.owner, s);
    }

    /// @notice Settles any outstanding fee debt owed to the destination CallbackProxy from contract ETH balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Withdraws surplus native gas ETH after settling any CallbackProxy debt (never touches ERC-20 escrow).
    function withdrawNative(address payable recipient_, uint256 amount_) external onlyOwner {
        if (recipient_ == address(0) || amount_ == 0) revert InvalidWithdrawal();
        _coverDebt();
        if (address(this).balance < amount_) revert InvalidWithdrawal();
        (bool ok, ) = recipient_.call{ value: amount_ }("");
        if (!ok) revert InvalidWithdrawal();
    }

    function getPosition(uint256 positionId_) external view returns (BracketPosition memory) {
        return positions[positionId_];
    }

    function averageLoopLatencySec() external view returns (uint256) {
        if (totalSettledCount == 0) return 0;
        return cumulativeLatencySec / totalSettledCount;
    }

    function _refundEscrow(BracketPosition storage pos_) internal {
        if (pos_.isBaseToQuote) {
            if (!baseToken.transfer(pos_.owner, pos_.amountIn)) revert ERC20TransferFailed();
        } else {
            if (!quoteToken.transfer(pos_.owner, pos_.amountIn)) revert ERC20TransferFailed();
        }
    }

    function _toUint64(uint256 value_) internal pure returns (uint64) {
        if (value_ > type(uint64).max) return type(uint64).max;
        // casting to 'uint64' is safe because `value_ <= type(uint64).max` is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value_);
    }
}
