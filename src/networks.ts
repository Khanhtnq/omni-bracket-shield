import { defineChain, encodeFunctionData, parseAbi, type Chain, type Hex } from "viem";

try {
  process.loadEnvFile?.(".env");
} catch {
  // .env is optional in CI / read-only benchmark environments
}

export interface OmniNetworkSpec {
  key: "lasna" | "baseSepolia" | "unichainSepolia";
  name: string;
  chainId: number;
  rpcUrl: string;
  explorerUrl: string;
  nativeSymbol: string;
  nominalBlockTimeMs: number;
  systemOrProxyAddress: `0x${string}`;
  faucetAddress?: `0x${string}`;
}

export const OMNI_CONSTANTS = {
  SYSTEM_CONTRACT: "0x8888888888888888888888888888888888888888" as const,
  CRON_EMITTER_ADDR: "0x0000000000000000000000000000000000fffFfF" as const,
  BASE_SEPOLIA_CALLBACK_PROXY: "0x476F44b11F5C942c58f4c8E3d0300E5710743585" as const,
  UNICHAIN_SEPOLIA_CALLBACK_PROXY: "0x775c9B990ADe401060B78D0e98684eEf8d2466C1" as const,
  BASE_SEPOLIA_FAUCET: "0x2afaFD298b23b62760711756088F75B7409f5967" as const,
  ETHEREUM_SEPOLIA_FAUCET: "0x9b9BB25f1A81078C544C829c5EB7822d747Cf434" as const,
  MIN_CALLBACK_GAS_LIMIT: 100_000n,
  MAX_REACTIVE_TX_GAS_LIMIT: 900_000n,
  DEFAULT_CALLBACK_GAS_LIMIT: 450_000n,
  ZERO_ADDRESS: "0x0000000000000000000000000000000000000000" as const,
} as const;

export const OMNI_NETWORKS: Record<OmniNetworkSpec["key"], OmniNetworkSpec> = {
  lasna: {
    key: "lasna",
    name: "Reactive Lasna (Omni CometBFT)",
    chainId: 5318007,
    get rpcUrl() {
      return process.env.LASNA_RPC_URL || "https://lasna-rpc.rnk.dev/";
    },
    explorerUrl: "https://lasna.reactscan.net",
    nativeSymbol: "lREACT",
    nominalBlockTimeMs: 1000,
    systemOrProxyAddress: OMNI_CONSTANTS.SYSTEM_CONTRACT,
  },
  baseSepolia: {
    key: "baseSepolia",
    name: "Base Sepolia (Denim 200ms)",
    chainId: 84532,
    get rpcUrl() {
      return process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org";
    },
    explorerUrl: "https://sepolia.basescan.org",
    nativeSymbol: "ETH",
    nominalBlockTimeMs: 200,
    systemOrProxyAddress: OMNI_CONSTANTS.BASE_SEPOLIA_CALLBACK_PROXY,
    faucetAddress: OMNI_CONSTANTS.BASE_SEPOLIA_FAUCET,
  },
  unichainSepolia: {
    key: "unichainSepolia",
    name: "Unichain Sepolia (1s)",
    chainId: 1301,
    get rpcUrl() {
      return process.env.UNICHAIN_SEPOLIA_RPC_URL || "https://sepolia.unichain.org";
    },
    explorerUrl: "https://sepolia.uniscan.xyz",
    nativeSymbol: "ETH",
    nominalBlockTimeMs: 1000,
    systemOrProxyAddress: OMNI_CONSTANTS.UNICHAIN_SEPOLIA_CALLBACK_PROXY,
  },
};

export const lasnaChain: Chain = defineChain({
  id: 5318007,
  name: "Reactive Lasna",
  nativeCurrency: { name: "Lasna REACT", symbol: "lREACT", decimals: 18 },
  rpcUrls: {
    default: { http: [OMNI_NETWORKS.lasna.rpcUrl] },
  },
  blockExplorers: {
    default: { name: "Reactscan", url: OMNI_NETWORKS.lasna.explorerUrl },
  },
  testnet: true,
});

export const baseSepoliaChain: Chain = defineChain({
  id: 84532,
  name: "Base Sepolia",
  nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [OMNI_NETWORKS.baseSepolia.rpcUrl] },
  },
  blockExplorers: {
    default: { name: "Basescan", url: OMNI_NETWORKS.baseSepolia.explorerUrl },
  },
  testnet: true,
});

