# Live Multi-Chain RPC, Faucet Gate & Balance Sweep Report

**Target Networks**:
1. Base Sepolia (`84532`, Denim 200ms blocks)
2. Reactive Lasna (`5318007`, Omni CometBFT 1s blocks)
3. Unichain Sepolia (`1301`, Flashblocks 1s blocks)

---

## 1. Multi-Testnet Balance Sweep (Canonical & Deployer Wallets)

Executed via `node scripts/check-testnet-funding.mjs` against public JSON-RPC endpoints:
- **Canonical Payout Wallet**: `0xcbEDbeCC127a32217075Ff40f16Ec804aa1E0533`
- **Configured Deployer Wallet**: `0x96a43E993dee5971355f86FFA5684710a421febc`

| Network | Chain ID | RPC Endpoint | Canonical Wallet Balance | Deployer Wallet Balance | Status |
| :--- | :---: | :--- | :---: | :---: | :---: |
| **Ethereum Sepolia** | `11155111` | `https://ethereum-sepolia-rpc.publicnode.com` | `0.0000 ETH` | `0.0000 ETH` | Clean / Unfunded |
| **Base Sepolia** | `84532` | `https://sepolia.base.org` | `0.0000 ETH` | `0.0000 ETH` | Clean / Unfunded |
| **Unichain Sepolia** | `1301` | `https://sepolia.unichain.org` | `0.0000 ETH` | `0.0000 ETH` | Clean / Unfunded |
| **Arbitrum Sepolia** | `421614` | `https://sepolia-rollup.arbitrum.io/rpc` | `0.0000 ETH` | `0.0000 ETH` | Clean / Unfunded |
| **Optimism Sepolia** | `11155420` | `https://sepolia.optimism.io` | `0.0000 ETH` | `0.0000 ETH` | Clean / Unfunded |
| **Polygon Amoy** | `80002` | `https://rpc-amoy.polygon.technology` | `0.0000 POL` | `0.0000 POL` | Clean / Unfunded |
| **Avalanche Fuji** | `43113` | `https://api.avax-test.network/ext/bc/C/rpc` | `0.0000 AVAX` | `0.0000 AVAX` | Clean / Unfunded |
| **BSC Testnet** | `97` | `https://bsc-testnet-rpc.publicnode.com` | `0.0000 tBNB` | `0.0000 tBNB` | Clean / Unfunded |
| **Monad Testnet** | `10143` | `https://testnet-rpc.monad.xyz` | `0.0000 MON` | `0.0000 MON` | Clean / Unfunded |
| **Reactive Lasna** | `5318007` | `https://lasna-rpc.rnk.dev/` | `0.0000 lREACT` | `0.0000 lREACT` | Clean / Unfunded |

*Result: Both addresses currently hold 0 testnet gas across all 10 EVM testnets.*

---

## 2. Multi-Chain RPC & System Infrastructure Verification

Probed via `npm run doctor`:

| Network | Chain ID | RPC URL | System / Proxy Contract | Bytecode Verified | Base Fee | Status |
| :--- | :---: | :--- | :--- | :---: | :---: | :---: |
| **Reactive Lasna** | `5318007` | `https://lasna-rpc.rnk.dev/` | `0x8888888888888888888888888888888888888888` | 239 B | 100 gwei | **ONLINE** (RTT ~913ms) |
| **Base Sepolia** | `84532` | `https://sepolia.base.org` | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` | 218 B | 0.005 gwei | **ONLINE** (RTT ~1085ms) |
| **Unichain Sepolia** | `1301` | `https://sepolia.unichain.org` | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` | 218 B | 0.0005 gwei | **ONLINE** (RTT ~998ms) |

- **Reactive Lasna Sequence Frontier**: Height and sequence progression active.
- **Callback Proxy Dynamic Parameters**:
  - Base Sepolia: Coeff `1100/1000` (1.1x), `extraGas=80,000`, `maxChargeGas=50,000`.
  - Reactive Lasna: Coeff `1000/1000` (1.0x), `extraGas=100,000`, `maxChargeGas=50,000`.
- **Destination Callback Fee**: At default 450k gas limit, Base Sepolia callback fee is estimated at `~0.00000146 ETH`.

---

## 3. On-Chain Faucet Probing & Reverse-Engineering

### A. Base Sepolia Official Reactive Faucet (`0x2afaFD298b23b62760711756088F75B7409f5967`)
- **Chain**: Base Sepolia (`84532`)
- **Contract Name**: `ReactiveFaucetL1`
- **Current Contract Balance**: `5.21229 ETH`
- **Reverse-Engineered ABI Selectors**:
  - `0x10062470`: `max_payout() view returns (uint256)` -> Returns `1,000,000,000,000,000,000` (`1 ETH`)
  - `0x27c78c42`: `request(address)` -> Exchanges SepETH for `100x` `lREACT` on Reactive Lasna testnet
  - `0x2e1a7d4d`: `withdraw(uint256)` (Owner restricted)
  - `0x56b4997f`: `setMaxPayout(uint256)` (Owner restricted)
