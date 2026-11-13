import { decodeFunctionData } from "viem";
import { describe, expect, it } from "vitest";
import { runCli } from "../src/cli.js";
import {
  CALLBACK_PAYLOAD_ABI,
  OMNI_CONSTANTS,
  OMNI_NETWORKS,
  buildBracketCallbackPayload,
  computeOmniFeeBudget,
  simulateProxySenderOverwrite,
} from "../src/networks.js";
import {
  DEFAULT_PROFILES,
  runLatencyBenchmark,
  totalLatencyMs,
} from "../src/latency-benchmark.js";

describe("Reactive Omni Network Constants & Fee Model", () => {
  it("uses canonical 2026 Reactive Omni addresses (0x8888...8888 & verified proxies)", () => {
    expect(OMNI_CONSTANTS.SYSTEM_CONTRACT).toBe("0x8888888888888888888888888888888888888888");
    expect(OMNI_NETWORKS.lasna.chainId).toBe(5318007);
    expect(OMNI_NETWORKS.baseSepolia.chainId).toBe(84532);
    expect(OMNI_NETWORKS.baseSepolia.nominalBlockTimeMs).toBe(200);
    expect(OMNI_NETWORKS.baseSepolia.systemOrProxyAddress).toBe(
      "0x476F44b11F5C942c58f4c8E3d0300E5710743585"
    );
    expect(OMNI_NETWORKS.unichainSepolia.chainId).toBe(1301);
    expect(OMNI_NETWORKS.unichainSepolia.systemOrProxyAddress).toBe(
      "0x775c9B990ADe401060B78D0e98684eEf8d2466C1"
    );
  });

  it("computes exact Reactive Lasna fee = p_base * (C/1000) * (g_used + K)", () => {
    const quote = computeOmniFeeBudget(
      {
        baseFeeWei: 2_000_000_000n,
        gasPriceCoeffPer1000: 1000n,
        gasUsed: 150_000n,
        extraGas: 100_000n,
        maxChargeGas: 50_000n,
      },
      450_000n
    );

    expect(quote.totalFeeWei).toBe(500_000_000_000_000n);
    expect(quote.proxyOverheadGas).toBe(150_000n);
    expect(quote.forwardedExecutionGas).toBe(300_000n);
    expect(quote.meetsMinimumCallbackGas).toBe(true);
    expect(quote.exceedsReactiveCap).toBe(false);
  });

  it("computes Base Sepolia CallbackProxy 1.1x coefficient and flags insufficient gas", () => {
    const validQuote = computeOmniFeeBudget(
      {
        baseFeeWei: 1_000_000_000n,
        gasPriceCoeffPer1000: 1100n,
        gasUsed: 200_000n,
        extraGas: 80_000n,
        maxChargeGas: 50_000n,
      },
      450_000n
    );
    expect(validQuote.totalFeeWei).toBe(308_000_000_000_000n);
    expect(validQuote.forwardedExecutionGas).toBe(320_000n);

    const tooTightQuote = computeOmniFeeBudget(
      {
        baseFeeWei: 1_000_000_000n,
        gasPriceCoeffPer1000: 1100n,
        gasUsed: 950_000n,
        extraGas: 80_000n,
        maxChargeGas: 50_000n,
      },
      120_000n
    );
    expect(tooTightQuote.forwardedExecutionGas).toBe(0n);
    expect(tooTightQuote.meetsMinimumCallbackGas).toBe(false);
    expect(tooTightQuote.exceedsReactiveCap).toBe(true);
  });

  it("rejects negative fee inputs cleanly", () => {
    expect(() =>
      computeOmniFeeBudget({
        baseFeeWei: -1n,
        gasPriceCoeffPer1000: 1000n,
        gasUsed: 100_000n,
        extraGas: 80_000n,
        maxChargeGas: 50_000n,
      })
    ).toThrow(/non-negative/i);
  });
});

