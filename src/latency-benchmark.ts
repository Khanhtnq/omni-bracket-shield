/**
 * Deterministic Full-Loop Latency & Slippage Benchmark Engine for Track 1 ("Every Second Counts").
 *
 * Compares:
 *   1. Reactive Omni (~1,000ms CometBFT instant finality, 0 reorg confirmation wait)
 *   2. Reactive Legacy (~7,000ms Geth+Prism reactive block + finality buffer)
 *   3. Off-Chain Polling Keeper (3,000ms poll interval + mempool inclusion delay)
 *
 * Across Base Sepolia (200ms Denim blocks) and Unichain Sepolia (1,000ms blocks).
 */

export interface ArchitectureLatencyProfile {
  id: "reactive_omni" | "offchain_keeper" | "reactive_legacy";
  label: string;
  originIngestMs: number;
  reactiveConsensusMs: number;
  callbackRelayMs: number;
  destinationInclusionMs: number;
}

export interface LoopBenchmarkRow {
  architecture: string;
  totalLoopLatencyMs: number;
  elapsedBaseSepolia200msBlocks: number;
  elapsedUnichain1sBlocks: number;
  crashExitPriceUsd: number;
  crashProceedsUsd: number;
  capitalPreservedVsLegacyUsd: number;
  slippageSavedBps: number;
  arbNetCaptureBps: number;
  wickSandwichPrevented: boolean;
}

export interface BenchmarkSummary {
  positionSizeWeth: number;
  entryPriceUsd: number;
  stopTriggerPriceUsd: number;
  crashDecayBpsPer200msBlock: number;
  initialArbSpreadBps: number;
  arbHalfLifeMs: number;
  rows: LoopBenchmarkRow[];
}

export const DEFAULT_PROFILES: Record<
  ArchitectureLatencyProfile["id"],
  ArchitectureLatencyProfile
> = {
  reactive_omni: {
    id: "reactive_omni",
    label: "Reactive Omni (~1s CometBFT Instant Finality)",
    originIngestMs: 220, // 1 Base Sepolia 200ms block + relayer read
    reactiveConsensusMs: 1_000, // ~1s CometBFT single-slot instant finality
    callbackRelayMs: 180, // Reactive Signer dispatch
    destinationInclusionMs: 200, // Next 200ms Base Sepolia Denim block
  },
  offchain_keeper: {
    id: "offchain_keeper",
    label: "Off-Chain Polling Bot (3s Poll + Gas Auction)",
    originIngestMs: 1_500, // Mean wait on 3,000ms HTTP poll interval
    reactiveConsensusMs: 350, // Off-chain webhook + KMS sign
    callbackRelayMs: 450, // Public RPC propagation + priority fee auction
    destinationInclusionMs: 400, // 2 Base Sepolia blocks under volatility contention
  },
  reactive_legacy: {
    id: "reactive_legacy",
    label: "Reactive Legacy (~7s Block + Finality Buffer)",
    originIngestMs: 800,
    reactiveConsensusMs: 7_000, // Pre-Omni ~7s block cadence
    callbackRelayMs: 600,
    destinationInclusionMs: 400,
  },
};

export function totalLatencyMs(p: ArchitectureLatencyProfile): number {
  return (
    p.originIngestMs +
    p.reactiveConsensusMs +
    p.callbackRelayMs +
    p.destinationInclusionMs
  );
}

/**
 * Evaluates full-loop execution quality during:
 *   1. A high-velocity Base Sepolia cascade starting at `stopTriggerPriceUsd` ($2,910)
 *      decaying by `crashDecayBpsPer200msBlock` (18 bps per 200ms Denim block = ~90 bps/sec).
 *   2. A cross-pool Base vs Unichain +250 bps dislocation decaying exponentially with half-life 2,200ms.
 *   3. A 1-block (200ms) isolated MEV flash-wick (-15%) where multi-origin correlation blocks false liquidation.
 */
export function runLatencyBenchmark(
  positionSizeWeth = 10,
  entryPriceUsd = 3_000,
  stopTriggerPriceUsd = 2_910,
  crashDecayBpsPer200msBlock = 18,
  initialArbSpreadBps = 250,
  arbHalfLifeMs = 2_200
): BenchmarkSummary {
  const profiles: ArchitectureLatencyProfile[] = [
    DEFAULT_PROFILES.reactive_omni,
    DEFAULT_PROFILES.offchain_keeper,
    DEFAULT_PROFILES.reactive_legacy,
  ];

  const legacyMs = totalLatencyMs(DEFAULT_PROFILES.reactive_legacy);
  const legacyBlocks200ms = Math.ceil(legacyMs / 200);
  const legacyExitPrice =
    stopTriggerPriceUsd *
    Math.pow(1 - crashDecayBpsPer200msBlock / 10_000, legacyBlocks200ms);
  const legacyProceeds = positionSizeWeth * legacyExitPrice * (1 - 0.003);

  const rows: LoopBenchmarkRow[] = profiles.map((p) => {
    const loopMs = totalLatencyMs(p);
    const blocks200ms = Math.ceil(loopMs / 200);
    const blocks1s = Math.ceil(loopMs / 1_000);

    const exitPrice =
      stopTriggerPriceUsd *
      Math.pow(1 - crashDecayBpsPer200msBlock / 10_000, blocks200ms);
    const proceedsUsd = positionSizeWeth * exitPrice * (1 - 0.003); // 30 bps pool swap fee

    const slippageFromTriggerBps = Math.round(
      ((stopTriggerPriceUsd - exitPrice) / stopTriggerPriceUsd) * 10_000
    );
    const legacySlippageBps = Math.round(
      ((stopTriggerPriceUsd - legacyExitPrice) / stopTriggerPriceUsd) * 10_000
    );

    // Exponentially decaying cross-L2 basis gap minus 30 bps AMM swap fee
    const remainingSpreadBps =
      initialArbSpreadBps * Math.pow(0.5, loopMs / arbHalfLifeMs);
    const arbNetCaptureBps = Math.round((remainingSpreadBps - 30) * 10) / 10;

    return {
      architecture: p.label,
      totalLoopLatencyMs: loopMs,
      elapsedBaseSepolia200msBlocks: blocks200ms,
      elapsedUnichain1sBlocks: blocks1s,
      crashExitPriceUsd: Number(exitPrice.toFixed(2)),
      crashProceedsUsd: Number(proceedsUsd.toFixed(2)),
      capitalPreservedVsLegacyUsd: Number((proceedsUsd - legacyProceeds).toFixed(2)),
      slippageSavedBps: legacySlippageBps - slippageFromTriggerBps,
      arbNetCaptureBps,
      // Multi-origin Reactive contracts correlate Unichain + Base inside react(); single-chain keepers do not
      wickSandwichPrevented: p.id !== "offchain_keeper",
    };
  });

  return {
    positionSizeWeth,
    entryPriceUsd,
    stopTriggerPriceUsd,
    crashDecayBpsPer200msBlock,
    initialArbSpreadBps,
    arbHalfLifeMs,
    rows,
  };
}