- **Mechanism**:
  Sending `msg.value` (e.g. `0.05 ETH`) with `"request(address)" $DEPLOYER_ADDR` emits a payment log that triggers the Reactive Network validator bridge to mint `5.0 lREACT` directly to `$DEPLOYER_ADDR` on Reactive Lasna (`5318007`). Limit: max 5 ETH per transaction.

### B. Ethereum Sepolia Official Reactive Faucet (`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`)
- **Chain**: Ethereum Sepolia (`11155111`)
- **Contract Name**: `ReactiveFaucetL1`
- **Current Contract Balance**: `198.253 ETH`
- **Mechanism**: Same `request(address)` function, minting `100x lREACT` on Reactive Lasna.

### C. Reactive Lasna System Receiver (`0x2afaFD298b23b62760711756088F75B7409f5967`)
- **Chain**: Reactive Lasna (`5318007`)
- **Current Contract Balance**: `2.0941 lREACT`
- **Selectors**: `react(...)`, `coverDebt()`, `pay(uint256)`

---

## 4. Public Faucet Gate Requirements & Anti-Sybil Policy Audit

All public Web3 faucets currently enforce strict anti-sybil and anti-bot gates:

| Faucet Endpoint | Network | Drip Amount | Anti-Sybil Gate / Requirements | Programmatic CLI Access |
| :--- | :--- | :--- | :--- | :---: |
| **Superchain Faucet** (`console.optimism.io/faucet`) | Base Sepolia (`84532`) | `0.05 ETH` | GitHub OAuth (account >= 30 days old) | Interactive Web Only |
| **Chainlink Faucet** (`faucets.chain.link/base-sepolia`) | Base Sepolia (`84532`) | `0.1 ETH` | GitHub OAuth + Cloudflare Turnstile | Interactive Web Only |
| **Unichain Faucet** (`faucet.unichain.org`) | Unichain Sepolia (`1301`) | `0.05 ETH` | Cloudflare Turnstile CAPTCHA | Interactive Web Only |
| **Google Cloud Web3 Faucet** | Ethereum Sepolia (`11155111`) | `0.05 ETH` | Google Account OAuth | Interactive Web Only |
| **Alchemy Faucet** (`sepoliafaucet.com`) | Ethereum Sepolia (`11155111`) | `0.1 ETH` | Alchemy login + `>= 0.001 ETH` on Mainnet | Interactive Web Only |
| **Infura Faucet** (`infura.io/faucet/sepolia`) | Ethereum Sepolia (`11155111`) | `0.5 ETH` | Infura login + `>= 0.001 ETH` on Mainnet | Interactive Web Only |
| **Sepolia PoW Faucet** (`sepolia-faucet.pk910.de`) | Ethereum Sepolia (`11155111`) | Variable | Browser Client-Side PoW Mining | Interactive Browser Only |

### Ground-Truth Policy Finding:
Autonomous subagents are strictly prohibited by protocol safety and OPSEC instructions from attempting to defeat, spoof, or bypass CAPTCHAs, OAuth gates, or anti-bot heuristics. Consequently, keyless testnet drip acquisition requires a single interactive operator action.

---

## 5. Single-Command Operator Funding & Execution Procedure

To activate the 3 live testnet full loops:

1. **Step 1 — Fund Deployer with Base SepETH**:
   - The operator visits `https://console.optimism.io/faucet` or `https://faucets.chain.link/base-sepolia`.
   - Request `0.05–0.1 Base SepETH` sent to either:
     - `0xcbEDbeCC127a32217075Ff40f16Ec804aa1E0533` (Canonical)
     - `0x96a43E993dee5971355f86FFA5684710a421febc` (Deployer)

2. **Step 2 — Mint Reactive Lasna `lREACT` Gas via On-Chain Faucet**:
   ```bash
   cast send 0x2afaFD298b23b62760711756088F75B7409f5967 \
     --rpc-url https://sepolia.base.org \
     --private-key $DEPLOYER_PRIVATE_KEY \
     "request(address)" $DEPLOYER_ADDR \
     --value 0.05ether
   ```
   *Within ~15–30 seconds, 5.0 `lREACT` will be minted to `$DEPLOYER_ADDR` on Reactive Lasna.*

3. **Step 3 — Execute All Three Live Callback Loops**:
   ```bash
   npm run live-loop --all-three
   ```
   *This automatically executes:*
   - Loop 1: Hard Stop-Loss ($3,000 -> $2,820)
   - Loop 2: Take-Profit ($3,000 -> $3,350)
   - Loop 3: Dynamic Trailing Stop ($3,000 -> $3,220 rally -> $3,080 pullback)
   *Recording the full-loop transaction hashes (Origin -> Lasna Reactive -> Destination Callback) directly into `SUBMISSION_PACKAGE.md`.*
