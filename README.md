# GAMBIT

**The market fits on your wrist.**

Gambit is a native iOS + Apple Watch app for trading 5-minute crypto prediction markets. Swipe right for UP, swipe left for DOWN — trade executes in ~3 seconds. No seed phrases, no browser extensions, no complex DeFi interfaces. Just your watch and a market opinion.

---

## The Problem

Prediction markets are powerful tools for price discovery and hedging, but they're trapped behind desktop-only interfaces that require technical crypto knowledge. Polymarket — the largest prediction market — has no mobile trading, no watch app, and requires manual wallet management.

Meanwhile, millions of people check their Apple Watch dozens of times a day. What if they could act on a market view in 2 seconds?

## The Solution

Gambit brings prediction markets to the most personal device you own. Real-time crypto charts on your wrist, instant swipe-to-trade, and automatic settlement — all powered by an embedded MPC wallet that requires zero crypto knowledge from the user.

## How It Works

1. **Open iPhone app** → tap "Get Started" → sign in with email (no seed phrase)
2. **Wallet is created automatically** and configured for trading (one-time, ~10 seconds)
3. **Deposit USDC** to your wallet address
4. **Open Apple Watch** → see live crypto charts → swipe to trade
5. **Watch positions resolve** → claim winnings from iPhone

### Under the Hood (~3 seconds)

```
Watch swipe
  → WatchConnectivity message to iPhone
  → iPhone asks backend to prepare EIP-712 order data
  → Dynamic embedded wallet silently signs (no user prompt)
  → Backend submits signed order to Polymarket CLOB
  → Polymarket matches the order (Fill-or-Kill)
  → Result flows back to Watch with haptic feedback
```

The user never sees a transaction, never approves a popup, never deals with gas.

---

## Architecture

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

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **iOS App** | SwiftUI, Combine, Dynamic SDK (embedded MPC wallet) |
| **watchOS App** | SwiftUI, WatchConnectivity, Charts |
| **Backend** | Node.js, TypeScript, Fastify |
| **Database** | PostgreSQL + Drizzle ORM |
| **Cache** | Redis (market data, L2 credentials, price history) |
| **Blockchain** | Polygon PoS (Polymarket), Arc Testnet (custom markets) |
| **Market Data** | Binance WebSocket (spot prices), Polymarket CLOB (odds) |
| **Oracle** | Chainlink CRE (decentralized market settlement) |
| **Wallet** | Dynamic.xyz embedded MPC wallet |
| **Deployment** | Hetzner Helsinki, Caddy (auto SSL) |

---

## Key Features

**Swipe-to-Bet on Apple Watch** — See a 60-second live price chart, swipe right for UP or left for DOWN. Digital Crown selects bet amount. Trade executes in ~3 seconds with haptic feedback.

**Zero-Friction Onboarding** — Sign in with email, wallet is created automatically. No seed phrases, no browser extensions, no MetaMask popups. Dynamic's MPC wallet handles everything.

**Client-Side Signing** — All blockchain transactions are signed on the iPhone using Dynamic's embedded wallet SDK. The backend never has access to private keys. This gives custodial-level UX with self-custodial security.

**Dual Settlement Layer** — Trade on Polymarket (Polygon) for deep liquidity, or switch to Arc Testnet for custom prediction markets with Chainlink CRE settlement. Toggle between networks from settings.

**Real-Time Price Pipeline** — Binance WebSocket streams BTC/ETH/XRP prices → Redis cache → SSE to iPhone → WatchConnectivity batch to Watch. Sub-second price updates across the entire stack.

**Automatic Settlement** — 5-minute markets resolve automatically. On Arc, the Chainlink CRE workflow fetches the final price from Binance, achieves DON consensus, and calls `settleMarket()` on-chain. Winners receive USDC automatically.

---

## Smart Contracts

### GambitMarket.sol (Arc Testnet)

