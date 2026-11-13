# Live Reactive Omni On-Chain Proofs & Execution Report

**Project**: OmniBracket Shield  
**Hackathon**: Reactive Omni Buildathon (DoraHacks ID: 2472)  
**Primary Track**: Track 1 — Every Second Counts  
**Deployer Address**: `0x96a43E993dee5971355f86FFA5684710a421febc`  
**Verified On-Chain UTC**: `2026-11-13T10:23:54Z` (Base Sepolia Blocks `58217613–58217867`, Reactive Lasna Blocks `8238400–8238447`, Unichain Sepolia Blocks `67712962–67713011`)  

---

## 1. Verified Live Deployed Contract Infrastructure

| Contract Role | Network | Address | Explorer Link | Verification |
| :--- | :--- | :--- | :--- | :---: |
| **Origin Pool (`OmniPricePool`)** | Base Sepolia (`84532`) | `0xb16A318355Ecc265Afd0aCa51EE01C3f0aA91551` | [Basescan](https://sepolia.basescan.org/address/0xb16A318355Ecc265Afd0aCa51EE01C3f0aA91551) | Deployed |
| **Origin Reference Pool (`OmniPricePool`)** | Unichain Sepolia (`1301`) | `0xb16A318355Ecc265Afd0aCa51EE01C3f0aA91551` | [Uniscan](https://sepolia.uniscan.xyz/address/0xb16A318355Ecc265Afd0aCa51EE01C3f0aA91551) | Deployed |
| **Virtual WETH (`MockERC20`)** | Base Sepolia (`84532`) | `0x2376EBA740136e63DBF172B8148B1D7362897857` | [Basescan](https://sepolia.basescan.org/address/0x2376EBA740136e63DBF172B8148B1D7362897857) | Deployed |
| **Virtual USDC (`MockERC20`)** | Base Sepolia (`84532`) | `0xC5C263bB0908F7b7400AB57dF6Bfaa22509110DE` | [Basescan](https://sepolia.basescan.org/address/0xC5C263bB0908F7b7400AB57dF6Bfaa22509110DE) | Deployed |
| **Reactive Sentinel (`OmniSentinelReactive`)** | Reactive Lasna (`5318007`) | `0x2376EBA740136e63DBF172B8148B1D7362897857` | [Reactscan](https://lasna.reactscan.net/address/0x2376EBA740136e63DBF172B8148B1D7362897857) | Sourcify Verified |
| **Destination Vault (`OmniBracketVault`)** | Base Sepolia (`84532`) | `0x24E60A1bcEB266DE6c44f0EE4e411e80fDD3289f` | [Basescan](https://sepolia.basescan.org/address/0x24E60A1bcEB266DE6c44f0EE4e411e80fDD3289f) | Sourcify Verified |
| **Canonical System Contract** | Reactive Lasna (`5318007`) | `0x8888888888888888888888888888888888888888` | [Reactscan](https://lasna.reactscan.net/address/0x8888888888888888888888888888888888888888) | System Precompile |
| **Callback Proxy** | Base Sepolia (`84532`) | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` | [Basescan](https://sepolia.basescan.org/address/0x476F44b11F5C942c58f4c8E3d0300E5710743585) | Protocol Proxy |

---

## 2. Live Multi-Chain Full-Loop Settlement Transactions

All 3 live cross-chain reactive execution loops were broadcast, confirmed, and settled on-chain:

### Loop 1 :: Hard Stop-Loss ($3,000 -> $2,820)
- **Position ID**: `#2`
- **Order Size**: 1.0 vWETH
- **0b. Unichain Reference Confirmation Tx**:  
  [`0xea6dc3a26751e3383272e2ddb5fc3d74a4eb3358029260abe501688eaba6715f`](https://sepolia.uniscan.xyz/tx/0xea6dc3a26751e3383272e2ddb5fc3d74a4eb3358029260abe501688eaba6715f)
- **1. Origin Event Tx (Base Sepolia `PoolTickUpdated`)**:  
  [`0x253bca14c49915d4c8bfa0125c82937a4790ffc1ea8e15d1aa32bb459915e061`](https://sepolia.basescan.org/tx/0x253bca14c49915d4c8bfa0125c82937a4790ffc1ea8e15d1aa32bb459915e061)
- **2. Reactive Lasna Execution Tx (`OmniSentinelReactive.react()` -> `CallbackRequest`)**:  
  [`0x40d9cec9b511d8ba9f8ed0df53999ffa536704ed709a72c355a24466fdee156f`](https://lasna.reactscan.net/tx/0x40d9cec9b511d8ba9f8ed0df53999ffa536704ed709a72c355a24466fdee156f)
- **3. Destination Settlement Tx (Base Sepolia `CallbackProxy` -> `executeBracketCallback` -> `BracketSettled`)**:  
  [`0xee5ba0a0160d6b2e607685fda4e1cdf73655295e96d56def21d343ceaab2d2eb`](https://sepolia.basescan.org/tx/0xee5ba0a0160d6b2e607685fda4e1cdf73655295e96d56def21d343ceaab2d2eb)
- **Wall-Clock Full-Loop Latency**: `2,796 ms` (~2.8 seconds)
- **On-Chain Loop Latency (`loopLatencySec`)**: `1 s`
- **Settled Proceeds**: `2,805.956091 vUSDC`
- **Reactive Lasna Sentinel Counters**: `callbacksDispatched=2`, `completedLoops=2`

---

### Loop 2 :: Take-Profit Settlement ($3,000 -> $3,350)
- **Position ID**: `#3`
- **Order Size**: 1.0 vWETH
- **0b. Unichain Reference Confirmation Tx**:  
  [`0x9c61dc5213335ec0ce0a3b27a9bba981d7263bcc0a7bdbc7dec66d524cb02c29`](https://sepolia.uniscan.xyz/tx/0x9c61dc5213335ec0ce0a3b27a9bba981d7263bcc0a7bdbc7dec66d524cb02c29)
- **1. Origin Event Tx (Base Sepolia `PoolTickUpdated`)**:  
  [`0x529eaba0133a218aea1269b708e1cce8e60700d05ab5492a8c6eeecc8e3a2e11`](https://sepolia.basescan.org/tx/0x529eaba0133a218aea1269b708e1cce8e60700d05ab5492a8c6eeecc8e3a2e11)
- **2. Reactive Lasna Execution Tx (`OmniSentinelReactive.react()` -> `CallbackRequest`)**:  
  [`0x2ef855cbc83b744f9b465c5fd50c4ccf856d46f9bd161abd988886307a81a3ee`](https://lasna.reactscan.net/tx/0x2ef855cbc83b744f9b465c5fd50c4ccf856d46f9bd161abd988886307a81a3ee)
- **3. Destination Settlement Tx (Base Sepolia `CallbackProxy` -> `executeBracketCallback` -> `BracketSettled`)**:  
  [`0xd8014433fdc376aab097ad3f630a87e4c0eabb22f5884e7b1e284c2a03f95b8f`](https://sepolia.basescan.org/tx/0xd8014433fdc376aab097ad3f630a87e4c0eabb22f5884e7b1e284c2a03f95b8f)
- **Wall-Clock Full-Loop Latency**: `3,428 ms` (~3.4 seconds)
- **On-Chain Loop Latency (`loopLatencySec`)**: `1 s`
- **Settled Proceeds**: `3,333.329821 vUSDC`
- **Reactive Lasna Sentinel Counters**: `callbacksDispatched=3`, `completedLoops=3`

---

### Loop 3 :: Dynamic Trailing Stop ($3,000 -> $3,220 Rally Ratchet -> $3,080 Pullback)
- **Position ID**: `#4`
- **Order Size**: 1.0 vWETH
- **0a. Rally High-Water Ratchet Tx (Base Sepolia `PoolTickUpdated` $3,220)**:  
  [`0xb126d0f06c83af3e410ec56c40f42358cd654ac804603c366e34f6707012cb3b`](https://sepolia.basescan.org/tx/0xb126d0f06c83af3e410ec56c40f42358cd654ac804603c366e34f6707012cb3b)
- **0b. Unichain Reference Confirmation Tx**:  
  [`0x36e82aa001e1f6f0f44ae055afbd6380d5b77065d3fc1b223706ae038bcfb202`](https://sepolia.uniscan.xyz/tx/0x36e82aa001e1f6f0f44ae055afbd6380d5b77065d3fc1b223706ae038bcfb202)
- **1. Origin Pullback Event Tx (Base Sepolia `PoolTickUpdated` $3,080)**:  
  [`0x78c238fdbf039d8b0b338dbb8628d03b52b3918c5da885beab8c75524c2cbb8e`](https://sepolia.basescan.org/tx/0x78c238fdbf039d8b0b338dbb8628d03b52b3918c5da885beab8c75524c2cbb8e)
- **2. Reactive Lasna Execution Tx (`OmniSentinelReactive.react()` -> `CallbackRequest`)**:  
  [`0x3204587016283d4c4a895bde817bad2b788ed851e6b352d5f6ce08919f2865ec`](https://lasna.reactscan.net/tx/0x3204587016283d4c4a895bde817bad2b788ed851e6b352d5f6ce08919f2865ec)
- **3. Destination Settlement Tx (Base Sepolia `CallbackProxy` -> `executeBracketCallback` -> `BracketSettled`)**:  
  [`0x0497c01950b0607d8c9de0fff11c2b8f214cd894d89659e866ee98971c236069`](https://sepolia.basescan.org/tx/0x0497c01950b0607d8c9de0fff11c2b8f214cd894d89659e866ee98971c236069)
- **Wall-Clock Full-Loop Latency**: `4,121 ms` (~4.1 seconds)
- **On-Chain Loop Latency (`loopLatencySec`)**: `1 s`
- **Settled Proceeds**: `3,064.685464 vUSDC`
- **Reactive Lasna Sentinel Counters**: `callbacksDispatched=4`, `completedLoops=4`

---

## 3. Telemetry & Performance Summary

| Scenario | Trigger Price | Executed Price | Wall-Clock Latency | On-Chain Latency (`loopLatencySec`) | Net Settled Proceeds |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Loop 1: Hard Stop-Loss** | $2,820 | $2,805.96 | 2,796 ms | 1 s | 2,805.95 vUSDC |
| **Loop 2: Take-Profit** | $3,350 | $3,333.33 | 3,428 ms | 1 s | 3,333.33 vUSDC |
| **Loop 3: Dynamic Trailing Stop** | $3,080 | $3,064.69 | 4,121 ms | 1 s | 3,064.69 vUSDC |

**Average Loop Latency**: ~3.4 seconds wall-clock across 3 independent multi-chain executions.  
**On-Chain Block Span & Latency Precision**: Every single loop settled in **exactly `5` Base Sepolia `200ms` blocks (`1.0 s` `loopLatencySec`)**: Loop 1 (`58217613 -> 58217618`), Loop 2 (`58217714 -> 58217719`), and Loop 3 (`58217862 -> 58217867`).
