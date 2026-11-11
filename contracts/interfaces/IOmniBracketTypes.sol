// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title IOmniBracketTypes
 * @notice Canonical protocol constants, enums, structs, and topic-0 hashes shared across
 *         Origin pools (Base Sepolia 84532 / Unichain Sepolia 1301), Destination callback vaults,
 *         and Reactive Omni contracts on Reactive Lasna (5318007) / Mainnet (1597).
 */
library OmniConstants {
    uint256 internal constant REACTIVE_MAINNET_CHAIN_ID = 1597;
    uint256 internal constant REACTIVE_LASNA_CHAIN_ID = 5318007;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    /// @notice Reactive Omni System Contract (Mainnet & Lasna Testnet).
    address internal constant OMNI_SYSTEM_CONTRACT = 0x8888888888888888888888888888888888888888;

    /// @notice Verified Destination Callback Proxies on Base Sepolia and Unichain Sepolia.
    address internal constant BASE_SEPOLIA_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address internal constant UNICHAIN_SEPOLIA_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    /// @notice Validator root emitter for protocol Cron ticks on Reactive Network.
    address internal constant CRON_EMITTER_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    /// @notice Reactive Network enforces >= 100,000 callback gas and <= 900,000 reactive tx gas.
    uint64 internal constant MIN_CALLBACK_GAS_LIMIT = 100_000;
    uint64 internal constant DEFAULT_CALLBACK_GAS_LIMIT = 450_000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant PRICE_SCALE = 1e18;

    /// @notice keccak256("PoolTickUpdated(bytes32,uint256,uint256,uint256,uint256)")
    uint256 internal constant POOL_TICK_UPDATED_TOPIC_0 =
        uint256(keccak256("PoolTickUpdated(bytes32,uint256,uint256,uint256,uint256)"));

    /// @notice keccak256("PositionArmed(uint256,address,bytes32,(bool,uint256,uint256,uint256,uint256,uint16,uint16,uint16,bool,uint64,uint64))")
    uint256 internal constant POSITION_ARMED_TOPIC_0 = uint256(
        keccak256(
            "PositionArmed(uint256,address,bytes32,(bool,uint256,uint256,uint256,uint256,uint16,uint16,uint16,bool,uint64,uint64))"
        )
    );

    /// @notice keccak256("PositionCancelled(uint256,address)")
    uint256 internal constant POSITION_CANCELLED_TOPIC_0 =
        uint256(keccak256("PositionCancelled(uint256,address)"));

    /// @notice keccak256("BracketSettled(uint256,address,(uint8,uint256,uint256,uint256,uint256,uint256,uint256))")
    uint256 internal constant BRACKET_SETTLED_TOPIC_0 = uint256(
        keccak256(
            "BracketSettled(uint256,address,(uint8,uint256,uint256,uint256,uint256,uint256,uint256))"
        )
    );

    /// @notice keccak256("SettlementDeferred(uint256,uint8,uint256,uint256,uint256)")
    uint256 internal constant SETTLEMENT_DEFERRED_TOPIC_0 =
        uint256(keccak256("SettlementDeferred(uint256,uint8,uint256,uint256,uint256)"));
}

enum TriggerKind {
    NONE,
    HARD_STOP_LOSS,
    TRAILING_STOP_LOSS,
    TAKE_PROFIT,
    CROSS_POOL_ARB_REBALANCE
}

enum PositionStatus {
    NONE,
    ACTIVE,
    IN_FLIGHT,
    SETTLED,
    CANCELLED,
    EXPIRED
}

struct ArmedPositionData {
    bool isBaseToQuote;
    uint256 amountIn;
    uint256 entryPriceE18;
    uint256 hardStopPriceE18;
    uint256 takeProfitPriceE18;
    uint16 trailingStopBps;
    uint16 maxDislocationBps;
    uint16 maxSlippageBps;
    bool enableCrossPoolArb;
    uint64 cooldownSec;
    uint64 expiresAt;
}

struct SettledEventData {
    uint8 triggerKind;
    uint256 amountIn;
    uint256 amountOut;
    uint256 executionPriceE18;
    uint256 originEventTimestamp;
    uint256 settledAtTimestamp;
    uint256 loopLatencySec;
}

interface IOmniBracketCallback {
    function executeBracketCallback(
        address reactiveSender_,
        uint256 positionId_,
        uint8 triggerKind_,
        uint256 referencePriceE18_,
        uint256 originEventTimestamp_
    ) external;
}
