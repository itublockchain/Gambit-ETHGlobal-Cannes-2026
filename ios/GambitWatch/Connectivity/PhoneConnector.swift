import Foundation
import WatchConnectivity
import Combine

/// watchOS side: Manages WatchConnectivity and HTTP fallback.
class PhoneConnector: NSObject, ObservableObject {
    static let shared = PhoneConnector()

    @Published var isPhoneReachable = false
    @Published var latestPrices: [String: PriceUpdate] = [:]
    @Published var markets: [MarketData] = []
    @Published var connectionMethod: ConnectionMethod = .unknown

    private let httpFallback = HTTPFallback()

    enum ConnectionMethod: String {
        case watchConnectivity = "WC"
        case httpPolling = "HTTP"
        case cached = "Cache"
        case unknown = "..."
    }

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Request active markets (Watch → Phone or direct HTTP).
    func requestMarkets() async -> [MarketData] {
        if WCSession.default.isReachable {
            return await requestViaWC(type: .getMarkets)
        } else {
            return (try? await httpFallback.fetchMarkets()) ?? []
        }
    }

    /// Place a bet (Watch → Phone → Backend).
    func placeBet(asset: CryptoAsset, direction: BetDirection, amount: Double) async -> BetResult {
        let message: [String: Any] = [
            WCKey.requestType: WCRequestType.placeBet.rawValue,
            WCKey.asset: asset.rawValue,
            WCKey.direction: direction.rawValue,
            WCKey.amount: amount,
        ]

        if WCSession.default.isReachable {
            return await withCheckedContinuation { continuation in
                WCSession.default.sendMessage(message, replyHandler: { reply in
                    if let status = reply[WCKey.status] as? String, status == "confirmed",
                       let orderId = reply[WCKey.orderId] as? String,
                       let price = reply[WCKey.price] as? Double {
                        continuation.resume(returning: .success(orderId: orderId, price: price))
                    } else {
                        let error = reply[WCKey.error] as? String ?? "Unknown error"
                        continuation.resume(returning: .failure(error))
                    }
                }, errorHandler: { error in
                    continuation.resume(returning: .failure(error.localizedDescription))
                })
            }
        } else {
            // Direct HTTP fallback for LTE-only Watch
            do {
                let result = try await httpFallback.placeBet(
                    asset: asset,
                    direction: direction,
                    amount: amount
                )
                return .success(orderId: result.orderId, price: result.price ?? 0)
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }

    /// Update connection method based on reachability.
    func updateConnectionMethod() {
        if WCSession.default.isReachable {
            connectionMethod = .watchConnectivity
            httpFallback.stopPolling()
        } else {
            connectionMethod = .httpPolling
            httpFallback.startPolling { [weak self] prices in
                DispatchQueue.main.async {
                    self?.latestPrices = prices
                }
            }
        }
    }

    // MARK: - Private

    private func requestViaWC<T: Decodable>(type: WCRequestType) async -> [T] {
        await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(
                [WCKey.requestType: type.rawValue],
                replyHandler: { reply in
                    guard let status = reply[WCKey.status] as? String, status == "ok",
                          let jsonData = reply[WCKey.data] else {
                        continuation.resume(returning: [])
                        return
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: jsonData),
                       let decoded = try? JSONDecoder().decode([T].self, from: data) {
                        continuation.resume(returning: decoded)
                    } else {
                        continuation.resume(returning: [])
                    }
                },
                errorHandler: { _ in
                    continuation.resume(returning: [])
                }
            )
        }
    }
}

// MARK: - WCSessionDelegate

extension PhoneConnector: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
            self.updateConnectionMethod()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
            self.updateConnectionMethod()
        }
    }

    /// Receive push messages from iPhone (price updates, market rotations, auth sync).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let type = message[WCKey.requestType] as? String else { return }

        DispatchQueue.main.async {
            switch type {
            case WCKey.priceUpdate:
                if let jsonData = message[WCKey.data],
                   let data = try? JSONSerialization.data(withJSONObject: jsonData),
                   let updates = try? JSONDecoder().decode([PriceUpdate].self, from: data) {
                    for update in updates {
                        self.latestPrices[update.tokenId] = update
                    }
                }

            case "marketUpdate":
                if let jsonData = message[WCKey.data],
                   let data = try? JSONSerialization.data(withJSONObject: jsonData),
                   let newMarkets = try? JSONDecoder().decode([MarketData].self, from: data) {
                    self.markets = newMarkets
                }

            case "authSync":
                if let token = message[WCKey.sessionToken] as? String {
                    UserDefaults.standard.set(token, forKey: "sessionToken")
                }

            default:
                break
            }
        }
    }

    /// Receive applicationContext fallback (when Watch was not reachable during push).
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            // Sync session token
            if let token = applicationContext[WCKey.sessionToken] as? String {
                UserDefaults.standard.set(token, forKey: "sessionToken")
            }

            if let jsonArray = applicationContext[WCKey.markets] as? [[String: Any]],
               let data = try? JSONSerialization.data(withJSONObject: jsonArray),
               let decoded = try? JSONDecoder().decode([MarketData].self, from: data) {
                self.markets = decoded
            }
        }
    }
}

// MARK: - BetResult

enum BetResult {
    case success(orderId: String, price: Double)
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
