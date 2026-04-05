import Foundation
import WatchConnectivity
import Combine
import DynamicSDKSwift

/// iPhone side: Manages WatchConnectivity session and forwards data to Watch.
class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    @Published var isWatchReachable = false

    private var priceUpdateCancellable: AnyCancellable?
    private var priceBatchTimer: Timer?
    private var pendingPriceUpdates: [String: PriceUpdate] = [:]

    override init() {
        super.init()

        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()

        // Listen for price updates from WebSocket and forward to Watch
        priceUpdateCancellable = WebSocketManager.shared.priceUpdateSubject
            .sink { [weak self] update in
                self?.bufferPriceUpdate(update)
            }

        // Batch price updates every 1 second to avoid flooding WatchConnectivity
        priceBatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.flushPriceUpdates()
        }
    }

    /// Push market data to Watch.
    func pushMarkets(_ markets: [MarketData]) {
        guard WCSession.default.isReachable else {
            // Fallback: applicationContext (latest state, not queued)
            if let data = try? JSONEncoder().encode(markets),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                try? WCSession.default.updateApplicationContext([
                    WCKey.markets: json,
                    WCKey.timestamp: Date().timeIntervalSince1970,
                ])
            }
            return
        }

        if let data = try? JSONEncoder().encode(markets),
           let json = try? JSONSerialization.jsonObject(with: data) {
            WCSession.default.sendMessage(
                [WCKey.requestType: "marketUpdate", WCKey.data: json],
                replyHandler: nil
            )
        }
    }

    // MARK: - Price Batching

    private func bufferPriceUpdate(_ update: PriceUpdate) {
        pendingPriceUpdates[update.tokenId] = update
    }

    private func flushPriceUpdates() {
        guard !pendingPriceUpdates.isEmpty, WCSession.default.isReachable else { return }

        if let data = try? JSONEncoder().encode(Array(pendingPriceUpdates.values)),
           let json = try? JSONSerialization.jsonObject(with: data) {
            WCSession.default.sendMessage(
                [WCKey.requestType: WCKey.priceUpdate, WCKey.data: json],
                replyHandler: nil
            )
        }

        pendingPriceUpdates.removeAll()
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
        // Send session token to Watch when it becomes reachable
        if session.isReachable {
            sendSessionTokenToWatch()
        }
    }

    /// Send the current session token to Watch for HTTP fallback auth.
    func sendSessionTokenToWatch() {
        guard let token = KeychainService.sessionToken else { return }
        // Use applicationContext so Watch always has the latest token even if not reachable at the moment
        do {
            var ctx = WCSession.default.applicationContext
            ctx[WCKey.sessionToken] = token
            try WCSession.default.updateApplicationContext(ctx)
        } catch {}
        // Also send via message if reachable for immediate delivery
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(
                [WCKey.requestType: "authSync", WCKey.sessionToken: token],
                replyHandler: nil
            )
        }
    }

    /// Handle messages from Watch (bet requests, data requests).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard let requestType = message[WCKey.requestType] as? String else {
            replyHandler([WCKey.status: "error", WCKey.error: "Missing request type"])
            return
        }

        Task {
            do {
                switch requestType {
                case WCRequestType.placeBet.rawValue:
                    let result = try await handlePlaceBet(message)
                    replyHandler(result)

                case "sellPosition":
                    let result = try await handleSellPosition(message)
                    replyHandler(result)

                case WCRequestType.getMarkets.rawValue:
                    let result = try await handleGetMarkets()
                    replyHandler(result)

                case WCRequestType.getPositions.rawValue:
                    let result = try await handleGetPositions()
                    replyHandler(result)

                case WCRequestType.getHistory.rawValue:
                    let result = try await handleGetHistory()
                    replyHandler(result)

                default:
                    replyHandler([WCKey.status: "error", WCKey.error: "Unknown request type"])
                }
            } catch {
                replyHandler([WCKey.status: "error", WCKey.error: error.localizedDescription])
            }
        }
    }

    // MARK: - Request Handlers

    private func handlePlaceBet(_ message: [String: Any]) async throws -> [String: Any] {
        guard let assetStr = message[WCKey.asset] as? String,
              let asset = CryptoAsset(rawValue: assetStr),
              let dirStr = message[WCKey.direction] as? String,
              let direction = BetDirection(rawValue: dirStr),
              let amount = message[WCKey.amount] as? Double else {
            return [WCKey.status: "error", WCKey.error: "Invalid bet parameters"]
        }

        // Arc mode: simple HTTP call to Arc backend, no signing needed
        if NetworkMode.isArc {
            let result: OrderResult = try await APIClient.shared.requestURL(
                url: "\(Environment.arcBaseURL)/api/v1/orders",
                method: "POST",
                body: [
                    "asset": asset.rawValue,
                    "direction": direction.rawValue,
                    "amount": amount,
                ]
            )
            return [
                WCKey.status: "confirmed",
                WCKey.orderId: result.orderId,
                WCKey.price: result.price ?? 0,
                WCKey.size: result.size ?? 0,
            ]
        }

        // Polymarket mode: prepare → sign → submit
        guard let sdk = await MainActor.run(body: { DynamicSDK.shared }),
              let wallet = await MainActor.run(body: { sdk.wallets.userWallets.first }) else {
            return [WCKey.status: "error", WCKey.error: "Wallet not available"]
        }

        for attempt in 1...3 {
            let prepared: PreparedOrder = try await APIClient.shared.request(
                endpoint: "/api/v1/orders/prepare",
                method: "POST",
                body: [
                    "asset": asset.rawValue,
                    "direction": direction.rawValue,
                    "amount": amount,
                ]
            )

            let typedDataJson = buildOrderTypedDataJson(prepared: prepared)
            let signature = try await sdk.wallets.signTypedData(
                wallet: wallet,
                typedDataJson: typedDataJson
            )

            let result: OrderResult = try await APIClient.shared.request(
                endpoint: "/api/v1/orders/submit-signed",
                method: "POST",
                body: [
                    "orderId": prepared.orderId,
                    "signature": signature,
                ]
            )

            if result.status == "matched" || result.status == "200" || result.status == "201" {
                return [
                    WCKey.status: "confirmed",
                    WCKey.orderId: result.orderId,
                    WCKey.price: result.price ?? 0,
                    WCKey.size: result.size ?? 0,
                ]
            }

            if attempt < 3 {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        return [WCKey.status: "error", WCKey.error: "No liquidity available"]
    }

    private func handleSellPosition(_ message: [String: Any]) async throws -> [String: Any] {
        guard let assetStr = message[WCKey.asset] as? String,
              let dirStr = message[WCKey.direction] as? String else {
            return [WCKey.status: "error", WCKey.error: "Invalid parameters"]
        }

        // 1. Prepare sell order
        let prepared: PreparedOrder = try await APIClient.shared.request(
            endpoint: "/api/v1/orders/sell-prepare",
            method: "POST",
            body: ["asset": assetStr, "direction": dirStr]
        )

        // 2. Sign with Dynamic SDK
        guard let sdk = await MainActor.run(body: { DynamicSDK.shared }),
              let wallet = await MainActor.run(body: { sdk.wallets.userWallets.first }) else {
            return [WCKey.status: "error", WCKey.error: "Wallet not available"]
        }

        // CT approval for sell (setApprovalForAll)
        let ctAddress = "0x4D97DCd97eC945f40cF65F87097ACe5EA0476045"
        let ctfExchange = "0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E"
        let negRiskExchange = "0xC5d563A36AE78145C45a50134d48A1215220f80a"
        let approveAllData = "0xa22cb465000000000000000000000000\(ctfExchange.dropFirst(2))0000000000000000000000000000000000000000000000000000000000000001"
        let approveAllData2 = "0xa22cb465000000000000000000000000\(negRiskExchange.dropFirst(2))0000000000000000000000000000000000000000000000000000000000000001"

        for data in [approveAllData, approveAllData2] {
            let tx = EthereumTransaction(from: wallet.address, to: ctAddress, data: data)
            _ = try? await sdk.evm.sendTransaction(transaction: tx, wallet: wallet)
        }

        let typedDataJson = buildOrderTypedDataJson(prepared: prepared)
        let signature = try await sdk.wallets.signTypedData(
            wallet: wallet,
            typedDataJson: typedDataJson
        )

        // 3. Submit signed sell order
        let result: OrderResult = try await APIClient.shared.request(
            endpoint: "/api/v1/orders/submit-signed",
            method: "POST",
            body: ["orderId": prepared.orderId, "signature": signature]
        )

        return [WCKey.status: "ok", WCKey.orderId: result.orderId]
    }

    private func buildOrderTypedDataJson(prepared: PreparedOrder) -> String {
        """
        {
            "types": {
                "EIP712Domain": [
                    {"name": "name", "type": "string"},
                    {"name": "version", "type": "string"},
                    {"name": "chainId", "type": "uint256"},
                    {"name": "verifyingContract", "type": "address"}
                ],
                "Order": [
                    {"name": "salt", "type": "uint256"},
                    {"name": "maker", "type": "address"},
                    {"name": "signer", "type": "address"},
                    {"name": "taker", "type": "address"},
                    {"name": "tokenId", "type": "uint256"},
                    {"name": "makerAmount", "type": "uint256"},
                    {"name": "takerAmount", "type": "uint256"},
                    {"name": "expiration", "type": "uint256"},
                    {"name": "nonce", "type": "uint256"},
                    {"name": "feeRateBps", "type": "uint256"},
                    {"name": "side", "type": "uint8"},
                    {"name": "signatureType", "type": "uint8"}
                ]
            },
            "primaryType": "Order",
            "domain": {
                "name": "\(prepared.domain.name)",
                "version": "\(prepared.domain.version)",
                "chainId": \(prepared.domain.chainId),
                "verifyingContract": "\(prepared.domain.verifyingContract)"
            },
            "message": {
                "salt": "\(prepared.message.salt)",
                "maker": "\(prepared.message.maker)",
                "signer": "\(prepared.message.signer)",
                "taker": "\(prepared.message.taker)",
                "tokenId": "\(prepared.message.tokenId)",
                "makerAmount": "\(prepared.message.makerAmount)",
                "takerAmount": "\(prepared.message.takerAmount)",
                "expiration": "\(prepared.message.expiration)",
                "nonce": "\(prepared.message.nonce)",
                "feeRateBps": "\(prepared.message.feeRateBps)",
                "side": \(prepared.message.side),
                "signatureType": \(prepared.message.signatureType)
            }
        }
        """
    }

    private func handleGetMarkets() async throws -> [String: Any] {
        let markets = try await APIClient.shared.getActiveMarkets()
        let data = try JSONEncoder().encode(markets)
        let json = try JSONSerialization.jsonObject(with: data)
        return [WCKey.status: "ok", WCKey.data: json]
    }

    private func handleGetPositions() async throws -> [String: Any] {
        let positions = try await APIClient.shared.getPositions()
        let data = try JSONEncoder().encode(positions)
        let json = try JSONSerialization.jsonObject(with: data)
        return [WCKey.status: "ok", WCKey.data: json]
    }

    private func handleGetHistory() async throws -> [String: Any] {
        let orders = try await APIClient.shared.getOrderHistory()
        let data = try JSONEncoder().encode(orders)
        let json = try JSONSerialization.jsonObject(with: data)
        return [WCKey.status: "ok", WCKey.data: json]
    }
}
