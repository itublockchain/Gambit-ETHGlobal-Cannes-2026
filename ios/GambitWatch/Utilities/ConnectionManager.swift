import Foundation
import WatchConnectivity

/// Manages connection strategy: WatchConnectivity → HTTP polling → Cache.
class ConnectionManager: ObservableObject {
    static let shared = ConnectionManager()

    @Published var method: ConnectionMethod = .unknown

    enum ConnectionMethod: String {
        case watchConnectivity = "Live"
        case httpPolling = "Polling"
        case cached = "Cached"
        case unknown = "..."
    }

    func update() {
        if WCSession.default.isReachable {
            method = .watchConnectivity
        } else {
            // Check if network is available (simplified)
            method = .httpPolling
        }
    }
}
