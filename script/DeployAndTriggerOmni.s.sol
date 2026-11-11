// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { OmniConstants } from "../contracts/interfaces/IOmniBracketTypes.sol";
import { MockERC20 } from "../contracts/origin/MockERC20.sol";
import { OmniPricePool } from "../contracts/origin/OmniPricePool.sol";
import { OmniBracketVault } from "../contracts/destination/OmniBracketVault.sol";
import { OmniSentinelReactive } from "../contracts/reactive/OmniSentinelReactive.sol";

interface IDepositProxy {
    function depositTo(address target_) external payable;
}

/**
 * @title DeployOriginPool
 * @notice Step 0: Deploy MockERC20 tokens + `OmniPricePool` and seed $3,000 spot liquidity on
 *         Base Sepolia (84532) and optionally Unichain Sepolia (1301).
 */
contract DeployOriginPool is Script {
    bytes32 internal constant PAIR_ID = keccak256("WETH/USDC");

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockERC20 weth = new MockERC20("Omni Virtual WETH", "vWETH");
        MockERC20 usdc = new MockERC20("Omni Virtual USDC", "vUSDC");
        OmniPricePool pool = new OmniPricePool(address(weth), address(usdc), PAIR_ID);

        weth.mint(deployer, 550e18);
        usdc.mint(deployer, 1_650_000e18);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.seedLiquidity(500e18, 1_500_000e18);

        vm.stopBroadcast();

        console2.log("CHAIN_ID:", block.chainid);
        console2.log("BASE_TOKEN_VWETH:", address(weth));
        console2.log("QUOTE_TOKEN_VUSDC:", address(usdc));
        console2.log("OMNI_PRICE_POOL:", address(pool));
    }
}

/**
 * @title DeployReactiveSentinel
 * @notice Step 1 of Reactive Omni 4-step deployment: Deploy `OmniSentinelReactive` on Reactive Lasna (5318007)
 *         and deposit operational lREACT into `SYSTEM` (`0x8888...8888`).
 */
contract DeployReactiveSentinel is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address primaryPool = vm.envAddress("BASE_SEPOLIA_POOL");
        address referencePool = vm.envOr("UNICHAIN_SEPOLIA_POOL", address(0));
        uint256 initialFundWei = vm.envOr("LASNA_FUND_WEI", uint256(0.5 ether));
        uint256 reserveDepositWei = vm.envOr("LASNA_RESERVE_WEI", uint256(0.5 ether));

        vm.startBroadcast(deployerKey);

        OmniSentinelReactive sentinel = new OmniSentinelReactive{ value: initialFundWei }(
            OmniConstants.BASE_SEPOLIA_CHAIN_ID,
            primaryPool,
            OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID,
            referencePool,
            OmniConstants.DEFAULT_CALLBACK_GAS_LIMIT
        );

        if (reserveDepositWei > 0) {
            IDepositProxy(OmniConstants.OMNI_SYSTEM_CONTRACT).depositTo{ value: reserveDepositWei }(
                address(sentinel)
            );
        }

        vm.stopBroadcast();

        console2.log("LASNA_SENTINEL_REACTIVE:", address(sentinel));
    }
}

/**
 * @title DeployDestinationVault
 * @notice Step 2 of Reactive Omni 4-step deployment: Deploy `OmniBracketVault` on Base Sepolia (84532)
 *         passing `(0x476F44b11F5C942c58f4c8E3d0300E5710743585, sentinelAddr, weth, usdc, pool, pairId)`
 *         and pre-funding CallbackProxy reserves in SepETH.
 */