export const unichainSepoliaChain: Chain = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [OMNI_NETWORKS.unichainSepolia.rpcUrl] },
  },
  blockExplorers: {
    default: { name: "Uniscan", url: OMNI_NETWORKS.unichainSepolia.explorerUrl },
  },
  testnet: true,
});

export const SYSTEM_OR_PROXY_ABI = parseAbi([
  "function _gasPriceCoeffPer1000() view returns (uint256)",
  "function _extraGas() view returns (uint256)",
  "function _maxChargeGas() view returns (uint256)",
  "function debt(address contract_) view returns (uint256)",
  "function reserves(address contract_) view returns (uint256)",
  "function depositTo(address target_) payable",
]);

export const CALLBACK_PAYLOAD_ABI = parseAbi([
  "function executeBracketCallback(address reactiveSender_, uint256 positionId_, uint8 triggerKind_, uint256 referencePriceE18_, uint256 originEventTimestamp_)",
]);

export interface FeeParameters {
  baseFeeWei: bigint;
  gasPriceCoeffPer1000: bigint;
  gasUsed: bigint;
  extraGas: bigint;
  maxChargeGas: bigint;
}

export interface FeeBudgetQuote {
  totalFeeWei: bigint;
  proxyOverheadGas: bigint;
  forwardedExecutionGas: bigint;
  meetsMinimumCallbackGas: boolean;
  exceedsReactiveCap: boolean;
}

/**
 * Exact Reactive Omni economy pricing formula (`dev.reactive.network/economy`):
 *   fee = p_base * (C / 1000) * (g_used + K)
 * and forwarded destination execution gas:
 *   g_forwarded = requestedGasLimit - (_extraGas + _maxChargeGas)
 */
export function computeOmniFeeBudget(
  params: FeeParameters,
  requestedCallbackGasLimit: bigint = OMNI_CONSTANTS.DEFAULT_CALLBACK_GAS_LIMIT
): FeeBudgetQuote {
  if (params.baseFeeWei < 0n || params.gasPriceCoeffPer1000 < 0n || params.gasUsed < 0n) {
    throw new Error("Fee parameters must be non-negative");
  }
  const billableGas = params.gasUsed + params.extraGas;
  const totalFeeWei = (params.baseFeeWei * params.gasPriceCoeffPer1000 * billableGas) / 1000n;
  const proxyOverheadGas = params.extraGas + params.maxChargeGas;
  const forwardedExecutionGas =
    requestedCallbackGasLimit > proxyOverheadGas ? requestedCallbackGasLimit - proxyOverheadGas : 0n;

  return {
    totalFeeWei,
    proxyOverheadGas,
    forwardedExecutionGas,
    meetsMinimumCallbackGas:
      requestedCallbackGasLimit >= OMNI_CONSTANTS.MIN_CALLBACK_GAS_LIMIT &&
      forwardedExecutionGas > 0n,
    exceedsReactiveCap: params.gasUsed > OMNI_CONSTANTS.MAX_REACTIVE_TX_GAS_LIMIT,
  };
}

/**
 * Encodes `executeBracketCallback` with `address(0)` reserved in the first 32-byte argument slot,
 * and provides a verifier mirroring Destination CallbackProxy's sender-overwrite injection.
 */
export function buildBracketCallbackPayload(
  positionId: bigint,
  triggerKind: number,
  referencePriceE18: bigint,
  originEventTimestamp: bigint
): Hex {
  return encodeFunctionData({
    abi: CALLBACK_PAYLOAD_ABI,
    functionName: "executeBracketCallback",
    args: [
      OMNI_CONSTANTS.ZERO_ADDRESS,
      positionId,
      triggerKind,
      referencePriceE18,
      originEventTimestamp,
    ],
  });
}

export function simulateProxySenderOverwrite(payload: Hex, reactiveContract: `0x${string}`): Hex {
  const raw = payload.slice(2);
  if (raw.length < 72) {
    throw new Error("Payload shorter than 4-byte selector + 32-byte reserved address slot");
  }
  const selector = raw.slice(0, 8);
  const tail = raw.slice(72);
  const paddedAddress = reactiveContract.slice(2).toLowerCase().padStart(64, "0");
  return `0x${selector}${paddedAddress}${tail}`;
}
