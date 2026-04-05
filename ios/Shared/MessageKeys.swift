import Foundation

/// Constants for WatchConnectivity message keys.
enum WCKey {
    // Request types
    static let requestType = "requestType"
    static let asset = "asset"
    static let direction = "direction"
    static let amount = "amount"

    // Response keys
    static let status = "status"
    static let error = "error"
    static let data = "data"

    // Price updates
    static let priceUpdate = "priceUpdate"
    static let prices = "prices"
    static let timestamp = "timestamp"

    // Market data
    static let markets = "markets"

    // Order data
    static let orderId = "orderId"
    static let price = "price"
    static let size = "size"

    // Auth
    static let sessionToken = "sessionToken"
}

enum WCRequestType: String {
    case getMarkets
    case placeBet
    case getPositions
    case getHistory
}