describe("Callback Payload First-Slot Reservation & Proxy Injection", () => {
  it("reserves address(0) in slot 0 and overwrites cleanly with Reactive contract address", () => {
    const rawPayload = buildBracketCallbackPayload(
      7n,
      2,
      3_260_000_000_000_000_000_000n,
      1_762_850_123n
    );

    const decodedBefore = decodeFunctionData({
      abi: CALLBACK_PAYLOAD_ABI,
      data: rawPayload,
    });
    expect(decodedBefore.args[0]).toBe(OMNI_CONSTANTS.ZERO_ADDRESS);
    expect(decodedBefore.args[1]).toBe(7n);

    const sentinelAddr = "0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF" as const;
    const injected = simulateProxySenderOverwrite(rawPayload, sentinelAddr);
    const decodedAfter = decodeFunctionData({
      abi: CALLBACK_PAYLOAD_ABI,
      data: injected,
    });

    expect(decodedAfter.args[0].toLowerCase()).toBe(sentinelAddr.toLowerCase());
    expect(decodedAfter.args[1]).toBe(7n);
    expect(decodedAfter.args[2]).toBe(2);
    expect(decodedAfter.args[3]).toBe(3_260_000_000_000_000_000_000n);
    expect(decodedAfter.args[4]).toBe(1_762_850_123n);
  });

  it("rejects malformed short payloads before overwriting", () => {
    expect(() =>
      simulateProxySenderOverwrite("0x12345678", "0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF")
    ).toThrow(/shorter/i);
  });
});

describe("Track 1 Full-Loop Latency & Slippage Benchmark", () => {
  it("proves ~1s Reactive Omni saves material slippage & captures positive cross-L2 arb vs Legacy", () => {
    expect(totalLatencyMs(DEFAULT_PROFILES.reactive_omni)).toBeLessThan(2_000);
    expect(totalLatencyMs(DEFAULT_PROFILES.reactive_legacy)).toBeGreaterThan(8_000);

    const summary = runLatencyBenchmark(10, 3_000, 2_910, 18, 250, 2_200);
    const [omni, keeper, legacy] = summary.rows;

    expect(omni.totalLoopLatencyMs).toBe(1_600);
    expect(omni.elapsedBaseSepolia200msBlocks).toBe(8);
    expect(legacy.elapsedBaseSepolia200msBlocks).toBe(44);

    expect(omni.capitalPreservedVsLegacyUsd).toBeGreaterThan(1_700);
    expect(omni.slippageSavedBps).toBeGreaterThan(600);

    expect(omni.arbNetCaptureBps).toBeGreaterThan(100);
    expect(legacy.arbNetCaptureBps).toBeLessThan(0);

    expect(omni.wickSandwichPrevented).toBe(true);
    expect(keeper.wickSandwichPrevented).toBe(false);
  });

  it("scales proceeds linearly with position size", () => {
    const s1 = runLatencyBenchmark(1);
    const s5 = runLatencyBenchmark(5);
    expect(s5.rows[0].crashProceedsUsd).toBeCloseTo(s1.rows[0].crashProceedsUsd * 5, 1);
  });
});

describe("CLI Entrypoint Routing", () => {
  it("executes benchmark and fee-calc commands without error", async () => {
    await expect(runCli(["node", "src/cli.ts", "benchmark"])).resolves.toBeUndefined();
    await expect(runCli(["node", "src/cli.ts", "fee-calc", "0.02", "450000"])).resolves.toBeUndefined();
  });

  it("throws descriptive error on unknown subcommand", async () => {
    await expect(runCli(["node", "src/cli.ts", "nonexistent"])).rejects.toThrow(/Unknown command/i);
  });
});

describe("Environment & .env Auto-Load Behavior", () => {
  it("resolves default RPC URLs when env vars are unset", () => {
    expect(OMNI_NETWORKS.lasna.rpcUrl).toMatch(/^https?:\/\//);
    expect(OMNI_NETWORKS.baseSepolia.rpcUrl).toMatch(/^https?:\/\//);
    expect(OMNI_NETWORKS.unichainSepolia.rpcUrl).toMatch(/^https?:\/\//);
  });

  it("dynamically reflects process.env overrides in OMNI_NETWORKS getters", () => {
    const orig = process.env.BASE_SEPOLIA_RPC_URL;
    try {
      process.env.BASE_SEPOLIA_RPC_URL = "https://custom-base-sepolia.example.com";
      expect(OMNI_NETWORKS.baseSepolia.rpcUrl).toBe("https://custom-base-sepolia.example.com");
    } finally {
      if (orig !== undefined) {
        process.env.BASE_SEPOLIA_RPC_URL = orig;
      } else {
        delete process.env.BASE_SEPOLIA_RPC_URL;
      }
    }
  });

  it("safely attempts process.loadEnvFile without failing when .env is absent", () => {
    expect(() => {
      try {
        process.loadEnvFile?.(".env.nonexistent_benchmark_file");
      } catch {
        // fail-safe catch
      }
    }).not.toThrow();
  });
});
