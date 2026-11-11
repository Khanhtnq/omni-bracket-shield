// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { MockERC20 } from "./MockERC20.sol";
import { OmniConstants } from "../interfaces/IOmniBracketTypes.sol";

/**
 * @title OmniPricePool
 * @notice Constant-product (x * y = k) liquidity pool & sub-second tick emitter deployed on
 *         Base Sepolia (200ms blocks) and Unichain Sepolia (1s blocks).
 * @dev Emits `PoolTickUpdated` carrying `block.timestamp` (never block counts) in compliance with
 *      Base Sepolia Denim 200ms block rules.
 */
contract OmniPricePool {
    MockERC20 public immutable baseToken;
    MockERC20 public immutable quoteToken;
    bytes32 public immutable pairId;
    address public immutable owner;

    uint256 public reserveBase;
    uint256 public reserveQuote;
    uint256 public lastUpdatedTimestamp;
    uint256 public constant SWAP_FEE_BPS = 30; // 0.30%

    event PoolTickUpdated(
        bytes32 indexed pairId,
        uint256 spotPriceE18,
        uint256 reserveBase,
        uint256 reserveQuote,
        uint256 tickTimestamp
    );

    event LiquiditySeeded(address indexed provider, uint256 baseAdded, uint256 quoteAdded, uint256 spotPriceE18);
    event SwapExecuted(
        address indexed sender,
        address indexed recipient,
        bool indexed baseToQuote,
        uint256 amountIn,
        uint256 amountOut,
        uint256 spotPriceAfterE18
    );

    error EmptyLiquidity();
    error InvalidAmount();
    error SlippageExceeded(uint256 quotedOut, uint256 minOut);
    error ERC20TransferFailed();
    error Unauthorized();

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    constructor(address baseToken_, address quoteToken_, bytes32 pairId_) {
        baseToken = MockERC20(baseToken_);
        quoteToken = MockERC20(quoteToken_);
        pairId = pairId_;
        owner = msg.sender;
    }

    function spotPriceE18() public view returns (uint256) {
        if (reserveBase == 0) return 0;
        return (reserveQuote * OmniConstants.PRICE_SCALE) / reserveBase;
    }

    function seedLiquidity(uint256 baseAmount_, uint256 quoteAmount_) external {
        if (baseAmount_ == 0 || quoteAmount_ == 0) revert InvalidAmount();
        if (!baseToken.transferFrom(msg.sender, address(this), baseAmount_)) revert ERC20TransferFailed();
        if (!quoteToken.transferFrom(msg.sender, address(this), quoteAmount_)) revert ERC20TransferFailed();

        reserveBase += baseAmount_;
        reserveQuote += quoteAmount_;
        lastUpdatedTimestamp = block.timestamp;

        uint256 price = spotPriceE18();
        emit LiquiditySeeded(msg.sender, baseAmount_, quoteAmount_, price);
        emit PoolTickUpdated(pairId, price, reserveBase, reserveQuote, block.timestamp);
    }

    function quoteBaseForQuote(uint256 amountBaseIn_) public view returns (uint256 amountQuoteOut) {
        if (reserveBase == 0 || reserveQuote == 0) revert EmptyLiquidity();
        if (amountBaseIn_ == 0) return 0;
        uint256 amountInWithFee = amountBaseIn_ * (OmniConstants.BPS_DENOMINATOR - SWAP_FEE_BPS);
        uint256 numerator = amountInWithFee * reserveQuote;
        uint256 denominator = (reserveBase * OmniConstants.BPS_DENOMINATOR) + amountInWithFee;
        amountQuoteOut = numerator / denominator;
    }

    function quoteQuoteForBase(uint256 amountQuoteIn_) public view returns (uint256 amountBaseOut) {
        if (reserveBase == 0 || reserveQuote == 0) revert EmptyLiquidity();
        if (amountQuoteIn_ == 0) return 0;
        uint256 amountInWithFee = amountQuoteIn_ * (OmniConstants.BPS_DENOMINATOR - SWAP_FEE_BPS);
        uint256 numerator = amountInWithFee * reserveBase;
        uint256 denominator = (reserveQuote * OmniConstants.BPS_DENOMINATOR) + amountInWithFee;
        amountBaseOut = numerator / denominator;
    }

    function swapExactBaseForQuote(
        uint256 amountBaseIn_,
        uint256 minQuoteOut_,
        address recipient_
    ) external returns (uint256 amountQuoteOut) {
        if (amountBaseIn_ == 0) revert InvalidAmount();
        amountQuoteOut = quoteBaseForQuote(amountBaseIn_);
        if (amountQuoteOut < minQuoteOut_) revert SlippageExceeded(amountQuoteOut, minQuoteOut_);

        if (!baseToken.transferFrom(msg.sender, address(this), amountBaseIn_)) revert ERC20TransferFailed();
        reserveBase += amountBaseIn_;
        reserveQuote -= amountQuoteOut;
        lastUpdatedTimestamp = block.timestamp;

        if (!quoteToken.transfer(recipient_, amountQuoteOut)) revert ERC20TransferFailed();

        uint256 priceAfter = spotPriceE18();
        emit SwapExecuted(msg.sender, recipient_, true, amountBaseIn_, amountQuoteOut, priceAfter);
        emit PoolTickUpdated(pairId, priceAfter, reserveBase, reserveQuote, block.timestamp);
    }

    function swapExactQuoteForBase(
        uint256 amountQuoteIn_,
        uint256 minBaseOut_,
        address recipient_
    ) external returns (uint256 amountBaseOut) {
        if (amountQuoteIn_ == 0) revert InvalidAmount();
        amountBaseOut = quoteQuoteForBase(amountQuoteIn_);
        if (amountBaseOut < minBaseOut_) revert SlippageExceeded(amountBaseOut, minBaseOut_);

        if (!quoteToken.transferFrom(msg.sender, address(this), amountQuoteIn_)) revert ERC20TransferFailed();
        reserveQuote += amountQuoteIn_;
        reserveBase -= amountBaseOut;
        lastUpdatedTimestamp = block.timestamp;

        if (!baseToken.transfer(recipient_, amountBaseOut)) revert ERC20TransferFailed();

        uint256 priceAfter = spotPriceE18();
        emit SwapExecuted(msg.sender, recipient_, false, amountQuoteIn_, amountBaseOut, priceAfter);
        emit PoolTickUpdated(pairId, priceAfter, reserveBase, reserveQuote, block.timestamp);
    }

    /**
     * @notice Testnet market-shock & arbitrage benchmark driver: shifts reserves to `targetSpotPriceE18_`
     *         while keeping real token balances solvent on `MockERC20` and emitting `PoolTickUpdated`.
     */
    function syncSpotPrice(uint256 targetSpotPriceE18_) external onlyOwner {
        if (reserveBase == 0 || reserveQuote == 0) revert EmptyLiquidity();
        if (targetSpotPriceE18_ == 0) revert InvalidAmount();

        // Preserve base reserve depth and scale quote reserve to hit target spot price cleanly.
        uint256 newReserveQuote = (reserveBase * targetSpotPriceE18_) / OmniConstants.PRICE_SCALE;
        if (newReserveQuote == 0) revert InvalidAmount();

        uint256 currentQuoteBal = quoteToken.balanceOf(address(this));
        if (newReserveQuote > currentQuoteBal) {
            quoteToken.mint(address(this), newReserveQuote - currentQuoteBal);
        }

        reserveQuote = newReserveQuote;
        lastUpdatedTimestamp = block.timestamp;

        uint256 actualPrice = spotPriceE18();
        emit PoolTickUpdated(pairId, actualPrice, reserveBase, reserveQuote, block.timestamp);
    }
}
