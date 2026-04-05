<img src="assets/banner.jpg" alt="Gambit" width="100%" />

<p align="center">
  <a href="#-how-it-works">How It Works</a> •
  <a href="#%EF%B8%8F-architecture">Architecture</a> •
  <a href="#-key-features">Features</a> •
  <a href="#-smart-contracts">Contracts</a> •
  <a href="#-quick-start">Quick Start</a>
</p>

---

Gambit is a native **iOS + Apple Watch** app for trading 5-minute crypto prediction markets. Swipe right for UP, swipe left for DOWN — trade executes in **~3 seconds**. No seed phrases, no browser extensions, no complex DeFi interfaces. Just your watch and a market opinion.

---

## 🔴 The Problem

Prediction markets are powerful tools for price discovery and hedging, but they're trapped behind desktop-only interfaces that require technical crypto knowledge. Polymarket — the largest prediction market — has no mobile trading, no watch app, and requires manual wallet management.

Meanwhile, millions of people check their Apple Watch dozens of times a day. **What if they could act on a market view in 2 seconds?**

## 💡 The Solution

Gambit brings prediction markets to the most personal device you own. Real-time crypto charts on your wrist, instant swipe-to-trade, and automatic settlement — all powered by an embedded MPC wallet that requires zero crypto knowledge from the user.

---

## ⚡ How It Works

1. 📱 **Open iPhone app** → tap "Get Started" → sign in with email (no seed phrase)
2. 🔐 **Wallet is created automatically** and configured for trading (one-time, ~10 seconds)
3. 💰 **Deposit USDC** to your wallet address
4. ⌚ **Open Apple Watch** → see live crypto charts → swipe to trade
5. 🏆 **Watch positions resolve** → claim winnings from iPhone

### 🔧 Under the Hood (~3 seconds)

```
Watch swipe
  → WatchConnectivity message to iPhone
  → iPhone asks backend to prepare EIP-712 order data
  → Dynamic embedded wallet silently signs (no user prompt)
  → Backend submits signed order to Polymarket CLOB
  → Polymarket matches the order (Fill-or-Kill)
  → Result flows back to Watch with haptic feedback
```

> The user never sees a transaction, never approves a popup, never deals with gas.

---

## 🏗️ Architecture

```
┌─────────────┐     WatchConnectivity     ┌─────────────┐
│ Apple Watch │ ◄──────────────────────► │   iPhone    │
│  SwiftUI    │    price data + trades    │  SwiftUI    │
│  Charts     │                           │  Dynamic SDK│
└─────────────┘                           └──────┬──────┘
                                                  │ HTTPS
                                                  ▼
                                          ┌──────────────┐
                                          │   Backend    │
                                          │  Fastify+TS  │
                                          │  PostgreSQL  │
                                          │    Redis     │
                                          └──┬───┬───┬──┘
                                             │   │   │
                              ┌──────────────┘   │   └──────────────┐
                              ▼                  ▼                  ▼
                      ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
                      │  Polymarket  │  │   Binance    │  │   Polygon    │
                      │  CLOB API   │  │  WebSocket   │  │     RPC      │
                      │  Orders     │  │  BTC/ETH/XRP │  │   USDC/CT    │
                      └──────────────┘  └──────────────┘  └──────────────┘
```

## 🛠️ Tech Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| 📱 **iOS App** | SwiftUI, Combine, Dynamic SDK | Native UI + embedded MPC wallet |
| ⌚ **watchOS App** | SwiftUI, WatchConnectivity | Swipe-to-bet + live charts |
| ⚙️ **Backend** | Node.js, TypeScript, Fastify | Order orchestration + market discovery |
| 🗄️ **Database** | PostgreSQL + Drizzle ORM | Users, wallets, orders, audit log |
| ⚡ **Cache** | Redis | Market data, L2 creds, price history |
| ⛓️ **Blockchain** | Polygon PoS, Arc Testnet | Polymarket settlement + custom markets |
| 📈 **Market Data** | Binance WebSocket, Polymarket CLOB | Real-time spot prices + odds |
| 🔗 **Oracle** | Chainlink CRE | Decentralized market settlement |
| 🔐 **Wallet** | Dynamic.xyz | Embedded MPC wallet, no seed phrases |
| 🌐 **Deployment** | Hetzner Helsinki, Caddy | Auto SSL, no VPN needed |

---

## ✨ Key Features

⌚ **Swipe-to-Bet on Apple Watch** — See a 60-second live price chart, swipe right for UP or left for DOWN. Digital Crown selects bet amount. Trade executes in ~3 seconds with haptic feedback.

🔐 **Zero-Friction Onboarding** — Sign in with email, wallet is created automatically. No seed phrases, no browser extensions, no MetaMask popups. Dynamic's MPC wallet handles everything.

✍️ **Client-Side Signing** — All blockchain transactions are signed on the iPhone using Dynamic's embedded wallet SDK. The backend never has access to private keys. Custodial-level UX with self-custodial security.

🔄 **Dual Settlement Layer** — Trade on Polymarket (Polygon) for deep liquidity, or switch to Arc Testnet for custom prediction markets with Chainlink CRE settlement. Toggle between networks from settings.

📡 **Real-Time Price Pipeline** — Binance WebSocket → Redis → SSE → iPhone → WatchConnectivity → Watch. Sub-second price updates across the entire stack.

🤖 **Automatic Settlement** — 5-minute markets resolve automatically. Chainlink CRE fetches final price, achieves DON consensus, and calls `settleMarket()` on-chain. Winners receive USDC automatically.

