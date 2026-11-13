try {
  process.loadEnvFile?.(".env");
} catch {
  // .env is optional in CI / read-only benchmark environments
}

import { formatEther, parseGwei, type Address, type Hex } from "viem";
import { runDoctorSuite } from "./inspector.js";
import { runLatencyBenchmark } from "./latency-benchmark.js";
import { checkDeployerReadiness, executeAndMeasureLiveLoop } from "./live-loop.js";
import { OMNI_CONSTANTS, computeOmniFeeBudget } from "./networks.js";

function pad(text: string, width: number): string {
  return text.length >= width ? text.slice(0, width) : text.padEnd(width, " ");
}

async function handleDoctor(): Promise<void> {
  console.log("=== OmniBracket Shield :: Live Multi-Chain Reactive Omni Doctor ===");
  const reports = await runDoctorSuite();

  for (const r of reports) {
    console.log(`\n[${r.reachable ? "ONLINE" : "OFFLINE"}] ${r.network.name} (chainId=${r.network.chainId})`);
    console.log(`  RPC URL              : ${r.network.rpcUrl} (${r.rpcLatencyMs} ms RTT)`);
    console.log(`  System/Proxy Address : ${r.network.systemOrProxyAddress} (${r.systemBytecodeBytes} B bytecode)`);
    if (r.reachable) {
      console.log(`  Latest Block         : #${r.latestBlock.toString()} (nominal ${r.network.nominalBlockTimeMs} ms cadence)`);
      console.log(`  Base Fee             : ${r.baseFeeGwei} gwei`);
      console.log(
        `  Fee Parameters       : coeff=${r.gasPriceCoeffPer1000}/1000 | extraGas=${r.extraGas} | maxChargeGas=${r.maxChargeGas}`
      );
      console.log(
        `  Default 450k Gas     : ${r.forwardedGasAtDefaultLimit} forwarded gas | est. fee ${r.estimatedCallbackFeeEth} ${r.network.nativeSymbol}`
      );
      if (r.lasnaSequenceFrontier) {
        console.log(
          `  RNK Sequence Frontier: height=${r.lasnaSequenceFrontier.height} seq=[${r.lasnaSequenceFrontier.fromSeq}..${r.lasnaSequenceFrontier.toSeq}]`
        );
      }
    } else {
      console.log(`  Error                : ${r.error}`);
    }
  }
}

function handleBenchmark(): void {
  const b = runLatencyBenchmark();
  console.log("=== Track 1 ('Every Second Counts') :: Full-Loop Latency & Slippage Benchmark ===");
  console.log(
    `Position: ${b.positionSizeWeth} WETH | Entry: $${b.entryPriceUsd} | Stop Trigger: $${b.stopTriggerPriceUsd} | Cascade: -${b.crashDecayBpsPer200msBlock} bps / 200ms Base Sepolia block\n`
  );

  const header = [
    pad("Architecture", 44),
    pad("Loop(ms)", 10),
    pad("BaseBlks", 10),
    pad("Exit($)", 11),
    pad("Saved($)", 12),
    pad("Saved(bps)", 12),
    pad("ArbNet(bps)", 12),
    pad("AntiWick", 9),
  ].join(" | ");
  console.log(header);
  console.log("-".repeat(header.length));

  for (const row of b.rows) {
    console.log(
      [
        pad(row.architecture, 44),
        pad(String(row.totalLoopLatencyMs), 10),
        pad(String(row.elapsedBaseSepolia200msBlocks), 10),
        pad(`$${row.crashExitPriceUsd.toFixed(2)}`, 11),
        pad(`+$${row.capitalPreservedVsLegacyUsd.toFixed(2)}`, 12),
        pad(`+${row.slippageSavedBps} bps`, 12),
        pad(`${row.arbNetCaptureBps} bps`, 12),
        pad(row.wickSandwichPrevented ? "YES" : "NO", 9),
      ].join(" | ")
    );
  }
}

function handleFeeCalc(args: string[]): void {
  const gweiArg = args[0] ? Number(args[0]) : 0.05;
  const gasLimitArg = args[1] ? BigInt(args[1]) : OMNI_CONSTANTS.DEFAULT_CALLBACK_GAS_LIMIT;
  const quote = computeOmniFeeBudget(
    {
      baseFeeWei: parseGwei(gweiArg.toString()),
      gasPriceCoeffPer1000: 1100n,
      gasUsed: 185_000n,
      extraGas: 80_000n,
      maxChargeGas: 50_000n,
    },
    gasLimitArg
  );
  console.log("=== Reactive Omni Destination Callback Budget Calculator (Base Sepolia 84532) ===");
  console.log(`Requested Gas Limit  : ${gasLimitArg.toString()}`);
  console.log(`Proxy Overhead Gas   : ${quote.proxyOverheadGas.toString()} (80k extra + 50k charge)`);
  console.log(`Forwarded Target Gas : ${quote.forwardedExecutionGas.toString()}`);
  console.log(`Meets >=100k Minimum : ${quote.meetsMinimumCallbackGas}`);
  console.log(`Estimated Fee (ETH)  : ${formatEther(quote.totalFeeWei)} ETH @ ${gweiArg} gwei`);
}

