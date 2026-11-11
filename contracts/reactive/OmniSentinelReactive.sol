// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import {
    OmniConstants,
    TriggerKind,
    PositionStatus,
    ArmedPositionData,
    SettledEventData,
    IOmniBracketCallback
} from "../interfaces/IOmniBracketTypes.sol";

/**
 * @title OmniSentinelReactive
 * @notice Stateful Cross-Chain DeFi Bracket, Trailing-Stop, Anti-Wick & Cross-Pool Dislocation Engine
 *         built natively on Reactive Omni (`0x8888...8888`, ~1s CometBFT instant finality).
 * @dev Subscribes to sub-second ticks on Base Sepolia (84532, 200ms Denim blocks) and Unichain Sepolia
 *      (1301, 1s blocks), correlates cross-venue dislocations, ratchets trailing stops with zero
 *      destination gas, filters single-pool flash wicks, and dispatches callbacks via
 *      `SYSTEM.requestCallbackV_1_0(...)`.
 */
contract OmniSentinelReactive is AbstractReactive {
    struct VenueFeed {
        uint256 spotPriceE18;
        uint256 emaPriceE18;
        uint256 volatilityBps;
        uint256 updatedAt;
        uint256 tickCount;
    }

    struct TrackedPosition {
        address owner;
        bytes32 pairId;
        bool isBaseToQuote;
        PositionStatus status;
        uint256 amountIn;
        uint256 entryPriceE18;
        uint256 extremumPriceE18;
        uint256 hardStopPriceE18;
        uint256 takeProfitPriceE18;
        uint16 trailingStopBps;
        uint16 maxDislocationBps;
        uint16 maxSlippageBps;
        bool enableCrossPoolArb;
        uint64 cooldownSec;
        uint64 expiresAt;
        uint64 lastTriggerAt;
        uint64 inFlightSince;
    }

    uint256 public constant IN_FLIGHT_TIMEOUT_SEC = 60;
    uint256 public constant DEFAULT_REF_MAX_AGE_SEC = 30;
    uint256 public constant HIGH_VOL_THRESHOLD_BPS = 150;
    uint256 public constant MAX_ACTIVE_SCAN = 16;
    uint256 public constant MAX_CALLBACKS_PER_TICK = 2;
    uint256 public constant MIN_DISPATCH_GAS_RESERVE = 180_000;

    address public immutable owner;
    uint256 public immutable primaryChainId;
    address public immutable primaryPool;
    uint256 public immutable referenceChainId;
    address public immutable referencePool;

    address public vault;
    uint64 public callbackGasLimit;
    uint256 public referenceMaxAgeSec = DEFAULT_REF_MAX_AGE_SEC;
    uint256 public scanCursor;
    bool public monitoringActive;
    bool public vaultSubscribed;
    bool public cronSubscribed;
    bool public cronDesired;

    VenueFeed public primaryFeed;
    VenueFeed public referenceFeed;

    uint256 public callbacksDispatched;
    uint256 public completedLoops;
    uint256 public wickManipulationsBlocked;
    uint256 public lastConfirmedLoopLatencySec;

    mapping(uint256 => TrackedPosition) public trackedPositions;
    uint256[] public activePositionIds;
    mapping(uint256 => uint256) internal activeIndexPlusOne; // 1-based index into activePositionIds

    event VaultConfigured(address indexed vault, uint256 indexed chainId);
    event MonitoringStateChanged(bool active);
    event TrailingExtremumRatcheted(
        uint256 indexed positionId,
        uint256 previousExtremumE18,
        uint256 newExtremumE18,
        uint256 effectiveStopPriceE18
    );
    event FlashWickFiltered(
        uint256 indexed positionId,
        uint256 primaryPriceE18,
        uint256 referencePriceE18,
        uint256 dislocationBps
    );
    event CallbackDispatched(
        uint256 indexed positionId,
        uint8 indexed triggerKind,
        uint256 primaryPriceE18,
        uint256 referencePriceE18,
        uint256 originTimestamp
    );
    event LoopConfirmed(
        uint256 indexed positionId,
        uint8 indexed triggerKind,
        uint256 amountOut,
        uint256 loopLatencySec
    );

    error OnlyOwner();
    error InvalidAddress();
    error InvalidCallbackGasLimit(uint64 provided, uint64 minimum);
    error VaultAlreadyConfigured();
    error InvalidWithdrawal();

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert OnlyOwner();
    }

    /**
     * @notice Deploys on Reactive Lasna (5318007) / Reactive Mainnet (1597) and subscribes to origin pools.
     * @dev Step 1 of Reactive Omni's 4-step deployment order: deploy Reactive first, then deploy
     *      `OmniBracketVault` with `address(this)` as `_CALLBACK_SENDER`, then call `configureVault(vault)`.
     */
    constructor(
        uint256 primaryChainId_,
        address primaryPool_,
        uint256 referenceChainId_,
        address referencePool_,
        uint64 callbackGasLimit_
    ) payable {
        if (primaryPool_ == address(0)) revert InvalidAddress();
        if (callbackGasLimit_ < OmniConstants.MIN_CALLBACK_GAS_LIMIT) {
            revert InvalidCallbackGasLimit(callbackGasLimit_, OmniConstants.MIN_CALLBACK_GAS_LIMIT);
        }

        owner = msg.sender;
        primaryChainId = primaryChainId_;
        primaryPool = primaryPool_;
        referenceChainId = referenceChainId_;
        referencePool = referencePool_;
        callbackGasLimit = callbackGasLimit_;

        _subscribePools();
        monitoringActive = true;
    }

    /**
     * @notice Step 3 of deployment: binds the destination `OmniBracketVault` and subscribes to its lifecycle events.
     */
    function configureVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert InvalidAddress();
        if (vault != address(0)) revert VaultAlreadyConfigured();

        vault = vault_;
        if (monitoringActive) {
            _subscribeVault(vault_);
        }

        emit VaultConfigured(vault_, primaryChainId);
    }

    function setCallbackGasLimit(uint64 callbackGasLimit_) external onlyOwner {
        if (callbackGasLimit_ < OmniConstants.MIN_CALLBACK_GAS_LIMIT) {
            revert InvalidCallbackGasLimit(callbackGasLimit_, OmniConstants.MIN_CALLBACK_GAS_LIMIT);
        }
        callbackGasLimit = callbackGasLimit_;
    }

    function setReferenceMaxAgeSec(uint256 maxAgeSec_) external onlyOwner {
        referenceMaxAgeSec = maxAgeSec_;
    }

    /**
     * @notice Toggles optional protocol Cron100 (~2 min) subscription for stale in-flight housekeeping.
     */
    function setCronHeartbeat(bool enabled_) external onlyOwner {
        cronDesired = enabled_;
        if (enabled_ && monitoringActive && !cronSubscribed) {
            _coverDebt();
            _subscribeCron();
        } else if (!enabled_ && cronSubscribed) {
            _unsubscribeCron();
        }
    }

    function pauseMonitoring() external onlyOwner {
        if (!monitoringActive) return;
        _unsubscribePools();
        if (vault != address(0) && vaultSubscribed) {
            _unsubscribeVault(vault);
        }
        if (cronSubscribed) {
            _unsubscribeCron();
        }
        monitoringActive = false;
        emit MonitoringStateChanged(false);
    }

    function resumeMonitoring() external payable onlyOwner {
        if (monitoringActive) return;
        _coverDebt();
        _subscribePools();
        if (vault != address(0) && !vaultSubscribed) {
            _subscribeVault(vault);
        }
        if (cronDesired && !cronSubscribed) {
            _subscribeCron();
        }
        monitoringActive = true;
        emit MonitoringStateChanged(true);
    }

    /// @notice Settles any outstanding debt owed to `SYSTEM` (`0x8888...8888`) from contract lREACT/REACT balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Withdraws surplus native lREACT/REACT after settling any outstanding `SYSTEM` debt.
    function withdrawNative(address payable recipient_, uint256 amount_) external onlyOwner {
        if (recipient_ == address(0) || amount_ == 0) revert InvalidWithdrawal();
        _coverDebt();
        if (address(this).balance < amount_) revert InvalidWithdrawal();
        (bool ok, ) = recipient_.call{ value: amount_ }("");
        if (!ok) revert InvalidWithdrawal();
    }

    function activePositionCount() external view returns (uint256) {
        return activePositionIds.length;
    }

    function getTrackedPosition(uint256 positionId_) external view returns (TrackedPosition memory) {
        return trackedPositions[positionId_];
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external override onlySystem {
        uint256 t0 = log_.topic0;

        if (t0 == OmniConstants.POOL_TICK_UPDATED_TOPIC_0 && log_.opCode == 2) {
            _handlePoolTick(log_);
        } else if (
            log_.chainId == primaryChainId &&
            log_.contractAddress == vault &&
            vault != address(0)
        ) {
            if (t0 == OmniConstants.POSITION_ARMED_TOPIC_0 && log_.opCode == 4) {
                _handlePositionArmed(log_);
            } else if (t0 == OmniConstants.POSITION_CANCELLED_TOPIC_0 && log_.opCode == 3) {
                _handlePositionCancelled(log_.topic1);
            } else if (t0 == OmniConstants.BRACKET_SETTLED_TOPIC_0 && log_.opCode == 3) {
                _handleBracketSettled(log_);
            } else if (t0 == OmniConstants.SETTLEMENT_DEFERRED_TOPIC_0 && log_.opCode == 2) {
                _handleSettlementDeferred(log_);
            }
        } else if (
            t0 == OmniConstants.CRON100_TOPIC_0 &&
            log_.contractAddress == OmniConstants.CRON_EMITTER_ADDR
        ) {
            _sweepStaleInFlight(block.timestamp);
        }
    }

    // -------------------------------------------------------------------------
    // Internal Event Handlers
    // -------------------------------------------------------------------------

    function _handlePositionArmed(LogRecord calldata log_) internal {
        uint256 posId = log_.topic1;
        TrackedPosition storage pos = trackedPositions[posId];
        if (pos.status != PositionStatus.NONE) return; // Idempotent against duplicate log replay

        address posOwner = address(uint160(log_.topic2));
        bytes32 pairId = bytes32(log_.topic3);

        ArmedPositionData memory d = abi.decode(log_.data, (ArmedPositionData));

        pos.owner = posOwner;
        pos.pairId = pairId;
        pos.isBaseToQuote = d.isBaseToQuote;
        pos.status = PositionStatus.ACTIVE;
        pos.amountIn = d.amountIn;
        pos.entryPriceE18 = d.entryPriceE18;
        pos.extremumPriceE18 = d.entryPriceE18;
        pos.hardStopPriceE18 = d.hardStopPriceE18;
        pos.takeProfitPriceE18 = d.takeProfitPriceE18;
        pos.trailingStopBps = d.trailingStopBps;
        pos.maxDislocationBps = d.maxDislocationBps;
        pos.maxSlippageBps = d.maxSlippageBps;
        pos.enableCrossPoolArb = d.enableCrossPoolArb;
        pos.cooldownSec = d.cooldownSec;
        pos.expiresAt = d.expiresAt;
        pos.lastTriggerAt = 0;
        pos.inFlightSince = 0;

        _addActive(posId);
    }

    function _handlePositionCancelled(uint256 posId_) internal {
        TrackedPosition storage pos = trackedPositions[posId_];
        if (pos.status == PositionStatus.NONE || pos.status == PositionStatus.SETTLED) return;
        pos.status = PositionStatus.CANCELLED;
        _removeActive(posId_);
    }

    function _handleBracketSettled(LogRecord calldata log_) internal {
        uint256 posId = log_.topic1;
        SettledEventData memory s = abi.decode(log_.data, (SettledEventData));

        TrackedPosition storage pos = trackedPositions[posId];
        pos.status = PositionStatus.SETTLED;
        pos.inFlightSince = 0;
        _removeActive(posId);

        completedLoops++;
        lastConfirmedLoopLatencySec = s.loopLatencySec;

        emit LoopConfirmed(posId, s.triggerKind, s.amountOut, s.loopLatencySec);
    }

    function _handleSettlementDeferred(LogRecord calldata log_) internal {
        uint256 posId = log_.topic1;
        (, , , uint256 deferredAtTs) = abi.decode(log_.data, (uint8, uint256, uint256, uint256));

        TrackedPosition storage pos = trackedPositions[posId];
        if (pos.status == PositionStatus.IN_FLIGHT) {
            pos.status = PositionStatus.ACTIVE;
            pos.inFlightSince = 0;
            pos.lastTriggerAt = _toUint64(deferredAtTs);
        }
    }

    function _handlePoolTick(LogRecord calldata log_) internal {
        bytes32 pairId = bytes32(log_.topic1);
        (uint256 spotPriceE18, , , uint256 tickTimestamp) =
            abi.decode(log_.data, (uint256, uint256, uint256, uint256));
        if (spotPriceE18 == 0) return;

        bool isPrimary = (log_.chainId == primaryChainId && log_.contractAddress == primaryPool);
        bool isReference = (
            referencePool != address(0) &&
            log_.chainId == referenceChainId &&
            log_.contractAddress == referencePool
        );

        if (!isPrimary && !isReference) return;

        if (isPrimary) {
            _updateVenueFeed(primaryFeed, spotPriceE18, tickTimestamp);
        } else {
            _updateVenueFeed(referenceFeed, spotPriceE18, tickTimestamp);
        }

        // Cannot dispatch callbacks before vault is wired or before primary venue has a price.
        if (vault == address(0) || primaryFeed.spotPriceE18 == 0) return;

        uint256 evalTs = tickTimestamp != 0 ? tickTimestamp : block.timestamp;
        _evaluateActivePositions(pairId, evalTs);
    }

    function _updateVenueFeed(VenueFeed storage feed_, uint256 spotE18_, uint256 ts_) internal {
        if (feed_.tickCount == 0 || feed_.emaPriceE18 == 0) {
            feed_.spotPriceE18 = spotE18_;
            feed_.emaPriceE18 = spotE18_;
            feed_.volatilityBps = 0;
        } else {
            uint256 prevSpot = feed_.spotPriceE18;
            uint256 absDelta = spotE18_ >= prevSpot ? spotE18_ - prevSpot : prevSpot - spotE18_;
            uint256 instantReturnBps = (absDelta * OmniConstants.BPS_DENOMINATOR) / prevSpot;

            // 25% new observation / 75% prior EMA smoothing.
            feed_.emaPriceE18 = (spotE18_ * 2_500 + feed_.emaPriceE18 * 7_500) / OmniConstants.BPS_DENOMINATOR;
            feed_.volatilityBps =
                (instantReturnBps * 3_000 + feed_.volatilityBps * 7_000) /
                OmniConstants.BPS_DENOMINATOR;
            feed_.spotPriceE18 = spotE18_;
        }
        if (ts_ >= feed_.updatedAt) {
            feed_.updatedAt = ts_;
        }
        feed_.tickCount++;
    }

    function _evaluateActivePositions(bytes32 pairId_, uint256 evalTs_) internal {
        uint256 len = activePositionIds.length;
        if (len == 0) return;

        uint256 scanCount = len > MAX_ACTIVE_SCAN ? MAX_ACTIVE_SCAN : len;
        uint256 startCursor = scanCursor % len;

        // Snapshot target positionIds before evaluation so swap-and-pop removals never corrupt round-robin order.
        uint256[] memory batchIds = new uint256[](scanCount);
        for (uint256 k = 0; k < scanCount; ++k) {
            batchIds[k] = activePositionIds[(startCursor + k) % len];
        }

        uint256 primaryPrice = primaryFeed.spotPriceE18;
        bool refFresh = _isReferenceFresh(evalTs_);
        uint256 refPrice = refFresh ? referenceFeed.spotPriceE18 : 0;
        uint256 dislocationBps = refFresh ? _computeDislocationBps(primaryPrice, refPrice) : 0;
        uint256 dispatchedThisTick = 0;
        uint256 processed = 0;

        for (uint256 i = 0; i < scanCount; ++i) {
            uint256 posId = batchIds[i];
            TrackedPosition storage pos = trackedPositions[posId];

            if (pos.pairId != pairId_) {
                unchecked {
                    ++processed;
                }
                continue;
            }

            // Recover stale in-flight positions after timestamp timeout.
            if (
                pos.status == PositionStatus.IN_FLIGHT &&
                pos.inFlightSince != 0 &&
                evalTs_ >= uint256(pos.inFlightSince) + IN_FLIGHT_TIMEOUT_SEC
            ) {
                pos.status = PositionStatus.ACTIVE;
                pos.inFlightSince = 0;
            }

            if (pos.status != PositionStatus.ACTIVE) {
                unchecked {
                    ++processed;
                }
                continue;
            }

            if (pos.expiresAt != 0 && evalTs_ >= pos.expiresAt) {
                pos.status = PositionStatus.EXPIRED;
                _removeActive(posId);
                unchecked {
                    ++processed;
                }
                continue;
            }

            // 1. Update zero-gas trailing extremum when price moves favorably (guarded against unconfirmed wicks).
            _maybeRatchetExtremum(posId, pos, primaryPrice, refFresh, dislocationBps);

            // 2. Enforce timestamp-based cooldown (with >= 1s defensive floor) before dispatching a callback.
            uint256 minCooldown = pos.cooldownSec > 0 ? uint256(pos.cooldownSec) : 1;
            if (pos.lastTriggerAt != 0 && evalTs_ < uint256(pos.lastTriggerAt) + minCooldown) {
                unchecked {
                    ++processed;
                }
                continue;
            }

            // 3. Enforce Reactive Omni 900k gas cap safety: bound dispatches per tick & preserve gas reserve.
            if (
                dispatchedThisTick >= MAX_CALLBACKS_PER_TICK ||
                gasleft() < MIN_DISPATCH_GAS_RESERVE
            ) {
                break;
            }

            // 4. Evaluate triggers in priority order: Take-Profit -> Cross-Pool Arb -> Hard/Trailing Stop.
            TriggerKind trigger = _selectTrigger(posId, pos, primaryPrice, refFresh, refPrice, dislocationBps);
            if (trigger != TriggerKind.NONE) {
                _dispatchCallback(posId, pos, trigger, primaryPrice, refPrice, evalTs_);
                unchecked {
                    ++dispatchedThisTick;
                }
            }
            unchecked {
                ++processed;
            }
        }

        uint256 newLen = activePositionIds.length;
        if (newLen > MAX_ACTIVE_SCAN || processed < scanCount) {
            scanCursor = newLen == 0 ? 0 : (startCursor + processed) % newLen;
        } else {
            scanCursor = 0;
        }
    }

    function _maybeRatchetExtremum(
        uint256 posId_,
        TrackedPosition storage pos_,
        uint256 primaryPrice_,
        bool refFresh_,
        uint256 dislocationBps_
    ) internal {
        if (pos_.trailingStopBps == 0) return;

        // Do not ratchet high-water mark on an isolated single-pool spike that exceeds maxDislocationBps.
        if (refFresh_ && pos_.maxDislocationBps > 0 && dislocationBps_ > pos_.maxDislocationBps) {
            return;
        }

        if (pos_.isBaseToQuote && primaryPrice_ > pos_.extremumPriceE18) {
            uint256 prev = pos_.extremumPriceE18;
            pos_.extremumPriceE18 = primaryPrice_;
            uint256 newStop = _computeTrailingStopPrice(pos_);
            emit TrailingExtremumRatcheted(posId_, prev, primaryPrice_, newStop);
        } else if (!pos_.isBaseToQuote && primaryPrice_ < pos_.extremumPriceE18) {
            uint256 prev = pos_.extremumPriceE18;
            pos_.extremumPriceE18 = primaryPrice_;
            uint256 newStop = _computeTrailingStopPrice(pos_);
            emit TrailingExtremumRatcheted(posId_, prev, primaryPrice_, newStop);
        }
    }

    function _selectTrigger(
        uint256 posId_,
        TrackedPosition storage pos_,
        uint256 primaryPrice_,
        bool refFresh_,
        uint256 refPrice_,
        uint256 dislocationBps_
    ) internal returns (TriggerKind) {
        // A. Take-Profit check
        if (pos_.takeProfitPriceE18 != 0) {
            if (pos_.isBaseToQuote && primaryPrice_ >= pos_.takeProfitPriceE18) {
                return TriggerKind.TAKE_PROFIT;
            }
            if (!pos_.isBaseToQuote && primaryPrice_ <= pos_.takeProfitPriceE18) {
                return TriggerKind.TAKE_PROFIT;
            }
        }

        // B. Favorable Cross-Pool Arbitrage / Rebalance check (Base Sepolia vs Unichain Sepolia)
        if (pos_.enableCrossPoolArb && refFresh_ && pos_.maxDislocationBps > 0) {
            if (dislocationBps_ >= pos_.maxDislocationBps) {
                if (pos_.isBaseToQuote && primaryPrice_ > refPrice_) {
                    return TriggerKind.CROSS_POOL_ARB_REBALANCE;
                }
                if (!pos_.isBaseToQuote && primaryPrice_ < refPrice_) {
                    return TriggerKind.CROSS_POOL_ARB_REBALANCE;
                }
            }
        }

        // C. Stop-Loss & Trailing-Stop checks with Cross-Chain Anti-Wick Protection
        bool hardStopHit = false;
        if (pos_.hardStopPriceE18 != 0) {
            hardStopHit = pos_.isBaseToQuote
                ? (primaryPrice_ <= pos_.hardStopPriceE18)
                : (primaryPrice_ >= pos_.hardStopPriceE18);
        }

        bool trailingHit = false;
        if (pos_.trailingStopBps != 0) {
            uint256 dynamicStop = _computeTrailingStopPrice(pos_);
            trailingHit = pos_.isBaseToQuote
                ? (primaryPrice_ <= dynamicStop)
                : (primaryPrice_ >= dynamicStop);
        }

        if (!hardStopHit && !trailingHit) {
            return TriggerKind.NONE;
        }

        // Cross-chain flash-wick filter: if primary venue dislocated violently from fresh Unichain quote
        // while Unichain remains safely clear of the stop level, block single-block sandwich liquidation.
        if (refFresh_ && pos_.maxDislocationBps > 0 && dislocationBps_ > pos_.maxDislocationBps) {
            bool refAlsoBreached = _referenceConfirmsBreach(pos_, refPrice_);
            if (!refAlsoBreached) {
                wickManipulationsBlocked++;
                emit FlashWickFiltered(posId_, primaryPrice_, refPrice_, dislocationBps_);
                return TriggerKind.NONE;
            }
        }

        return hardStopHit ? TriggerKind.HARD_STOP_LOSS : TriggerKind.TRAILING_STOP_LOSS;
    }

    function _computeTrailingStopPrice(TrackedPosition storage pos_) internal view returns (uint256) {
        uint256 effBps = pos_.trailingStopBps;
        // Widen trailing distance by up to 25% during elevated volatility regimes to prevent noise whip-saw.
        if (primaryFeed.volatilityBps >= HIGH_VOL_THRESHOLD_BPS) {
            uint256 widened = effBps + (effBps / 4);
            if (widened < OmniConstants.BPS_DENOMINATOR) {
                effBps = widened;
            }
        }

        if (pos_.isBaseToQuote) {
            return
                (pos_.extremumPriceE18 * (OmniConstants.BPS_DENOMINATOR - effBps)) /
                OmniConstants.BPS_DENOMINATOR;
        } else {
            return
                (pos_.extremumPriceE18 * (OmniConstants.BPS_DENOMINATOR + effBps)) /
                OmniConstants.BPS_DENOMINATOR;
        }
    }

    function _referenceConfirmsBreach(
        TrackedPosition storage pos_,
        uint256 refPrice_
    ) internal view returns (bool) {
        if (pos_.hardStopPriceE18 != 0) {
            if (pos_.isBaseToQuote && refPrice_ <= pos_.hardStopPriceE18) return true;
            if (!pos_.isBaseToQuote && refPrice_ >= pos_.hardStopPriceE18) return true;
        }
        if (pos_.trailingStopBps != 0) {
            uint256 stopPrice = _computeTrailingStopPrice(pos_);
            if (pos_.isBaseToQuote && refPrice_ <= stopPrice) return true;
            if (!pos_.isBaseToQuote && refPrice_ >= stopPrice) return true;
        }
        return false;
    }

    function _dispatchCallback(
        uint256 posId_,
        TrackedPosition storage pos_,
        TriggerKind trigger_,
        uint256 primaryPrice_,
        uint256 refPrice_,
        uint256 originTimestamp_
    ) internal {
        pos_.status = PositionStatus.IN_FLIGHT;
        pos_.lastTriggerAt = _toUint64(originTimestamp_);
        pos_.inFlightSince = _toUint64(originTimestamp_);
        callbacksDispatched++;

        // First parameter MUST be `address(0)` — overwritten by Destination CallbackProxy with `address(this)`.
        bytes memory payload = abi.encodeCall(
            IOmniBracketCallback.executeBracketCallback,
            (address(0), posId_, uint8(trigger_), primaryPrice_, originTimestamp_)
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: primaryChainId,
                recipient: vault,
                gasLimit: callbackGasLimit,
                payload: payload
            })
        );

        emit CallbackDispatched(posId_, uint8(trigger_), primaryPrice_, refPrice_, originTimestamp_);
    }

    function _sweepStaleInFlight(uint256 nowTs_) internal {
        uint256 len = activePositionIds.length;
        if (len == 0) return;
        uint256 scanCount = len > MAX_ACTIVE_SCAN ? MAX_ACTIVE_SCAN : len;
        uint256 startCursor = scanCursor % len;
        for (uint256 i = 0; i < scanCount; ++i) {
            TrackedPosition storage pos = trackedPositions[activePositionIds[(startCursor + i) % len]];
            if (
                pos.status == PositionStatus.IN_FLIGHT &&
                pos.inFlightSince != 0 &&
                nowTs_ >= uint256(pos.inFlightSince) + IN_FLIGHT_TIMEOUT_SEC
            ) {
                pos.status = PositionStatus.ACTIVE;
                pos.inFlightSince = 0;
            }
        }
        if (len > MAX_ACTIVE_SCAN) {
            scanCursor = (startCursor + scanCount) % len;
        }
    }

    function _isReferenceFresh(uint256 evalTs_) internal view returns (bool) {
        if (referencePool == address(0) || referenceFeed.updatedAt == 0 || referenceFeed.spotPriceE18 == 0) {
            return false;
        }
        if (evalTs_ <= referenceFeed.updatedAt) return true;
        return (evalTs_ - referenceFeed.updatedAt) <= referenceMaxAgeSec;
    }

    function _computeDislocationBps(uint256 priceA_, uint256 priceB_) internal pure returns (uint256) {
        if (priceA_ == 0 || priceB_ == 0) return 0;
        uint256 diff = priceA_ >= priceB_ ? priceA_ - priceB_ : priceB_ - priceA_;
        uint256 base = priceA_ <= priceB_ ? priceA_ : priceB_;
        return (diff * OmniConstants.BPS_DENOMINATOR) / base;
    }

    // -------------------------------------------------------------------------
    // Subscription & Set Helpers
    // -------------------------------------------------------------------------

    function _subscribePools() internal {
        SYSTEM.subscribe(
            primaryChainId,
            primaryPool,
            OmniConstants.POOL_TICK_UPDATED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        if (referencePool != address(0)) {
            SYSTEM.subscribe(
                referenceChainId,
                referencePool,
                OmniConstants.POOL_TICK_UPDATED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function _unsubscribePools() internal {
        SYSTEM.unsubscribe(
            primaryChainId,
            primaryPool,
            OmniConstants.POOL_TICK_UPDATED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        if (referencePool != address(0)) {
            SYSTEM.unsubscribe(
                referenceChainId,
                referencePool,
                OmniConstants.POOL_TICK_UPDATED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function _subscribeVault(address vault_) internal {
        SYSTEM.subscribe(
            primaryChainId,
            vault_,
            OmniConstants.POSITION_ARMED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            primaryChainId,
            vault_,
            OmniConstants.POSITION_CANCELLED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            primaryChainId,
            vault_,
            OmniConstants.BRACKET_SETTLED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            primaryChainId,
            vault_,
            OmniConstants.SETTLEMENT_DEFERRED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        vaultSubscribed = true;
    }

    function _unsubscribeVault(address vault_) internal {
        SYSTEM.unsubscribe(
            primaryChainId,
            vault_,
            OmniConstants.POSITION_ARMED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.unsubscribe(
            primaryChainId,
            vault_,
            OmniConstants.POSITION_CANCELLED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.unsubscribe(
            primaryChainId,
            vault_,
            OmniConstants.BRACKET_SETTLED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.unsubscribe(
            primaryChainId,
            vault_,
            OmniConstants.SETTLEMENT_DEFERRED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        vaultSubscribed = false;
    }

    function _subscribeCron() internal {
        SYSTEM.subscribe(
            block.chainid,
            OmniConstants.CRON_EMITTER_ADDR,
            OmniConstants.CRON100_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        cronSubscribed = true;
    }

    function _unsubscribeCron() internal {
        SYSTEM.unsubscribe(
            block.chainid,
            OmniConstants.CRON_EMITTER_ADDR,
            OmniConstants.CRON100_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        cronSubscribed = false;
    }

    function _addActive(uint256 posId_) internal {
        if (activeIndexPlusOne[posId_] != 0) return;
        activePositionIds.push(posId_);
        activeIndexPlusOne[posId_] = activePositionIds.length;
    }

    function _removeActive(uint256 posId_) internal {
        uint256 idxPlusOne = activeIndexPlusOne[posId_];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = activePositionIds.length - 1;
        if (idx != lastIdx) {
            uint256 movedId = activePositionIds[lastIdx];
            activePositionIds[idx] = movedId;
            activeIndexPlusOne[movedId] = idx + 1;
        }
        activePositionIds.pop();
        delete activeIndexPlusOne[posId_];
    }

    function _toUint64(uint256 value_) internal pure returns (uint64) {
        if (value_ > type(uint64).max) return type(uint64).max;
        // casting to 'uint64' is safe because `value_ <= type(uint64).max` is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value_);
    }
}
