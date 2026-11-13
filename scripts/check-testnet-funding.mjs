// scripts/check-testnet-funding.mjs
// Multi-Testnet Read-Only Balance Sweep for Canonical & Deployer Wallets

const CANONICAL_WALLET = "0xcbEDbeCC127a32217075Ff40f16Ec804aa1E0533";

try {
  process.loadEnvFile?.(".env");
} catch {
  // .env is optional
}

const DEPLOYER_WALLET = process.env.DEPLOYER_ADDR || "0x96a43E993dee5971355f86FFA5684710a421febc";

const TESTNETS = [
  {
    name: "Ethereum Sepolia",
    chainId: 11155111,
    symbol: "ETH",
    rpcs: ["https://ethereum-sepolia-rpc.publicnode.com", "https://1rpc.io/sepolia"],
  },
  {
    name: "Base Sepolia",
    chainId: 84532,
    symbol: "ETH",
    rpcs: ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com"],
  },
  {
    name: "Unichain Sepolia",
    chainId: 1301,
    symbol: "ETH",
    rpcs: ["https://sepolia.unichain.org"],
  },
  {
    name: "Arbitrum Sepolia",
    chainId: 421614,
    symbol: "ETH",
    rpcs: ["https://sepolia-rollup.arbitrum.io/rpc", "https://arbitrum-sepolia-rpc.publicnode.com"],
  },
  {
    name: "Optimism Sepolia",
    chainId: 11155420,
    symbol: "ETH",
    rpcs: ["https://sepolia.optimism.io", "https://optimism-sepolia-rpc.publicnode.com"],
  },
  {
    name: "Polygon Amoy",
    chainId: 80002,
    symbol: "POL",
    rpcs: ["https://rpc-amoy.polygon.technology", "https://polygon-amoy-bor-rpc.publicnode.com"],
  },
  {
    name: "Avalanche Fuji",
    chainId: 43113,
    symbol: "AVAX",
    rpcs: ["https://api.avax-test.network/ext/bc/C/rpc", "https://avalanche-fuji-c-chain-rpc.publicnode.com"],
  },
  {
    name: "BSC Testnet",
    chainId: 97,
    symbol: "tBNB",
    rpcs: ["https://bsc-testnet-rpc.publicnode.com", "https://data-seed-prebsc-1-s1.binance.org:8545"],
  },
  {
    name: "Monad Testnet",
    chainId: 10143,
    symbol: "MON",
    rpcs: ["https://testnet-rpc.monad.xyz"],
  },
  {
    name: "QDay Testnet",
    chainId: 44005,
    symbol: "QDAY",
    rpcs: ["https://rpc.qday.ninja", "https://testnet-rpc.qday.network"],
  },
  {
    name: "Reactive Lasna",
    chainId: 5318007,
    symbol: "lREACT",
    rpcs: ["https://lasna-rpc.rnk.dev/"],
  },
  {
    name: "Reactive Kopli",
    chainId: 5318008,
    symbol: "kREACT",
    rpcs: ["https://kopli-rpc.rnk.dev/"],
  },
];

async function getBalance(rpcUrl, address) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 9000);
  try {
    const res = await fetch(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_getBalance",
        params: [address, "latest"],
      }),
      signal: controller.signal,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const json = await res.json();
    if (json.error) throw new Error(json.error.message || "RPC error");
    return BigInt(json.result || "0x0");
  } finally {
    clearTimeout(timer);
  }
}

function formatEther(weiBigInt) {
  const s = weiBigInt.toString().padStart(19, "0");
  const whole = s.slice(0, s.length - 18) || "0";
  const frac = s.slice(s.length - 18, s.length - 14); // 4 decimals
  return `${whole}.${frac}`;
}

async function sweepChain(net) {
  let canonicalBal = null;
  let deployerBal = null;
  let usedRpc = null;
  let lastErr = null;

  for (const rpc of net.rpcs) {
    try {
      canonicalBal = await getBalance(rpc, CANONICAL_WALLET);
      deployerBal = await getBalance(rpc, DEPLOYER_WALLET);
      usedRpc = rpc;
      break;
    } catch (e) {
      lastErr = e.message;
    }
  }

  return {
    net,
    usedRpc,
    canonicalBal,
    deployerBal,
    error: usedRpc ? null : lastErr,
  };
}

async function main() {
  console.log("===============================================================================");
  console.log("  MULTI-TESTNET EXISTING BALANCE SWEEP (Read-Only JSON-RPC)");
  console.log("===============================================================================");
  console.log(`Canonical Wallet : ${CANONICAL_WALLET}`);
  console.log(`Deployer Wallet  : ${DEPLOYER_WALLET}`);
  console.log("-------------------------------------------------------------------------------");

  let totalFundedChains = 0;

  // Run in chunks of 3 to avoid socket contention
  const chunkSize = 3;
  for (let i = 0; i < TESTNETS.length; i += chunkSize) {
    const chunk = TESTNETS.slice(i, i + chunkSize);
    const results = await Promise.all(chunk.map(sweepChain));

    for (const r of results) {
      const tag = `[${r.net.name}] (id=${r.net.chainId})`.padEnd(36, " ");
      if (r.error) {
        console.log(`${tag} : RPC OFFLINE (${r.error})`);
        continue;
      }

      const cBal = r.canonicalBal ?? 0n;
      const dBal = r.deployerBal ?? 0n;

      const cStr = `${formatEther(cBal)} ${r.net.symbol}`.padStart(16, " ");
      const dStr = `${formatEther(dBal)} ${r.net.symbol}`.padStart(16, " ");

      const funded = cBal > 0n || dBal > 0n;
      if (funded) totalFundedChains++;

      const flag = funded ? " <-- FUNDED!" : "";
      console.log(`${tag} : Canonical=${cStr} | Deployer=${dStr}${flag}`);
    }
  }

  console.log("-------------------------------------------------------------------------------");
  console.log(`Summary: ${totalFundedChains} chain(s) hold non-zero testnet balance.`);
  console.log("===============================================================================");
}

main().catch((e) => {
  console.error("Fatal sweep error:", e);
  process.exit(1);
});