async function handleLiveLoop(args: string[]): Promise<void> {
  const pk = process.env.DEPLOYER_PRIVATE_KEY as Hex | undefined;
  if (!pk) {
    console.log(
      "Set DEPLOYER_PRIVATE_KEY (plus deployed contract addresses) in .env to broadcast a live Base Sepolia <-> Lasna loop."
    );
    return;
  }
  const readiness = await checkDeployerReadiness(pk);
  console.log(
    `Deployer ${readiness.deployer} | Base: ${readiness.baseSepoliaEth} ETH | Unichain: ${readiness.unichainSepoliaEth} ETH | Lasna: ${readiness.lasnaLReact} lREACT`
  );

  const weth = process.env.BASE_TOKEN_VWETH as Address | undefined;
  const pool = process.env.BASE_SEPOLIA_POOL as Address | undefined;
  const uniPool = process.env.UNICHAIN_SEPOLIA_POOL as Address | undefined;
  const vault = process.env.DESTINATION_VAULT as Address | undefined;
  const sentinel = process.env.LASNA_SENTINEL_REACTIVE as Address | undefined;

  if (!weth || !pool || !vault || !sentinel) {
    console.log(
      "Deploy contracts first via `forge script script/DeployAndTriggerOmni.s.sol` (4-step pipeline in README.md), then populate .env."
    );
    return;
  }

  const runAllThree = args.includes("--all-three") || args.includes("--all");
  const scenarios = runAllThree
    ? [
        {
          scenarioLabel: "Loop 1 :: Hard Stop-Loss ($3,000 -> $2,820)",
          triggerPriceE18: 2_820_000_000_000_000_000_000n,
        },
        {
          scenarioLabel: "Loop 2 :: Take-Profit ($3,000 -> $3,350)",
          triggerPriceE18: 3_350_000_000_000_000_000_000n,
        },
        {
          scenarioLabel: "Loop 3 :: Dynamic Trailing Stop ($3,000 -> $3,220 rally -> $3,080 pullback)",
          rallyPriceE18: 3_220_000_000_000_000_000_000n,
          triggerPriceE18: 3_080_000_000_000_000_000_000n,
        },
      ]
    : [
        {
          scenarioLabel: "Hard Stop-Loss ($3,000 -> $2,820)",
          triggerPriceE18: 2_820_000_000_000_000_000_000n,
        },
      ];

  for (const s of scenarios) {
    const res = await executeAndMeasureLiveLoop({
      privateKeyHex: pk,
      wethAddress: weth,
      poolAddress: pool,
      unichainPoolAddress: uniPool,
      vaultAddress: vault,
      sentinelAddress: sentinel,
      scenarioLabel: s.scenarioLabel,
      rallyPriceE18: s.rallyPriceE18,
      triggerPriceE18: s.triggerPriceE18,
    });

    console.log(`\n=== LIVE REACTIVE OMNI FULL-LOOP SETTLEMENT RECORDED (${res.scenarioLabel}) ===`);
    console.log(`Position ID                : #${res.positionId.toString()}`);
    if (res.rallySetupTxHash) {
      console.log(
        `0a. Rally Ratchet Tx (Base): https://sepolia.basescan.org/tx/${res.rallySetupTxHash}`
      );
    }
    if (res.unichainConfirmTxHash) {
      console.log(
        `0b. Unichain Reference Tx  : https://sepolia.uniscan.xyz/tx/${res.unichainConfirmTxHash}`
      );
    }
    console.log(
      `1. Origin Event Tx (Base)  : https://sepolia.basescan.org/tx/${res.originTriggerTxHash}`
    );
    console.log(
      `2. Reactive Tx (Lasna)     : ${
        res.lasnaReactiveTxHash
          ? `https://lasna.reactscan.net/tx/${res.lasnaReactiveTxHash}`
          : "Pending indexer lookup via SYSTEM.getCallbacks"
      }`
    );
    console.log(
      `3. Callback Tx (Base)      : ${
        res.destinationCallbackTxHash
          ? `https://sepolia.basescan.org/tx/${res.destinationCallbackTxHash}`
          : "Confirmed on-chain (PositionStatus.SETTLED)"
      }`
    );
    console.log(`Wall-Clock Loop Latency    : ${res.wallClockElapsedMs} ms`);
    console.log(`On-Chain Timestamp Delta   : ${res.onChainLoopLatencySec.toString()} s`);
    console.log(`Settled Proceeds           : ${res.settledAmountOutUsdc} vUSDC`);
    console.log(
      `Lasna Sentinel Counters    : dispatched=${res.lasnaCallbacksDispatched} | completedLoops=${res.lasnaCompletedLoops}`
    );
  }
}

export async function runCli(argv: string[]): Promise<void> {
  const cmd = argv[2] ?? "benchmark";
  switch (cmd) {
    case "doctor":
      await handleDoctor();
      break;
    case "benchmark":
      handleBenchmark();
      break;
    case "fee-calc":
      handleFeeCalc(argv.slice(3));
      break;
    case "live-loop":
      await handleLiveLoop(argv.slice(3));
      break;
    default:
      throw new Error(`Unknown command '${cmd}'. Expected: doctor | benchmark | fee-calc | live-loop`);
  }
}

const isMain = process.argv[1] && process.argv[1].replace(/\\/g, "/").endsWith("src/cli.ts");
if (isMain) {
  runCli(process.argv).catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
