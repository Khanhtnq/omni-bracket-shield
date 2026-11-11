import {
  createPublicClient,
  createWalletClient,
  formatEther,
  http,
  parseAbi,
  parseAbiItem,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  OMNI_CONSTANTS,
  OMNI_NETWORKS,
  SYSTEM_OR_PROXY_ABI,
  baseSepoliaChain,
  lasnaChain,
  unichainSepoliaChain,
} from "./networks.js";

const VAULT_LIVE_ABI = parseAbi([
  "function openBracketPosition((bool isBaseToQuote, uint256 amountIn, uint256 hardStopPriceE18, uint256 takeProfitPriceE18, uint16 trailingStopBps, uint16 maxDislocationBps, uint16 maxSlippageBps, bool enableCrossPoolArb, uint64 cooldownSec, uint64 ttlSeconds) p_) returns (uint256)",
  "function getPosition(uint256 positionId_) view returns ((address owner, bytes32 pairId, bool isBaseToQuote, uint8 status, uint256 amountIn, uint256 entryPriceE18, uint256 hardStopPriceE18, uint256 takeProfitPriceE18, uint16 trailingStopBps, uint16 maxDislocationBps, uint16 maxSlippageBps, bool enableCrossPoolArb, uint64 cooldownSec, uint64 createdAt, uint64 expiresAt, uint64 lastAttemptAt, uint64 settledAt, uint8 deferralCount, uint256 amountOut, uint256 lastLoopLatencySec))",
]);

const POOL_LIVE_ABI = parseAbi([
  "function syncSpotPrice(uint256 targetSpotPriceE18_)",
  "function spotPriceE18() view returns (uint256)",
]);

const ERC20_LIVE_ABI = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address owner) view returns (uint256)",
]);

const SENTINEL_LIVE_ABI = parseAbi([
  "function callbacksDispatched() view returns (uint256)",
  "function completedLoops() view returns (uint256)",
  "function lastConfirmedLoopLatencySec() view returns (uint256)",
  "function activePositionCount() view returns (uint256)",
]);

const CALLBACK_DISPATCHED_EVENT = parseAbiItem(
  "event CallbackDispatched(uint256 indexed positionId, uint8 indexed triggerKind, uint256 primaryPriceE18, uint256 referencePriceE18, uint256 originTimestamp)"
);

const BRACKET_SETTLED_EVENT = parseAbiItem(
  "event BracketSettled(uint256 indexed positionId, address indexed owner, (uint8 triggerKind, uint256 amountIn, uint256 amountOut, uint256 executionPriceE18, uint256 originEventTimestamp, uint256 settledAtTimestamp, uint256 loopLatencySec) settlement)"
);

const FAUCET_ABI = parseAbi([
  "function request(address recipient) payable",
]);

export interface LiveLoopMeasurement {
  positionId: bigint;
  originTriggerTxHash: Hex;
  unichainConfirmTxHash?: Hex;
  lasnaReactiveTxHash?: Hex;
  destinationCallbackTxHash?: Hex;
  originBlockNumber: bigint;
  wallClockElapsedMs: number;
  onChainLoopLatencySec: bigint;
  settledAmountOutUsdc: string;
  lasnaCallbacksDispatched: bigint;
  lasnaCompletedLoops: bigint;
}

export async function checkDeployerReadiness(privateKeyHex: Hex): Promise<{
  deployer: Address;
  baseSepoliaEth: string;
  unichainSepoliaEth: string;
  lasnaLReact: string;
}> {
  const account = privateKeyToAccount(privateKeyHex);
  const baseClient = createPublicClient({
    chain: baseSepoliaChain,
    transport: http(OMNI_NETWORKS.baseSepolia.rpcUrl),
  });
  const uniClient = createPublicClient({
    chain: unichainSepoliaChain,
    transport: http(OMNI_NETWORKS.unichainSepolia.rpcUrl),
  });
  const lasnaClient = createPublicClient({
    chain: lasnaChain,
    transport: http(OMNI_NETWORKS.lasna.rpcUrl),
  });

  const [baseBal, uniBal, lasnaBal] = await Promise.all([
    baseClient.getBalance({ address: account.address }),
    uniClient.getBalance({ address: account.address }),
    lasnaClient.getBalance({ address: account.address }),
  ]);

  return {
    deployer: account.address,
    baseSepoliaEth: formatEther(baseBal),
    unichainSepoliaEth: formatEther(uniBal),
    lasnaLReact: formatEther(lasnaBal),
  };
}

