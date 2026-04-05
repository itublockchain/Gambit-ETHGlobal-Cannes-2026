import Foundation

enum Environment {
    static let baseHost = "https://89-167-35-173.nip.io"

    /// Always points to main backend (Polymarket) — used for auth, delegation, etc.
    static let apiBaseURL = "https://89-167-35-173.nip.io"
    static let wsBaseURL = "wss://89-167-35-173.nip.io"

    /// Arc backend — only used explicitly for Arc-specific calls
    static let arcBaseURL = "https://89-167-35-173.nip.io/arc"

    static let dynamicEnvironmentId = "90994e0a-d890-4a28-82a5-e878cc412bf5"
}

/// Toggle between Polymarket (Polygon) and Arc Testnet
enum NetworkMode {
    static var isArc: Bool {
        get { UserDefaults.standard.bool(forKey: "useArcTestnet") }
        set { UserDefaults.standard.set(newValue, forKey: "useArcTestnet") }
    }
    static var displayName: String { isArc ? "Arc Testnet" : "Polymarket" }
}