Deployed at [`0xfE3dd8F80051B2F3da054F8657BaF016478697bD`](https://testnet.arcscan.app/address/0xfE3dd8F80051B2F3da054F8657BaF016478697bD)

| Function | Description |
|----------|-------------|
| `createMarket(asset, strikePrice, duration)` | Creates a new 5-min prediction market |
| `placeBet(marketId, direction, amount)` | Places a USDC bet on UP or DOWN |
| `settleMarket(marketId, finalPrice)` | Resolves market with final price (CRE or operator) |
| `claim(marketId)` | Winners withdraw proportional USDC payout |
| `requestSettlement(marketId)` | Emits `SettlementRequested` event for CRE workflow |

### Polymarket Contracts (Polygon)

| Contract | Address | Usage |
|----------|---------|-------|
| CTF Exchange | `0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E` | Order matching |
| Neg Risk Exchange | `0xC5d563A36AE78145C45a50134d48A1215220f80a` | Negative risk markets |
| Conditional Tokens | `0x4D97DCd97eC945f40cF65F87097ACe5EA0476045` | ERC-1155 outcome tokens |
| USDC.e | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | Settlement token |

---

## Chainlink CRE Integration

The CRE workflow provides decentralized, trustless market settlement:

```
1. Contract emits SettlementRequested(marketId, asset, strikePrice, endTime)
2. CRE DON nodes detect the event via LogTrigger
3. Each node fetches BTC/ETH/XRP price from Binance API
4. Nodes reach consensus on the price (identical aggregation)
5. Workflow generates a signed report with encoded settlement data
6. Report is written on-chain → settleMarket() executes
7. Winners receive proportional USDC payout
```

The workflow is compiled to WASM and configured to target Arc Testnet. Backend provides an operator fallback for demo purposes.

---

## Security Model

- **No private keys on server** — Dynamic MPC wallet splits key shares between infrastructure and device
- **Client-side EIP-712 signing** — Backend prepares typed data, iPhone signs, backend submits
- **JWT session tokens** — Stored in iOS Keychain, validated on every request
- **HMAC L2 authentication** — Every Polymarket API call is signed with derived credentials
- **Custom RPC** — Bypass rate-limited default RPCs with dedicated Polygon endpoint

---

## Project Structure

```
gambit/
├── backend/                    # Node.js Fastify server (Polymarket)
│   ├── src/
│   │   ├── modules/            # auth, orders, markets, wallet, prices
│   │   ├── lib/                # polymarket client, dynamic SDK, errors
│   │   ├── plugins/            # postgres, redis, auth, websocket
│   │   └── db/                 # schema + migrations (Drizzle)
│   └── package.json
├── ios/
│   ├── Gambit/                 # iPhone app (SwiftUI)
│   │   ├── Auth/               # AuthManager, DelegationManager, Keychain
│   │   ├── Views/              # LoginView, DashboardView, OnboardingView
│   │   ├── Networking/         # APIClient, WebSocketManager
│   │   └── WatchBridge/        # WatchSessionManager
│   ├── GambitWatch/            # Apple Watch app (SwiftUI)
│   │   ├── Views/              # MarketView, ActivePositionView, Charts
│   │   └── Connectivity/       # PhoneConnector, HTTPFallback
│   └── Shared/                 # SharedModels, MessageKeys
├── arc/
│   ├── contracts/              # GambitMarket.sol (Foundry)
│   ├── cre-workflow/           # Chainlink CRE TypeScript workflow
│   └── backend/                # Arc-specific Fastify server
└── README.md
```

---

## Quick Start

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

## Team

Built by **ITU Blockchain** at ETHGlobal Cannes 2026.

| Name | Role |
|------|------|
| Barış Bice | Full-stack & iOS Development |
| [Team Member] | Smart Contracts & Design |
| [Team Member] | Research & Strategy |

---

## Bounty Submissions

### Dynamic — Embedded Wallet SDK
Native iOS embedded MPC wallet with client-side EIP-712 signing. Zero seed phrases, silent transaction signing, custom Polygon RPC configuration via `evmNetworks`.

### Arc/Circle — Best Prediction Markets on Arc
GambitMarket.sol deployed on Arc Testnet. USDC-native settlement, 5-minute binary options on BTC/ETH/XRP. Stablecoin gas model.

### Chainlink — Best CRE Workflow
TypeScript CRE workflow for decentralized market settlement. Fetches price from Binance via HTTPClient, DON consensus, signed report settles markets on-chain. Compiled to WASM.
