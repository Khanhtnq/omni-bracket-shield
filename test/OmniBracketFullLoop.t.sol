// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

import {
    OmniConstants,
    TriggerKind,
    PositionStatus
} from "../contracts/interfaces/IOmniBracketTypes.sol";
import { MockERC20 } from "../contracts/origin/MockERC20.sol";
import { OmniPricePool } from "../contracts/origin/OmniPricePool.sol";
import { OmniBracketVault } from "../contracts/destination/OmniBracketVault.sol";
import { OmniSentinelReactive } from "../contracts/reactive/OmniSentinelReactive.sol";
import { MockOmniSystemContract, MockOmniCallbackProxy } from "./mocks/MockOmniNetwork.sol";

contract OmniBracketFullLoopTest is Test {
    MockOmniSystemContract internal sys;
    MockOmniCallbackProxy internal baseProxy;

    MockERC20 internal baseWeth;
    MockERC20 internal baseUsdc;
    OmniPricePool internal basePool;

    MockERC20 internal uniWeth;
    MockERC20 internal uniUsdc;
    OmniPricePool internal uniPool;

    OmniSentinelReactive internal sentinel;
    OmniBracketVault internal vault;

    bytes32 internal constant PAIR_ID = keccak256("WETH/USDC");
    address internal trader = makeAddr("trader");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        vm.warp(1_762_850_000); // Deterministic starting timestamp

        // 1. Etch Reactive Omni SystemContract at canonical 0x8888...8888
        MockOmniSystemContract sysImpl = new MockOmniSystemContract();
        vm.etch(OmniConstants.OMNI_SYSTEM_CONTRACT, address(sysImpl).code);
        sys = MockOmniSystemContract(payable(OmniConstants.OMNI_SYSTEM_CONTRACT));

        // 2. Etch Base Sepolia CallbackProxy at canonical 0x476F44b11F5C942c58f4c8E3d0300E5710743585
        MockOmniCallbackProxy proxyImpl = new MockOmniCallbackProxy();
        vm.etch(OmniConstants.BASE_SEPOLIA_CALLBACK_PROXY, address(proxyImpl).code);
        baseProxy = MockOmniCallbackProxy(payable(OmniConstants.BASE_SEPOLIA_CALLBACK_PROXY));
        // Initialize storage values after vm.etch (storage doesn't copy with runtime bytecode)
        vm.store(OmniConstants.OMNI_SYSTEM_CONTRACT, bytes32(uint256(4)), bytes32(uint256(1000)));
        vm.store(OmniConstants.OMNI_SYSTEM_CONTRACT, bytes32(uint256(5)), bytes32(uint256(100_000)));
        vm.store(OmniConstants.OMNI_SYSTEM_CONTRACT, bytes32(uint256(6)), bytes32(uint256(50_000)));

        vm.store(OmniConstants.BASE_SEPOLIA_CALLBACK_PROXY, bytes32(uint256(2)), bytes32(uint256(1100)));
        vm.store(OmniConstants.BASE_SEPOLIA_CALLBACK_PROXY, bytes32(uint256(3)), bytes32(uint256(80_000)));
        vm.store(OmniConstants.BASE_SEPOLIA_CALLBACK_PROXY, bytes32(uint256(4)), bytes32(uint256(50_000)));

        // 3. Deploy Origin Pools on Base Sepolia (84532) & Unichain Sepolia (1301)
        baseWeth = new MockERC20("Virtual WETH", "vWETH");
        baseUsdc = new MockERC20("Virtual USDC", "vUSDC");
        basePool = new OmniPricePool(address(baseWeth), address(baseUsdc), PAIR_ID);

        uniWeth = new MockERC20("Unichain vWETH", "uWETH");
        uniUsdc = new MockERC20("Unichain vUSDC", "uUSDC");
        uniPool = new OmniPricePool(address(uniWeth), address(uniUsdc), PAIR_ID);

        // Seed deep liquidity: 500 WETH & 1,500,000 USDC ($3,000.00 spot) on both pools
        baseWeth.mint(address(this), 500e18);
        baseUsdc.mint(address(this), 1_500_000e18);
        baseWeth.approve(address(basePool), type(uint256).max);
        baseUsdc.approve(address(basePool), type(uint256).max);
        basePool.seedLiquidity(500e18, 1_500_000e18);

        uniWeth.mint(address(this), 500e18);
        uniUsdc.mint(address(this), 1_500_000e18);
        uniWeth.approve(address(uniPool), type(uint256).max);
        uniUsdc.approve(address(uniPool), type(uint256).max);
        uniPool.seedLiquidity(500e18, 1_500_000e18);

        // 4. Mandatory 4-Step Reactive Omni Deployment Order:
        // Step A: Deploy OmniSentinelReactive first
        sentinel = new OmniSentinelReactive{ value: 5 ether }(
            OmniConstants.BASE_SEPOLIA_CHAIN_ID,
            address(basePool),
            OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID,
            address(uniPool),
            OmniConstants.DEFAULT_CALLBACK_GAS_LIMIT
        );

        // Step B: Deploy OmniBracketVault passing callbackProxy & address(sentinel)
        vault = new OmniBracketVault{ value: 2 ether }(
            IPayable(payable(OmniConstants.BASE_SEPOLIA_CALLBACK_PROXY)),
            address(sentinel),
            address(baseWeth),
            address(baseUsdc),
            address(basePool),
            PAIR_ID
        );

        // Step C: Bind vault on OmniSentinelReactive
        sentinel.configureVault(address(vault));

        // Step D: Pre-fund reserves on SYSTEM and CallbackProxy
        sys.depositTo{ value: 2 ether }(address(sentinel));
        baseProxy.depositTo{ value: 1 ether }(address(vault));

        // Fund trader with tokens
        baseWeth.mint(trader, 50e18);
        baseUsdc.mint(trader, 150_000e18);
        vm.startPrank(trader);
        baseWeth.approve(address(vault), type(uint256).max);
        baseUsdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        // Prime initial ticks into Reactive state
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 3_000e18, 1);
        _syncPoolAndPropagate(OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID, uniPool, 3_000e18, 1);
    }

    // =========================================================================
    // Helper: Full Reactive Omni Event -> react() -> CallbackProxy -> Feedback
    // =========================================================================

    function _propagateLogs(Vm.Log[] memory logs_, uint256 originChainId_, uint256 omniFinalityLagSec_) internal {
        for (uint256 round = 0; round < 6; ++round) {
            if (logs_.length == 0) break;

            for (uint256 i = 0; i < logs_.length; ++i) {
                IReactive.LogRecord memory rec = _toLogRecord(logs_[i], originChainId_);
                address[] memory subs = sys.getMatchingSubscribers(rec);
                for (uint256 s = 0; s < subs.length; ++s) {
                    vm.prank(OmniConstants.OMNI_SYSTEM_CONTRACT);
                    IReactive(payable(subs[s])).react(rec);
                }
            }

            MockOmniSystemContract.QueuedCallback[] memory cbs = sys.drainQueuedCallbacks();
            if (cbs.length == 0) break;

            if (omniFinalityLagSec_ > 0) {
                vm.warp(block.timestamp + omniFinalityLagSec_);
            }

            vm.recordLogs();
            for (uint256 c = 0; c < cbs.length; ++c) {
                require(cbs[c].chainId == OmniConstants.BASE_SEPOLIA_CHAIN_ID, "Unexpected dest chain");
                (bool ok, ) = baseProxy.deliver(
                    cbs[c].sender,
                    cbs[c].recipient,
                    cbs[c].gasLimit,
                    cbs[c].payload,
                    0.0005 ether
                );
                assertTrue(ok, "Callback execution reverted unexpectedly");
            }
            logs_ = vm.getRecordedLogs();
            originChainId_ = OmniConstants.BASE_SEPOLIA_CHAIN_ID;
            omniFinalityLagSec_ = 0;
        }
    }

    function _syncPoolAndPropagate(
        uint256 chainId_,
        OmniPricePool pool_,
        uint256 targetSpotE18_,
        uint256 omniFinalityLagSec_
    ) internal {
        vm.recordLogs();
        pool_.syncSpotPrice(targetSpotE18_);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _propagateLogs(logs, chainId_, omniFinalityLagSec_);
    }

    function _openOrderAndPropagate(
        address user_,
        OmniBracketVault.OrderParams memory params_
    ) internal returns (uint256 posId) {
        vm.recordLogs();
        vm.prank(user_);
        posId = vault.openBracketPosition(params_);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _propagateLogs(logs, OmniConstants.BASE_SEPOLIA_CHAIN_ID, 0);
    }

    function _toLogRecord(Vm.Log memory vLog_, uint256 chainId_) internal view returns (IReactive.LogRecord memory r) {
        r.chainId = chainId_;
        r.contractAddress = vLog_.emitter;
        r.opCode = vLog_.topics.length;
        if (vLog_.topics.length > 0) r.topic0 = uint256(vLog_.topics[0]);
        if (vLog_.topics.length > 1) r.topic1 = uint256(vLog_.topics[1]);
        if (vLog_.topics.length > 2) r.topic2 = uint256(vLog_.topics[2]);
        if (vLog_.topics.length > 3) r.topic3 = uint256(vLog_.topics[3]);
        r.data = vLog_.data;
        r.blockNumber = block.number;
    }

    // =========================================================================
    // 1. Compiler Selector & 4-Step Deployment Invariants
    // =========================================================================

    function test_Topic0SelectorsMatchCompilerExactly() public pure {
        assertEq(OmniConstants.POOL_TICK_UPDATED_TOPIC_0, uint256(OmniPricePool.PoolTickUpdated.selector));
        assertEq(OmniConstants.POSITION_ARMED_TOPIC_0, uint256(OmniBracketVault.PositionArmed.selector));
        assertEq(OmniConstants.POSITION_CANCELLED_TOPIC_0, uint256(OmniBracketVault.PositionCancelled.selector));
        assertEq(OmniConstants.BRACKET_SETTLED_TOPIC_0, uint256(OmniBracketVault.BracketSettled.selector));
        assertEq(OmniConstants.SETTLEMENT_DEFERRED_TOPIC_0, uint256(OmniBracketVault.SettlementDeferred.selector));
    }

    function test_FourStepDeploymentSubscriptionsAndServiceProviders() public view {
        assertEq(address(sentinel._SERVICE_PROVIDER()), OmniConstants.OMNI_SYSTEM_CONTRACT);
        assertEq(address(vault._SERVICE_PROVIDER()), OmniConstants.BASE_SEPOLIA_CALLBACK_PROXY);
        assertEq(vault._CALLBACK_SENDER(), address(sentinel));
        assertEq(sentinel.vault(), address(vault));
        assertTrue(sentinel.monitoringActive());
        assertTrue(sentinel.vaultSubscribed());
        // 2 pool subscriptions + 4 vault lifecycle subscriptions = 6 total
        assertEq(sys.subscriptionCount(), 6);
    }

    // =========================================================================
    // 2. Trailing Stop Ratchet + ~1s Omni Closed-Loop Settlement
    // =========================================================================

    function test_TrailingStopRatchetAndClosedLoopSettlement() public {
        uint256 usdcBefore = baseUsdc.balanceOf(trader);

        uint256 posId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 2e18, // 2 WETH
                hardStopPriceE18: 2_800e18,
                takeProfitPriceE18: 3_600e18,
                trailingStopBps: 300, // 3.00% trailing stop
                maxDislocationBps: 250, // 2.50% cross-pool anti-wick threshold
                maxSlippageBps: 200, // 2.00% max AMM slippage
                enableCrossPoolArb: false,
                cooldownSec: 5,
                ttlSeconds: 3600
            })
        );

        assertEq(sentinel.activePositionCount(), 1);
        assertEq(sentinel.getTrackedPosition(posId).extremumPriceE18, 3_000e18);

        // Market rallies cleanly across both L2s: $3,000 -> $3,200 -> $3,400
        vm.warp(block.timestamp + 2);
        _syncPoolAndPropagate(OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID, uniPool, 3_200e18, 0);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 3_200e18, 0);
        assertEq(sentinel.getTrackedPosition(posId).extremumPriceE18, 3_200e18);
        assertEq(sentinel.callbacksDispatched(), 0); // Zero destination gas wasted during rally!

        vm.warp(block.timestamp + 2);
        _syncPoolAndPropagate(OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID, uniPool, 3_400e18, 0);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 3_400e18, 0);
        assertEq(sentinel.getTrackedPosition(posId).extremumPriceE18, 3_400e18);
        assertEq(sentinel.callbacksDispatched(), 0);

        // Pullback of ~4.12% to $3,260 (clears volatility-widened 3.75% trailing stop at $3,272.50 from $3,400 peak!)
        vm.warp(block.timestamp + 2);
        _syncPoolAndPropagate(OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID, uniPool, 3_260e18, 1);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 3_260e18, 1);

        // Verify closed-loop execution across Destination AND Reactive!
        OmniBracketVault.BracketPosition memory vPos = vault.getPosition(posId);
        assertEq(uint8(vPos.status), uint8(PositionStatus.SETTLED));
        assertEq(vPos.lastLoopLatencySec, 1); // ~1s Reactive Omni CometBFT finality!
        assertGt(vPos.amountOut, 6_470e18); // Locked in >$6,470 profit instead of riding back down to $2,800!
        assertEq(baseUsdc.balanceOf(trader) - usdcBefore, vPos.amountOut);

        // Reactive contract received BracketSettled feedback and pruned active list
        assertEq(uint8(sentinel.getTrackedPosition(posId).status), uint8(PositionStatus.SETTLED));
        assertEq(sentinel.activePositionCount(), 0);
        assertEq(sentinel.completedLoops(), 1);
        assertEq(sentinel.lastConfirmedLoopLatencySec(), 1);
    }

    // =========================================================================
    // 3. Take-Profit & Quote->Base (Buy-the-Dip) OCO Brackets
    // =========================================================================

    function test_TakeProfitBracketFullLoop() public {
        uint256 posId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 1e18,
                hardStopPriceE18: 2_850e18,
                takeProfitPriceE18: 3_150e18,
                trailingStopBps: 0,
                maxDislocationBps: 300,
                maxSlippageBps: 150,
                enableCrossPoolArb: false,
                cooldownSec: 3,
                ttlSeconds: 1800
            })
        );

        vm.warp(block.timestamp + 3);
        _syncPoolAndPropagate(OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID, uniPool, 3_160e18, 1);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 3_160e18, 1);

        OmniBracketVault.BracketPosition memory vPos = vault.getPosition(posId);
        assertEq(uint8(vPos.status), uint8(PositionStatus.SETTLED));
        assertGt(vPos.amountOut, 3_140e18);
        assertEq(sentinel.completedLoops(), 1);
    }

    function test_QuoteToBaseTrailingLowWaterMarkEntry() public {
        uint256 wethBefore = baseWeth.balanceOf(trader);

        // Trader escrows 3,000 USDC to buy WETH via trailing-rebound (+2% off low-water mark) or TP at $2,700
        uint256 posId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: false,
                amountIn: 3_000e18,
                hardStopPriceE18: 3_300e18,
                takeProfitPriceE18: 2_600e18,
                trailingStopBps: 200, // 2% rebound off trough
                maxDislocationBps: 300,
                maxSlippageBps: 200,
                enableCrossPoolArb: false,
                cooldownSec: 2,
                ttlSeconds: 3600
            })
        );

        // Price dips $3,000 -> $2,800: low-water mark ratchets downward to $2,800
        vm.warp(block.timestamp + 2);
        _syncPoolAndPropagate(OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID, uniPool, 2_800e18, 0);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 2_800e18, 0);
        assertEq(sentinel.getTrackedPosition(posId).extremumPriceE18, 2_800e18);
        assertEq(sentinel.callbacksDispatched(), 0);

        // Price rebounds +2.5% to $2,870 (>= $2,800 * 1.02 = $2,856): triggers entry swap into >1.04 WETH!
        vm.warp(block.timestamp + 2);
        _syncPoolAndPropagate(OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID, uniPool, 2_870e18, 1);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 2_870e18, 1);

        assertEq(uint8(vault.getPosition(posId).status), uint8(PositionStatus.SETTLED));
        assertGt(baseWeth.balanceOf(trader) - wethBefore, 1.03e18);
    }

    // =========================================================================
    // 4. Cross-Chain Anti-Wick Protection (Base Sepolia vs Unichain Sepolia)
    // =========================================================================

    function test_CrossChainAntiWickFilterBlocksSinglePoolSandwich() public {
        uint256 posId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 3e18,
                hardStopPriceE18: 2_850e18,
                takeProfitPriceE18: 3_500e18,
                trailingStopBps: 0,
                maxDislocationBps: 250, // Max 2.50% divergence vs Unichain reference
                maxSlippageBps: 200,
                enableCrossPoolArb: false,
                cooldownSec: 2,
                ttlSeconds: 3600
            })
        );

        // Isolated 200ms flash-loan wick on Base Sepolia to $2,550 (-15%), while Unichain stays at $3,000!
        vm.warp(block.timestamp + 1);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 2_550e18, 1);

        // Sentinel detects 1,764 bps dislocation > 250 bps and BLOCKS sandwich stop-out!
        assertEq(sentinel.wickManipulationsBlocked(), 1);
        assertEq(sentinel.callbacksDispatched(), 0);
        assertEq(uint8(vault.getPosition(posId).status), uint8(PositionStatus.ACTIVE));

        // Base Sepolia snaps back to $3,000 on next 200ms block; trader's 3 WETH is unharmed!
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 3_000e18, 0);
        assertEq(uint8(vault.getPosition(posId).status), uint8(PositionStatus.ACTIVE));

        // Now a genuine market-wide drop hits BOTH Unichain ($2,820) and Base ($2,810)
        vm.warp(block.timestamp + 3);
        _syncPoolAndPropagate(OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID, uniPool, 2_820e18, 0);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 2_810e18, 1);

        // Real drop confirmed across venues -> stop-loss executes immediately!
        assertEq(sentinel.callbacksDispatched(), 1);
        assertEq(uint8(vault.getPosition(posId).status), uint8(PositionStatus.SETTLED));
    }

    // =========================================================================
    // 5. Cross-Pool Arbitrage Rebalance on Venue Dislocation
    // =========================================================================

    function test_CrossPoolArbitrageCapturesBasePremiumOverUnichain() public {
        uint256 posId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 2e18,
                hardStopPriceE18: 2_700e18,
                takeProfitPriceE18: 3_800e18,
                trailingStopBps: 0,
                maxDislocationBps: 150, // Capture >= 1.50% cross-L2 basis gap
                maxSlippageBps: 150,
                enableCrossPoolArb: true,
                cooldownSec: 2,
                ttlSeconds: 3600
            })
        );

        // Base Sepolia dislocates upward to $3,075 while Unichain trades at $3,000 (+250 bps premium)
        vm.warp(block.timestamp + 2);
        _syncPoolAndPropagate(OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID, uniPool, 3_000e18, 0);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 3_075e18, 1);

        OmniBracketVault.BracketPosition memory vPos = vault.getPosition(posId);
        assertEq(uint8(vPos.status), uint8(PositionStatus.SETTLED));
        assertGt(vPos.amountOut, 6_100e18); // Captured ~$3,050+/WETH arb premium!
    }

    // =========================================================================
    // 6. Strict Security Guards (`onlySystem`, `onlyServiceProvider`, `onlyCallbackSender`)
    // =========================================================================

    function test_SecurityRejectsUnauthorizedReactAndSpoofedCallbacks() public {
        IReactive.LogRecord memory fakeLog;
        fakeLog.chainId = OmniConstants.BASE_SEPOLIA_CHAIN_ID;
        fakeLog.contractAddress = address(basePool);
        fakeLog.topic0 = OmniConstants.POOL_TICK_UPDATED_TOPIC_0;

        // 1. Direct caller to sentinel.react() MUST revert with NotAuthorized
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractPayer.NotAuthorized.selector,
                attacker,
                OmniConstants.OMNI_SYSTEM_CONTRACT
            )
        );
        sentinel.react(fakeLog);

        // 2. Direct caller to vault.executeBracketCallback() MUST revert with NotAuthorized
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractPayer.NotAuthorized.selector,
                attacker,
                OmniConstants.BASE_SEPOLIA_CALLBACK_PROXY
            )
        );
        vault.executeBracketCallback(address(sentinel), 1, uint8(TriggerKind.HARD_STOP_LOSS), 2_800e18, block.timestamp);

        // 3. Legitimate CallbackProxy forwarding a callback from an unauthorized Reactive contract MUST revert!
        bytes memory roguePayload = abi.encodeCall(
            vault.executeBracketCallback,
            (address(0), 1, uint8(TriggerKind.HARD_STOP_LOSS), 2_800e18, block.timestamp)
        );
        (bool ok, bytes memory ret) = baseProxy.deliver(
            attacker, // Rogue reactive contract address injected by CallbackProxy
            address(vault),
            OmniConstants.DEFAULT_CALLBACK_GAS_LIMIT,
            roguePayload,
            0
        );
        assertFalse(ok);
        assertEq(
            ret,
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, attacker, address(sentinel))
        );
    }

    // =========================================================================
    // 7. Base Sepolia 200ms Block Rule: Timestamp Cooldowns & Slippage Deferral
    // =========================================================================

    function test_SlippageDeferralDoesNotRevertAndRespectsTimestampCooldown() public {
        uint256 posId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 2e18,
                hardStopPriceE18: 2_900e18,
                takeProfitPriceE18: 0,
                trailingStopBps: 0,
                maxDislocationBps: 0,
                maxSlippageBps: 100, // 1.00% max slippage (covers 30 bps fee + 40 bps impact, rejects -4.8% gap)
                enableCrossPoolArb: false,
                cooldownSec: 10, // 10-second timestamp cooldown (50 Base Sepolia 200ms blocks)
                ttlSeconds: 600
            })
        );

        // Record trigger tick at $2,890 without auto-propagating callback yet
        vm.warp(block.timestamp + 2);
        vm.recordLogs();
        basePool.syncSpotPrice(2_890e18);
        Vm.Log[] memory tickLogs = vm.getRecordedLogs();

        // Deliver log to OmniSentinelReactive -> queues callback with referencePrice = $2,890
        IReactive.LogRecord memory rec = _toLogRecord(tickLogs[0], OmniConstants.BASE_SEPOLIA_CHAIN_ID);
        vm.prank(OmniConstants.OMNI_SYSTEM_CONTRACT);
        sentinel.react(rec);
        assertEq(sentinel.callbacksDispatched(), 1);
        assertEq(uint8(sentinel.getTrackedPosition(posId).status), uint8(PositionStatus.IN_FLIGHT));

        // Before callback lands on Base Sepolia, five 200ms blocks pass and price gaps down to $2,750 (-4.8%)
        vm.roll(block.number + 5); // Advance block count WITHOUT advancing timestamp past cooldown!
        basePool.syncSpotPrice(2_750e18);

        // Deliver queued callback -> vault gracefully defers instead of reverting!
        MockOmniSystemContract.QueuedCallback[] memory cbs = sys.drainQueuedCallbacks();
        vm.recordLogs();
        (bool ok, ) = baseProxy.deliver(cbs[0].sender, cbs[0].recipient, cbs[0].gasLimit, cbs[0].payload, 0);
        assertTrue(ok);
        assertEq(vault.totalDeferredCount(), 1);
        assertEq(uint8(vault.getPosition(posId).status), uint8(PositionStatus.ACTIVE));

        // Feed SettlementDeferred back to Reactive -> unlocks IN_FLIGHT back to ACTIVE
        _propagateLogs(vm.getRecordedLogs(), OmniConstants.BASE_SEPOLIA_CHAIN_ID, 0);
        assertEq(uint8(sentinel.getTrackedPosition(posId).status), uint8(PositionStatus.ACTIVE));

        // 20 Base Sepolia blocks (4 seconds) pass — still < 10s timestamp cooldown! Even if blocks rose +20, must NOT fire!
        vm.roll(block.number + 20);
        vm.warp(block.timestamp + 4);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 2_880e18, 0);
        assertEq(sentinel.callbacksDispatched(), 1); // Timestamp cooldown strictly enforced!

        // Advance remaining 7 seconds (total 11s >= 10s cooldownSec): retries and settles cleanly!
        vm.warp(block.timestamp + 7);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 2_880e18, 1);
        assertEq(sentinel.callbacksDispatched(), 2);
        assertEq(uint8(vault.getPosition(posId).status), uint8(PositionStatus.SETTLED));
    }

    // =========================================================================
    // 8. Cancellation, Expiration, Economy Debt Settlement & Cron100 Recovery
    // =========================================================================

    function test_CancelAndTimestampExpirationRefundEscrow() public {
        uint256 wethStart = baseWeth.balanceOf(trader);

        uint256 cancelId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 1e18,
                hardStopPriceE18: 2_800e18,
                takeProfitPriceE18: 3_400e18,
                trailingStopBps: 0,
                maxDislocationBps: 0,
                maxSlippageBps: 100,
                enableCrossPoolArb: false,
                cooldownSec: 2,
                ttlSeconds: 120
            })
        );

        vm.recordLogs();
        vm.prank(trader);
        vault.cancelPosition(cancelId);
        _propagateLogs(vm.getRecordedLogs(), OmniConstants.BASE_SEPOLIA_CHAIN_ID, 0);

        assertEq(uint8(sentinel.getTrackedPosition(cancelId).status), uint8(PositionStatus.CANCELLED));
        assertEq(sentinel.activePositionCount(), 0);
        assertEq(baseWeth.balanceOf(trader), wethStart);

        // Open expiring order with 30-second TTL
        uint256 expId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 1e18,
                hardStopPriceE18: 2_800e18,
                takeProfitPriceE18: 3_400e18,
                trailingStopBps: 0,
                maxDislocationBps: 0,
                maxSlippageBps: 100,
                enableCrossPoolArb: false,
                cooldownSec: 2,
                ttlSeconds: 30
            })
        );

        // Before 30s timestamp deadline, reclaimExpired reverts even if 500 blocks elapsed!
        vm.roll(block.number + 500);
        vm.expectRevert(OmniBracketVault.PositionNotExpired.selector);
        vault.reclaimExpired(expId);

        // After 30s timestamp deadline, reclaimExpired refunds cleanly
        vm.warp(block.timestamp + 31);
        vault.reclaimExpired(expId);
        assertEq(uint8(vault.getPosition(expId).status), uint8(PositionStatus.EXPIRED));
        assertEq(baseWeth.balanceOf(trader), wethStart);
    }

    function test_EconomyDebtSettlementViaPayAndCoverDebt() public {
        // Simulate accrued debt on both SYSTEM and CallbackProxy
        sys.setMockDebt(address(sentinel), 0.25 ether);
        baseProxy.setMockDebt(address(vault), 0.15 ether);
        assertEq(sys.debt(address(sentinel)), 0.25 ether);
        assertEq(baseProxy.debt(address(vault)), 0.15 ether);

        // Settle via public coverDebt() wrappers
        sentinel.coverDebt();
        vault.coverDebt();

        assertEq(sys.debt(address(sentinel)), 0);
        assertEq(baseProxy.debt(address(vault)), 0);
    }

    function test_PauseResumeSubscriptionsAndCron100StaleInFlightSweep() public {
        uint256 initialSubs = sys.subscriptionCount();
        sentinel.pauseMonitoring();
        assertFalse(sentinel.monitoringActive());
        assertEq(sys.subscriptionCount(), 0);

        sentinel.resumeMonitoring();
        assertTrue(sentinel.monitoringActive());
        assertEq(sys.subscriptionCount(), initialSubs);

        // Enable Cron100 subscription
        sentinel.setCronHeartbeat(true);
        assertTrue(sentinel.cronSubscribed());
        assertEq(sys.subscriptionCount(), initialSubs + 1);

        // Arm an order and leave it IN_FLIGHT without callback feedback
        uint256 posId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 1e18,
                hardStopPriceE18: 2_900e18,
                takeProfitPriceE18: 0,
                trailingStopBps: 0,
                maxDislocationBps: 0,
                maxSlippageBps: 100,
                enableCrossPoolArb: false,
                cooldownSec: 2,
                ttlSeconds: 0
            })
        );

        vm.warp(block.timestamp + 2);
        vm.recordLogs();
        basePool.syncSpotPrice(2_880e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.prank(OmniConstants.OMNI_SYSTEM_CONTRACT);
        sentinel.react(_toLogRecord(logs[0], OmniConstants.BASE_SEPOLIA_CHAIN_ID));
        sys.drainQueuedCallbacks();
        assertEq(uint8(sentinel.getTrackedPosition(posId).status), uint8(PositionStatus.IN_FLIGHT));

        // Advance past IN_FLIGHT_TIMEOUT_SEC (60s) and deliver Cron100 tick from 0x0000...fffFfF
        vm.warp(block.timestamp + 65);
        IReactive.LogRecord memory cronLog;
        cronLog.chainId = block.chainid;
        cronLog.contractAddress = OmniConstants.CRON_EMITTER_ADDR;
        cronLog.topic0 = OmniConstants.CRON100_TOPIC_0;
        cronLog.opCode = 1;
        cronLog.data = abi.encode(block.number);

        vm.prank(OmniConstants.OMNI_SYSTEM_CONTRACT);
        sentinel.react(cronLog);

        // Stale IN_FLIGHT position automatically unlocked back to ACTIVE!
        assertEq(uint8(sentinel.getTrackedPosition(posId).status), uint8(PositionStatus.ACTIVE));
    }

    // =========================================================================
    // 9. Fuzz Test: Trailing Stop High-Water Mark & Trigger Invariants
    // =========================================================================

    function testFuzz_TrailingStopInvariants(
        uint16 trailBps_,
        uint16 rallyBps_,
        uint16 drawdownBps_
    ) public {
        trailBps_ = uint16(bound(trailBps_, 50, 2_000)); // 0.50% .. 20.00%
        rallyBps_ = uint16(bound(rallyBps_, 10, 4_000)); // +0.10% .. +40.00%
        drawdownBps_ = uint16(bound(drawdownBps_, 1, 3_500)); // -0.01% .. -35.00%

        // Disable cross-pool ref check so fuzz isolates trailing math cleanly across single-venue moves
        sentinel.setReferenceMaxAgeSec(0);

        uint256 posId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 0.5e18,
                hardStopPriceE18: 0,
                takeProfitPriceE18: 0,
                trailingStopBps: trailBps_,
                maxDislocationBps: 0,
                maxSlippageBps: 500,
                enableCrossPoolArb: false,
                cooldownSec: 2,
                ttlSeconds: 0
            })
        );

        // Apply smooth 4-step rally so instantaneous volatility stays realistic (<150 bps if moderate)
        uint256 peakPrice = (3_000e18 * (10_000 + uint256(rallyBps_))) / 10_000;
        vm.warp(block.timestamp + 2);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, peakPrice, 0);

        assertEq(sentinel.getTrackedPosition(posId).extremumPriceE18, peakPrice);
        assertEq(sentinel.callbacksDispatched(), 0);

        // Apply pullback from peak
        uint256 pullbackPrice = (peakPrice * (10_000 - uint256(drawdownBps_))) / 10_000;
        vm.warp(block.timestamp + 2);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, pullbackPrice, 1);

        // Account for dynamic volatility widening (1.0x or 1.25x trailBps)
        ( , , uint256 volBps, , ) = sentinel.primaryFeed();
        uint256 effectiveTrailBps = volBps >= sentinel.HIGH_VOL_THRESHOLD_BPS()
            ? uint256(trailBps_) + (uint256(trailBps_) / 4)
            : uint256(trailBps_);
        if (effectiveTrailBps >= 10_000) effectiveTrailBps = trailBps_;

        uint256 expectedStop = (peakPrice * (10_000 - effectiveTrailBps)) / 10_000;
        if (pullbackPrice <= expectedStop) {
            assertEq(sentinel.callbacksDispatched(), 1);
            assertEq(uint8(vault.getPosition(posId).status), uint8(PositionStatus.SETTLED));
        } else {
            assertEq(sentinel.callbacksDispatched(), 0);
            assertEq(uint8(vault.getPosition(posId).status), uint8(PositionStatus.ACTIVE));
        }
    }

    // =========================================================================
    // 10. Adversarial Hardening: Anti-Griefing, Bounded Deferrals, 900k Gas Cap & Round-Robin
    // =========================================================================

    function test_RejectsGriefingOrderParamsBelowFeeOrMinCooldownOrDust() public {
        // 1. Dust amountIn < MIN_ORDER_AMOUNT (1e15) reverts
        vm.prank(trader);
        vm.expectRevert(OmniBracketVault.InvalidOrderConfiguration.selector);
        vault.openBracketPosition(
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 100, // < 1e15
                hardStopPriceE18: 2_850e18,
                takeProfitPriceE18: 0,
                trailingStopBps: 0,
                maxDislocationBps: 0,
                maxSlippageBps: 100,
                enableCrossPoolArb: false,
                cooldownSec: 2,
                ttlSeconds: 600
            })
        );

        // 2. Zero cooldownSec (< MIN_COOLDOWN_SEC = 2) reverts
        vm.prank(trader);
        vm.expectRevert(OmniBracketVault.InvalidOrderConfiguration.selector);
        vault.openBracketPosition(
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 1e18,
                hardStopPriceE18: 2_850e18,
                takeProfitPriceE18: 0,
                trailingStopBps: 0,
                maxDislocationBps: 0,
                maxSlippageBps: 100,
                enableCrossPoolArb: false,
                cooldownSec: 0,
                ttlSeconds: 600
            })
        );

        // 3. Unfillable maxSlippageBps <= SWAP_FEE_BPS (30 bps) reverts
        vm.prank(trader);
        vm.expectRevert(OmniBracketVault.InvalidOrderConfiguration.selector);
        vault.openBracketPosition(
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 1e18,
                hardStopPriceE18: 2_850e18,
                takeProfitPriceE18: 0,
                trailingStopBps: 0,
                maxDislocationBps: 0,
                maxSlippageBps: 30, // <= 30 bps pool swap fee
                enableCrossPoolArb: false,
                cooldownSec: 2,
                ttlSeconds: 600
            })
        );
    }

    function test_MaxDeferralRetriesAutoRefundsAndPrunesActiveQueue() public {
        uint256 wethStart = baseWeth.balanceOf(trader);

        // Order size 20 WETH in 500 WETH pool has ~3.85% AMM price impact + 0.30% fee > 50 bps maxSlippageBps,
        // forcing persistent slippage deferral on every callback until MAX_DEFERRAL_RETRIES (5) auto-cancels!
        uint256 posId = _openOrderAndPropagate(
            trader,
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 20e18,
                hardStopPriceE18: 2_900e18,
                takeProfitPriceE18: 0,
                trailingStopBps: 0,
                maxDislocationBps: 0,
                maxSlippageBps: 50,
                enableCrossPoolArb: false,
                cooldownSec: 3,
                ttlSeconds: 3600
            })
        );

        uint256 ts = block.timestamp;
        for (uint256 attempt = 1; attempt <= 5; ++attempt) {
            ts += 4;
            vm.warp(ts);
            _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 2_880e18, 0);
        }

        // After 5th deferral, vault auto-cancelled, refunded 100% of 20 WETH, and Reactive pruned the queue!
        OmniBracketVault.BracketPosition memory vPos = vault.getPosition(posId);
        assertEq(uint8(vPos.status), uint8(PositionStatus.CANCELLED));
        assertEq(vPos.deferralCount, 5);
        assertEq(baseWeth.balanceOf(trader), wethStart);
        assertEq(sentinel.activePositionCount(), 0);
        assertEq(uint8(sentinel.getTrackedPosition(posId).status), uint8(PositionStatus.CANCELLED));
    }

    function test_BatchDispatchCapAndRoundRobinPrevents900kOogAndStarvation() public {
        sentinel.setReferenceMaxAgeSec(0);
        baseWeth.mint(trader, 100e18);

        // 1. Arm 16 deep-OTM orders (hardStop = $1,500) filling window 1 [0..15],
        //    followed by 4 ITM orders (indices 16..19, hardStop = $2,900) beyond MAX_ACTIVE_SCAN (16).
        for (uint256 i = 0; i < 16; ++i) {
            _openOrderAndPropagate(
                trader,
                OmniBracketVault.OrderParams({
                    isBaseToQuote: true,
                    amountIn: 0.1e18,
                    hardStopPriceE18: 1_500e18,
                    takeProfitPriceE18: 0,
                    trailingStopBps: 0,
                    maxDislocationBps: 0,
                    maxSlippageBps: 200,
                    enableCrossPoolArb: false,
                    cooldownSec: 2,
                    ttlSeconds: 0
                })
            );
        }

        uint256[] memory tailIds = new uint256[](4);
        for (uint256 j = 0; j < 4; ++j) {
            tailIds[j] = _openOrderAndPropagate(
                trader,
                OmniBracketVault.OrderParams({
                    isBaseToQuote: true,
                    amountIn: 0.1e18,
                    hardStopPriceE18: 2_900e18,
                    takeProfitPriceE18: 0,
                    trailingStopBps: 0,
                    maxDislocationBps: 0,
                    maxSlippageBps: 200,
                    enableCrossPoolArb: false,
                    cooldownSec: 2,
                    ttlSeconds: 0
                })
            );
        }

        assertEq(sentinel.activePositionCount(), 20);

        uint256 ts = block.timestamp;
        // Tick 1 scans [0..15] -> cursor 16; Tick 2 settles 2 tail orders (MAX_CALLBACKS_PER_TICK=2) -> cursor 18; Tick 3 settles remaining 2 tail orders!
        ts += 3;
        vm.warp(ts);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 2_850e18, 1);
        ts = block.timestamp + 3;
        vm.warp(ts);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 2_850e18, 1);
        ts = block.timestamp + 3;
        vm.warp(ts);
        _syncPoolAndPropagate(OmniConstants.BASE_SEPOLIA_CHAIN_ID, basePool, 2_850e18, 1);

        for (uint256 j = 0; j < 4; ++j) {
            assertEq(uint8(vault.getPosition(tailIds[j]).status), uint8(PositionStatus.SETTLED));
        }

        // 2. Verify MAX_CALLBACKS_PER_TICK (2) keeps single react() execution strictly < 900,000 gas cap (even under --gas-report)!
        basePool.syncSpotPrice(3_000e18);
        for (uint256 k = 0; k < 8; ++k) {
            _openOrderAndPropagate(
                trader,
                OmniBracketVault.OrderParams({
                    isBaseToQuote: true,
                    amountIn: 0.1e18,
                    hardStopPriceE18: 2_920e18,
                    takeProfitPriceE18: 0,
                    trailingStopBps: 0,
                    maxDislocationBps: 0,
                    maxSlippageBps: 300,
                    enableCrossPoolArb: false,
                    cooldownSec: 2,
                    ttlSeconds: 0
                })
            );
        }

        ts = block.timestamp + 3;
        vm.warp(ts);
        vm.recordLogs();
        basePool.syncSpotPrice(2_880e18);
        Vm.Log[] memory tickLogs = vm.getRecordedLogs();
        IReactive.LogRecord memory rec = _toLogRecord(tickLogs[0], OmniConstants.BASE_SEPOLIA_CHAIN_ID);

        // First react() scans window and caps dispatches at MAX_CALLBACKS_PER_TICK (2) well under 900k gas cap
        vm.prank(OmniConstants.OMNI_SYSTEM_CONTRACT);
        uint256 g0 = gasleft();
        sentinel.react(rec);
        uint256 gasUsed = g0 - gasleft();
        assertLt(gasUsed, 900_000, "react() must stay strictly below Reactive Omni 900k gas cap");

        // Second react() fires the remaining spillover orders cleanly, also strictly under 900k gas cap
        vm.prank(OmniConstants.OMNI_SYSTEM_CONTRACT);
        uint256 g1 = gasleft();
        sentinel.react(rec);
        uint256 gasUsed2 = g1 - gasleft();
        assertLt(gasUsed2, 900_000, "react() batch 2 must stay strictly below 900k gas cap");
    }

    function test_DuplicateLogReplayIdempotenceCronPauseAndWithdrawNative() public {
        vm.recordLogs();
        vm.prank(trader);
        uint256 posId = vault.openBracketPosition(
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 1e18,
                hardStopPriceE18: 2_800e18,
                takeProfitPriceE18: 3_400e18,
                trailingStopBps: 0,
                maxDislocationBps: 0,
                maxSlippageBps: 150,
                enableCrossPoolArb: false,
                cooldownSec: 2,
                ttlSeconds: 600
            })
        );
        Vm.Log[] memory armedLogs = vm.getRecordedLogs();
        // Find PositionArmed log (emitter == address(vault))
        IReactive.LogRecord memory armedRec;
        for (uint256 i = 0; i < armedLogs.length; ++i) {
            if (armedLogs[i].emitter == address(vault)) {
                armedRec = _toLogRecord(armedLogs[i], OmniConstants.BASE_SEPOLIA_CHAIN_ID);
                break;
            }
        }

        // Deliver PositionArmed twice: duplicate replay must be a no-op
        vm.prank(OmniConstants.OMNI_SYSTEM_CONTRACT);
        sentinel.react(armedRec);
        vm.prank(OmniConstants.OMNI_SYSTEM_CONTRACT);
        sentinel.react(armedRec);
        assertEq(sentinel.activePositionCount(), 1);
        assertEq(uint8(sentinel.getTrackedPosition(posId).status), uint8(PositionStatus.ACTIVE));

        // Enable Cron100, then pauseMonitoring(): ALL subscriptions including Cron100 must hit 0!
        sentinel.setCronHeartbeat(true);
        assertTrue(sentinel.cronSubscribed());
        sentinel.pauseMonitoring();
        assertFalse(sentinel.cronSubscribed());
        assertEq(sys.subscriptionCount(), 0);

        // resumeMonitoring() automatically restores Cron100 as well
        sentinel.resumeMonitoring();
        assertTrue(sentinel.cronSubscribed());
        assertEq(sys.subscriptionCount(), 7);

        // withdrawNative settles debt first and transfers surplus native currency without touching ERC-20 escrow
        address payable treasury = payable(makeAddr("treasury"));
        sys.setMockDebt(address(sentinel), 0.2 ether);
        baseProxy.setMockDebt(address(vault), 0.1 ether);

        sentinel.withdrawNative(treasury, 1 ether);
        vault.withdrawNative(treasury, 0.5 ether);

        assertEq(sys.debt(address(sentinel)), 0);
        assertEq(baseProxy.debt(address(vault)), 0);
        assertEq(treasury.balance, 1.5 ether);
        // Trader's 1 WETH escrow inside vault remains 100% intact
        assertEq(baseWeth.balanceOf(address(vault)), 1e18);
    }
}
