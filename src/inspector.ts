import { createPublicClient, formatEther, formatGwei, http } from "viem";
import {
  OMNI_CONSTANTS,
  OMNI_NETWORKS,
  SYSTEM_OR_PROXY_ABI,
  baseSepoliaChain,
  computeOmniFeeBudget,
  lasnaChain,
  unichainSepoliaChain,
  type OmniNetworkSpec,
} from "./networks.js";

export interface NetworkDiagnosticReport {
  network: OmniNetworkSpec;
  reachable: boolean;
  rpcLatencyMs: number;
  latestBlock: bigint;
  baseFeeGwei: string;
  systemBytecodeBytes: number;
  gasPriceCoeffPer1000: bigint;
  extraGas: bigint;
  maxChargeGas: bigint;
  estimatedCallbackFeeEth: string;
  forwardedGasAtDefaultLimit: bigint;
  lasnaSequenceFrontier?: {
    height: string;
    fromSeq: string;
    toSeq: string;
  };
  error?: string;
}

const CHAIN_MAP = {
  lasna: lasnaChain,
  baseSepolia: baseSepoliaChain,
  unichainSepolia: unichainSepoliaChain,
} as const;

export async function inspectOmniNetwork(
  key: OmniNetworkSpec["key"]
): Promise<NetworkDiagnosticReport> {
  const spec = OMNI_NETWORKS[key];
  const client = createPublicClient({
    chain: CHAIN_MAP[key],
    transport: http(spec.rpcUrl, { timeout: 12_000 }),
  });

  const t0 = performance.now();
  try {
    const [block, bytecode, coeff, extraGas, maxChargeGas] = await Promise.all([
      client.getBlock({ blockTag: "latest" }),
      client.getCode({ address: spec.systemOrProxyAddress }),
      client.readContract({
        address: spec.systemOrProxyAddress,
        abi: SYSTEM_OR_PROXY_ABI,
        functionName: "_gasPriceCoeffPer1000",
      }),
      client.readContract({
        address: spec.systemOrProxyAddress,
        abi: SYSTEM_OR_PROXY_ABI,
        functionName: "_extraGas",
      }),
      client.readContract({
        address: spec.systemOrProxyAddress,
        abi: SYSTEM_OR_PROXY_ABI,
        functionName: "_maxChargeGas",
      }),
    ]);
    const rpcLatencyMs = Math.round(performance.now() - t0);
    const baseFeeWei = block.baseFeePerGas ?? 1_000_000_000n;

    const feeQuote = computeOmniFeeBudget(
      {
        baseFeeWei,
        gasPriceCoeffPer1000: coeff,
        gasUsed: 185_000n,
        extraGas,
        maxChargeGas,
      },
      OMNI_CONSTANTS.DEFAULT_CALLBACK_GAS_LIMIT
    );

    let lasnaSequenceFrontier: NetworkDiagnosticReport["lasnaSequenceFrontier"];
    if (key === "lasna") {
      try {
        const raw = (await client.request({
          method: "rnk_getCommittedSequenceFrontier" as never,
          params: [] as never,
        })) as { height: string; fromSeq: string; toSeq: string };
        if (raw && typeof raw.height === "string") {
          lasnaSequenceFrontier = raw;
        }
      } catch {
        // Non-fatal if custom RNK namespace is disabled on a mirror node
      }
    }

    return {
      network: spec,
      reachable: true,
      rpcLatencyMs,
      latestBlock: block.number ?? 0n,
      baseFeeGwei: formatGwei(baseFeeWei),
      systemBytecodeBytes: bytecode ? (bytecode.length - 2) / 2 : 0,
      gasPriceCoeffPer1000: coeff,
      extraGas,
      maxChargeGas,
      estimatedCallbackFeeEth: formatEther(feeQuote.totalFeeWei),
      forwardedGasAtDefaultLimit: feeQuote.forwardedExecutionGas,
      lasnaSequenceFrontier,
    };
  } catch (err) {
    return {
      network: spec,
      reachable: false,
      rpcLatencyMs: Math.round(performance.now() - t0),
      latestBlock: 0n,
      baseFeeGwei: "0",
      systemBytecodeBytes: 0,
      gasPriceCoeffPer1000: 0n,
      extraGas: 0n,
      maxChargeGas: 0n,
      estimatedCallbackFeeEth: "0",
      forwardedGasAtDefaultLimit: 0n,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

export async function runDoctorSuite(): Promise<NetworkDiagnosticReport[]> {
  return Promise.all([
    inspectOmniNetwork("lasna"),
    inspectOmniNetwork("baseSepolia"),
    inspectOmniNetwork("unichainSepolia"),
  ]);
}