contract DeployDestinationVault is Script {
    bytes32 internal constant PAIR_ID = keccak256("WETH/USDC");

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sentinelAddr = vm.envAddress("LASNA_SENTINEL_REACTIVE");
        address wethAddr = vm.envAddress("BASE_TOKEN_VWETH");
        address usdcAddr = vm.envAddress("QUOTE_TOKEN_VUSDC");
        address poolAddr = vm.envAddress("BASE_SEPOLIA_POOL");
        uint256 vaultBalanceWei = vm.envOr("VAULT_BALANCE_WEI", uint256(0.01 ether));
        uint256 proxyReserveWei = vm.envOr("PROXY_RESERVE_WEI", uint256(0.02 ether));

        address callbackProxy = block.chainid == OmniConstants.UNICHAIN_SEPOLIA_CHAIN_ID
            ? OmniConstants.UNICHAIN_SEPOLIA_CALLBACK_PROXY
            : OmniConstants.BASE_SEPOLIA_CALLBACK_PROXY;

        vm.startBroadcast(deployerKey);

        OmniBracketVault vault = new OmniBracketVault{ value: vaultBalanceWei }(
            IPayable(payable(callbackProxy)),
            sentinelAddr,
            wethAddr,
            usdcAddr,
            poolAddr,
            PAIR_ID
        );

        if (proxyReserveWei > 0) {
            IDepositProxy(callbackProxy).depositTo{ value: proxyReserveWei }(address(vault));
        }

        vm.stopBroadcast();

        console2.log("DESTINATION_VAULT:", address(vault));
        console2.log("CALLBACK_PROXY_USED:", callbackProxy);
    }
}

/**
 * @title WireVaultOnLasna
 * @notice Step 3 of Reactive Omni 4-step deployment: Bind `OmniBracketVault` onto `OmniSentinelReactive`
 *         on Reactive Lasna (5318007), activating lifecycle subscriptions.
 */
contract WireVaultOnLasna is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address payable sentinelAddr = payable(vm.envAddress("LASNA_SENTINEL_REACTIVE"));
        address vaultAddr = vm.envAddress("DESTINATION_VAULT");

        vm.startBroadcast(deployerKey);
        OmniSentinelReactive(sentinelAddr).configureVault(vaultAddr);
        vm.stopBroadcast();

        console2.log("WIRED_VAULT_TO_SENTINEL:", vaultAddr);
    }
}

/**
 * @title TriggerLiveBracketLoop
 * @notice End-to-end live loop driver on Base Sepolia (84532): arms a 1 vWETH trailing/hard-stop
 *         position on `OmniBracketVault`, then triggers a price move on `OmniPricePool` so
 *         Reactive Lasna dispatches the live cross-chain callback and records loop latency!
 */
contract TriggerLiveBracketLoop is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address wethAddr = vm.envAddress("BASE_TOKEN_VWETH");
        address poolAddr = vm.envAddress("BASE_SEPOLIA_POOL");
        address payable vaultAddr = payable(vm.envAddress("DESTINATION_VAULT"));
        address uniPoolAddr = vm.envOr("UNICHAIN_SEPOLIA_POOL", address(0));
        uint256 baselinePriceE18 = vm.envOr("BASELINE_PRICE_E18", uint256(3_000e18));
        uint256 targetTriggerPriceE18 = vm.envOr("TRIGGER_PRICE_E18", uint256(2_820e18));
        uint16 dislocationGuardBps = uniPoolAddr == address(0) ? 0 : 300;

        vm.startBroadcast(deployerKey);

        // Reset pool to baseline spot if a prior demo run left spot below the stop price
        uint256 currentSpot = OmniPricePool(poolAddr).spotPriceE18();
        if (currentSpot < 2_950e18 || currentSpot > 3_050e18) {
            OmniPricePool(poolAddr).syncSpotPrice(baselinePriceE18);
        }

        MockERC20(wethAddr).approve(vaultAddr, type(uint256).max);
        uint256 posId = OmniBracketVault(vaultAddr).openBracketPosition(
            OmniBracketVault.OrderParams({
                isBaseToQuote: true,
                amountIn: 1e18,
                hardStopPriceE18: 2_850e18,
                takeProfitPriceE18: 3_300e18,
                trailingStopBps: 250,
                maxDislocationBps: dislocationGuardBps,
                maxSlippageBps: 200,
                enableCrossPoolArb: false,
                cooldownSec: 2,
                ttlSeconds: 3600
            })
        );

        OmniPricePool(poolAddr).syncSpotPrice(targetTriggerPriceE18);

        vm.stopBroadcast();

        console2.log("ARMED_POSITION_ID:", posId);
        console2.log("TRIGGERED_SPOT_PRICE_E18:", targetTriggerPriceE18);
    }
}