export async function requestLReactFromBaseFaucet(
  privateKeyHex: Hex,
  ethValueWei: bigint
): Promise<Hex> {
  if (ethValueWei <= 0n || ethValueWei > 5_000_000_000_000_000_000n) {
    throw new Error("Base Sepolia lREACT faucet accepts > 0 and <= 5 ETH per request");
  }
  const account = privateKeyToAccount(privateKeyHex);
  const wallet = createWalletClient({
    account,
    chain: baseSepoliaChain,
    transport: http(OMNI_NETWORKS.baseSepolia.rpcUrl),
  });

  return wallet.writeContract({
    address: OMNI_CONSTANTS.BASE_SEPOLIA_FAUCET,
    abi: FAUCET_ABI,
    functionName: "request",
    args: [account.address],
    value: ethValueWei,
  });
}

export async function executeAndMeasureLiveLoop(opts: {
  privateKeyHex: Hex;
  wethAddress: Address;
  poolAddress: Address;
  unichainPoolAddress?: Address;
  vaultAddress: Address;
  sentinelAddress: Address;
  baselinePriceE18?: bigint;
  triggerPriceE18?: bigint;
  pollTimeoutMs?: number;
}): Promise<LiveLoopMeasurement> {
  const account = privateKeyToAccount(opts.privateKeyHex);
  const basePublic = createPublicClient({
    chain: baseSepoliaChain,
    transport: http(OMNI_NETWORKS.baseSepolia.rpcUrl),
  });
  const baseWallet = createWalletClient({
    account,
    chain: baseSepoliaChain,
    transport: http(OMNI_NETWORKS.baseSepolia.rpcUrl),
  });
  const uniPublic = createPublicClient({
    chain: unichainSepoliaChain,
    transport: http(OMNI_NETWORKS.unichainSepolia.rpcUrl),
  });
  const uniWallet = createWalletClient({
    account,
    chain: unichainSepoliaChain,
    transport: http(OMNI_NETWORKS.unichainSepolia.rpcUrl),
  });
  const lasnaPublic = createPublicClient({
    chain: lasnaChain,
    transport: http(OMNI_NETWORKS.lasna.rpcUrl),
  });

  // 1. Verify zero outstanding debt before firing live loop
  const [sentinelDebt, vaultDebt] = await Promise.all([
    lasnaPublic.readContract({
      address: OMNI_CONSTANTS.SYSTEM_CONTRACT,
      abi: SYSTEM_OR_PROXY_ABI,
      functionName: "debt",
      args: [opts.sentinelAddress],
    }),
    basePublic.readContract({
      address: OMNI_CONSTANTS.BASE_SEPOLIA_CALLBACK_PROXY,
      abi: SYSTEM_OR_PROXY_ABI,
      functionName: "debt",
      args: [opts.vaultAddress],
    }),
  ]);

  if (sentinelDebt > 0n) {
    throw new Error(`Reactive Sentinel has unpaid debt on Lasna: ${formatEther(sentinelDebt)} lREACT`);
  }
  if (vaultDebt > 0n) {
    throw new Error(`Destination Vault has unpaid debt on Base Sepolia: ${formatEther(vaultDebt)} ETH`);
  }

  // 2. Idempotent baseline spot normalization ($3,000) so consecutive runs never revert on hardStop >= spot
  const baselinePrice = opts.baselinePriceE18 ?? 3_000_000_000_000_000_000_000n;
  const minBand = 2_950_000_000_000_000_000_000n;
  const maxBand = 3_050_000_000_000_000_000_000n;

  if (opts.unichainPoolAddress) {
    const uniSpot = await uniPublic.readContract({
      address: opts.unichainPoolAddress,
      abi: POOL_LIVE_ABI,
      functionName: "spotPriceE18",
    });
    if (uniSpot < minBand || uniSpot > maxBand) {
      const resetUniHash = await uniWallet.writeContract({
        address: opts.unichainPoolAddress,
        abi: POOL_LIVE_ABI,
        functionName: "syncSpotPrice",
        args: [baselinePrice],
      });
      await uniPublic.waitForTransactionReceipt({ hash: resetUniHash });
    }
  }

  const baseSpot = await basePublic.readContract({
    address: opts.poolAddress,
    abi: POOL_LIVE_ABI,
    functionName: "spotPriceE18",
  });
  if (baseSpot < minBand || baseSpot > maxBand) {
    const resetBaseHash = await baseWallet.writeContract({
      address: opts.poolAddress,
      abi: POOL_LIVE_ABI,
      functionName: "syncSpotPrice",
      args: [baselinePrice],
    });
    await basePublic.waitForTransactionReceipt({ hash: resetBaseHash });
  }

  const approveHash = await baseWallet.writeContract({
    address: opts.wethAddress,
    abi: ERC20_LIVE_ABI,
    functionName: "approve",
    args: [opts.vaultAddress, 100_000_000_000_000_000_000n],
  });
  await basePublic.waitForTransactionReceipt({ hash: approveHash });

  // Use cross-pool anti-wick threshold (300 bps) when Unichain reference pool is active; 0 when single-chain
  const orderParams = {
    isBaseToQuote: true,
    amountIn: 1_000_000_000_000_000_000n, // 1 vWETH
    hardStopPriceE18: 2_850_000_000_000_000_000_000n,
    takeProfitPriceE18: 3_300_000_000_000_000_000_000n,
    trailingStopBps: 250,
    maxDislocationBps: opts.unichainPoolAddress ? 300 : 0,
    maxSlippageBps: 200,
    enableCrossPoolArb: false,
    cooldownSec: 2n,
    ttlSeconds: 3600n,
  };

  const simOpen = await basePublic.simulateContract({
    account,
    address: opts.vaultAddress,
    abi: VAULT_LIVE_ABI,
    functionName: "openBracketPosition",
    args: [orderParams],
  });
  const positionId = simOpen.result;
  const openHash = await baseWallet.writeContract(simOpen.request);
  await basePublic.waitForTransactionReceipt({ hash: openHash });

  // Wait briefly so Lasna indexes `PositionArmed` before firing the price trigger
  await new Promise((r) => setTimeout(r, 2_200));

  const lasnaStartBlock = await lasnaPublic.getBlockNumber();
  const targetTrigger = opts.triggerPriceE18 ?? 2_820_000_000_000_000_000_000n;

  // If Unichain Sepolia reference pool is configured, confirm directional move there first so anti-wick passes
  let unichainConfirmTxHash: Hex | undefined;
  if (opts.unichainPoolAddress) {
    const uniTarget = targetTrigger + 5_000_000_000_000_000_000n; // $2,825 (~17 bps within $2,820)
    unichainConfirmTxHash = await uniWallet.writeContract({
      address: opts.unichainPoolAddress,
      abi: POOL_LIVE_ABI,
      functionName: "syncSpotPrice",
      args: [uniTarget],
    });
    await uniPublic.waitForTransactionReceipt({ hash: unichainConfirmTxHash });
  }

  const tStart = performance.now();
  const originTriggerTxHash = await baseWallet.writeContract({
    address: opts.poolAddress,
    abi: POOL_LIVE_ABI,
    functionName: "syncSpotPrice",
    args: [targetTrigger],
  });
  const triggerReceipt = await basePublic.waitForTransactionReceipt({ hash: originTriggerTxHash });

  const timeoutMs = opts.pollTimeoutMs ?? 45_000;
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const pos = await basePublic.readContract({
      address: opts.vaultAddress,
      abi: VAULT_LIVE_ABI,
      functionName: "getPosition",
      args: [positionId],
    });

    // PositionStatus.SETTLED === 3
    if (Number(pos.status) === 3) {
      const wallClockElapsedMs = Math.round(performance.now() - tStart);
      const [lasnaCallbacksDispatched, lasnaCompletedLoops, lasnaLogs, baseSettledLogs] =
        await Promise.all([
          lasnaPublic.readContract({
            address: opts.sentinelAddress,
            abi: SENTINEL_LIVE_ABI,
            functionName: "callbacksDispatched",
          }),
          lasnaPublic.readContract({
            address: opts.sentinelAddress,
            abi: SENTINEL_LIVE_ABI,
            functionName: "completedLoops",
          }),
          lasnaPublic
            .getLogs({
              address: opts.sentinelAddress,
              event: CALLBACK_DISPATCHED_EVENT,
              args: { positionId },
              fromBlock: lasnaStartBlock > 5n ? lasnaStartBlock - 5n : 0n,
              toBlock: "latest",
            })
            .catch(() => []),
          basePublic
            .getLogs({
              address: opts.vaultAddress,
              event: BRACKET_SETTLED_EVENT,
              args: { positionId },
              fromBlock: triggerReceipt.blockNumber,
              toBlock: "latest",
            })
            .catch(() => []),
        ]);

      const lasnaReactiveTxHash =
        lasnaLogs.length > 0 ? lasnaLogs[lasnaLogs.length - 1].transactionHash : undefined;
      const destinationCallbackTxHash =
        baseSettledLogs.length > 0
          ? baseSettledLogs[baseSettledLogs.length - 1].transactionHash
          : undefined;

      return {
        positionId,
        originTriggerTxHash,
        unichainConfirmTxHash,
        lasnaReactiveTxHash,
        destinationCallbackTxHash,
        originBlockNumber: triggerReceipt.blockNumber,
        wallClockElapsedMs,
        onChainLoopLatencySec: pos.lastLoopLatencySec,
        settledAmountOutUsdc: formatEther(pos.amountOut),
        lasnaCallbacksDispatched,
        lasnaCompletedLoops,
      };
    }
    await new Promise((r) => setTimeout(r, 350));
  }

  throw new Error(`Timed out after ${timeoutMs}ms waiting for Reactive Omni callback settlement`);
}
