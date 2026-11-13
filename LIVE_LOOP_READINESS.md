# Live Multi-Chain RPC & Faucet Readiness Probe Report

**Generated**: March 2026  
**Target Networks**:
1. Base Sepolia (`84532`, Denim 200ms blocks)
2. Reactive Lasna (`5318007`, Omni CometBFT 1s blocks)
3. Unichain Sepolia (`1301`, Flashblocks 1s blocks)

---

## 1. Multi-Chain RPC & System Infrastructure Status

All three protocol chains were actively probed and verified operational via `npm run doctor`:

| Network | Chain ID | RPC URL | System / Proxy Contract | Bytecode Verified | Base Fee | Status |
| :--- | :---: | :--- | :--- | :---: | :---: | :---: |
| **Reactive Lasna** | `5318007` | `https://lasna-rpc.rnk.dev/` | `0x8888888888888888888888888888888888888888` | 239 B | 100 gwei | **ONLINE** (RTT ~913ms) |
| **Base Sepolia** | `84532` | `https://sepolia.base.org` | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` | 218 B | 0.005 gwei | **ONLINE** (RTT ~1085ms) |
| **Unichain Sepolia** | `1301` | `https://sepolia.unichain.org` | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` | 218 B | 0.0005 gwei | **ONLINE** (RTT ~998ms) |

- **Reactive Lasna Sequence Frontier**: Verified height and sequence progression active.
- **Callback Proxy Dynamic Parameters**:
  - Base Sepolia: Coeff `1100/1000` (1.1x), `extraGas=80,000`, `maxChargeGas=50,000`.
  - Reactive Lasna: Coeff `1000/1000` (1.0x), `extraGas=100,000`, `maxChargeGas=50,000`.
- **Destination Callback Fee**: At default 450k gas limit, Base Sepolia callback fee is estimated at `~0.00000146 ETH`.

---

## 2. On-Chain Faucet Probing & Reverse-Engineering

### A. Base Sepolia Official Reactive Faucet (`0x2afaFD298b23b62760711756088F75B7409f5967`)
- **Chain**: Base Sepolia (`84532`)
- **Bytecode**: Deployed and active (Solidity 0.8.28 compiler metadata)
- **Current Contract Balance**: `5.21229 ETH`
- **Reverse-Engineered ABI Selectors**:
  - `0x10062470`: `max_payout() view returns (uint256)` -> Returns `1,000,000,000,000,000,000` (`1 ETH`)
  - `0x27c78c42`: `request(address)` -> Exchanges SepETH for `100x` `lREACT` on Reactive Lasna testnet
  - `0x2e1a7d4d`: `withdraw(uint256)` (Owner restricted)
  - `0x56b4997f`: `setMaxPayout(uint256)` (Owner restricted)
- **Mechanism**:
  Sending `msg.value` (e.g. `0.05 ETH`) with `"request(address)" $DEPLOYER_ADDR` emits a cross-chain bridging event that triggers the Reactive Network bridge relayer to mint `5.0 lREACT` directly to `$DEPLOYER_ADDR` on Reactive Lasna (`5318007`).

### B. Ethereum Sepolia Official Reactive Faucet (`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`)
- **Chain**: Ethereum Sepolia (`11155111`)
- **Bytecode**: Deployed and active
- **Current Contract Balance**: `198.253 ETH`
- **Reverse-Engineered ABI Selectors**:
  - `0x10062470`: `max_payout() view returns (uint256)`
  - `0x27c78c42`: `request(address)` -> Cross-chain mints `100x` `lREACT` on Reactive Lasna
- **Availability**: Massive liquidity pool (`~198 ETH`) available for swapping into `lREACT`.

### C. Reactive Lasna System/Bridging Contract (`0x2afaFD298b23b62760711756088F75B7409f5967`)
- **Chain**: Reactive Lasna (`5318007`)
- **Bytecode**: Deployed and active (AbstractReactive / System receiver)
- **Current Contract Balance**: `2.0941 lREACT`
- **Selectors**: `react(...)`, `coverDebt()`, `pay(uint256)`

---

## 3. Keyless / Public Faucet Endpoints for Ephemeral Deployers

To fund an ephemeral deployer with initial Base Sepolia ETH or Unichain Sepolia ETH without requiring any KYC or API keys:

1. **Sepolia PoW Faucet (Zero-Key, 100% Autonomous)**:
   - Endpoint: `https://sepolia-faucet.pk910.de/`
   - Mechanism: Browser or CLI PoW mining yields direct SepETH payout to any EVM address.
   - Payout can be swapped directly via `cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` for Lasna `lREACT`, or bridged to Base Sepolia via the native Superchain bridge.

2. **Base Sepolia Public Faucets**:
   - Superchain Faucet: `https://console.optimism.io/faucet`
   - Chainlink Faucet: `https://faucets.chain.link/base-sepolia`
   - QuickNode Faucet: `https://faucet.quicknode.com/base/sepolia`

3. **Unichain Sepolia Public Faucet**:
   - Official Faucet: `https://faucet.unichain.org/`

---

## 4. Deployer Account Status

- **Configured Deployer Address**: `0x96a43E993dee5971355f86FFA5684710a421febc`
- **Current Balances**:
  - Base Sepolia: `0.0 ETH`
  - Unichain Sepolia: `0.0 ETH`
  - Reactive Lasna: `0.0 lREACT`
- **Pipeline Readiness**:
  The TypeScript CLI suite (`npm run doctor`, `npm run fee-calc`, `npm run live-loop`) and Foundry deployment pipeline (`DeployAndTriggerOmni.s.sol`) are fully compiled and configured. Once `~0.05 ETH` is dripped to the deployer, running `npm run live-loop --all-three` will execute all three live settlement loops across Base Sepolia, Unichain Sepolia, and Reactive Lasna.