---

## 📜 Smart Contracts

### GambitMarket.sol — Arc Testnet

> Deployed at [`0xfE3dd8F80051B2F3da054F8657BaF016478697bD`](https://testnet.arcscan.app/address/0xfE3dd8F80051B2F3da054F8657BaF016478697bD)

| Function | Description |
|----------|-------------|
| `createMarket(asset, strikePrice, duration)` | Creates a new 5-min prediction market |
| `placeBet(marketId, direction, amount)` | Places a USDC bet on UP or DOWN |
| `settleMarket(marketId, finalPrice)` | Resolves market with final price (CRE or operator) |
| `claim(marketId)` | Winners withdraw proportional USDC payout |
| `requestSettlement(marketId)` | Emits `SettlementRequested` event for CRE |

### Polymarket Contracts — Polygon

| Contract | Address | Usage |
|----------|---------|-------|
| CTF Exchange | `0x4bFb41d5...982E` | Order matching engine |
| Neg Risk Exchange | `0xC5d563A3...f80a` | Negative risk markets |
| Conditional Tokens | `0x4D97DCd9...0045` | ERC-1155 outcome tokens |
| USDC.e | `0x2791Bca1...4174` | Settlement token |

---

## 🔗 Chainlink CRE Integration

The CRE workflow provides **decentralized, trustless market settlement**:

```
1. 📋 Contract emits SettlementRequested(marketId, asset, strikePrice, endTime)
2. 👁️ CRE DON nodes detect the event via LogTrigger
3. 🌐 Each node fetches price from Binance API via HTTPClient
4. 🤝 Nodes reach consensus on the price (identical aggregation)
5. 📝 Workflow generates a signed report with encoded settlement data
6. ⛓️ Report is written on-chain → settleMarket() executes
7. 💸 Winners receive proportional USDC payout
```

> Compiled to WASM. Backend provides an operator fallback for demo.

---

## 🛡️ Security Model

| Layer | Approach |
|-------|----------|
| 🔑 **Key Management** | Dynamic MPC — key shares split between infra and device |
| ✍️ **Signing** | Client-side EIP-712 on iPhone — backend never touches keys |
| 🎫 **Sessions** | JWT tokens stored in iOS Keychain |
| 🔒 **API Auth** | HMAC L2 signatures on every Polymarket call |
| 🌐 **RPC** | Custom Polygon endpoint — no rate-limited defaults |

---

## 📁 Project Structure

```
gambit/
├── backend/                    # ⚙️ Node.js Fastify server (Polymarket)
│   ├── src/
│   │   ├── modules/            # auth, orders, markets, wallet, prices
│   │   ├── lib/                # polymarket client, dynamic SDK, errors
│   │   ├── plugins/            # postgres, redis, auth, websocket
│   │   └── db/                 # schema + migrations (Drizzle)
│   └── package.json
├── ios/
│   ├── Gambit/                 # 📱 iPhone app (SwiftUI)
│   │   ├── Auth/               # AuthManager, DelegationManager, Keychain
│   │   ├── Views/              # LoginView, DashboardView, OnboardingView
│   │   ├── Networking/         # APIClient, WebSocketManager
│   │   └── WatchBridge/        # WatchSessionManager
│   ├── GambitWatch/            # ⌚ Apple Watch app (SwiftUI)
│   │   ├── Views/              # MarketView, ActivePositionView, Charts
│   │   └── Connectivity/       # PhoneConnector, HTTPFallback
│   └── Shared/                 # SharedModels, MessageKeys
├── arc/
│   ├── contracts/              # 📜 GambitMarket.sol (Foundry)
│   ├── cre-workflow/           # 🔗 Chainlink CRE TypeScript workflow
│   └── backend/                # ⚙️ Arc-specific Fastify server
└── README.md
```

---

## 🚀 Quick Start

### Prerequisites
- Node.js v22+, npm
- PostgreSQL, Redis
- Xcode 16+ (for iOS/watchOS)
- Foundry (for smart contracts)

### Backend
```bash
cd backend
cp .env.example .env  # fill in credentials
npm install
npx drizzle-kit migrate
npm run dev
```

### iOS App
```bash
cd ios
open Gambit.xcodeproj
# Select Gambit scheme → Build & Run on iPhone
# Select GambitWatch scheme → Build & Run on Watch
```

### Arc Contracts
```bash
cd arc/contracts
forge build
forge script script/Deploy.s.sol --rpc-url https://rpc.testnet.arc.network --broadcast
```

### CRE Workflow
```bash
cd arc/cre-workflow
bun install
bunx cre-compile main.ts gambit-workflow.wasm --skip-type-checks
```

---

## 👥 Team

Built by **ITU Blockchain** at ETHGlobal Cannes 2026.

---

## 🏆 Bounty Submissions

### 🔐 Dynamic — Embedded Wallet SDK
Native iOS embedded MPC wallet with client-side EIP-712 signing. Zero seed phrases, silent transaction signing, custom Polygon RPC configuration via `evmNetworks`.

### 🌐 Arc/Circle — Best Prediction Markets on Arc
GambitMarket.sol deployed on Arc Testnet. USDC-native settlement, 5-minute binary options on BTC/ETH/XRP. Stablecoin gas model.

### 🔗 Chainlink — Best CRE Workflow
TypeScript CRE workflow for decentralized market settlement. Fetches price from Binance via HTTPClient, DON consensus, signed report settles markets on-chain. Compiled to WASM.
