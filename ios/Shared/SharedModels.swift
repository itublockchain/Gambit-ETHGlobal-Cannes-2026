import Foundation

// MARK: - Crypto Assets

enum CryptoAsset: String, Codable, CaseIterable {
    case btc, eth, xrp

    var symbol: String {
        rawValue.uppercased()
    }

    var displayName: String {
        switch self {
        case .btc: return "Bitcoin"
        case .eth: return "Ethereum"
        case .xrp: return "XRP"
        }
    }
}

// MARK: - Bet Direction

enum BetDirection: String, Codable {
    case up, down

    var label: String {
        switch self {
        case .up: return "UP ↑"
        case .down: return "DOWN ↓"
        }
    }
}

// MARK: - Market Data

struct MarketData: Codable {
    let asset: CryptoAsset
    let slug: String
    let conditionId: String
    let upTokenId: String
    let downTokenId: String
    let upPrice: String
    let downPrice: String
    let endDate: String
    let question: String
}

struct MarketPrices: Codable {
    let btc: PricePoint?
    let eth: PricePoint?
    let xrp: PricePoint?
    let timestamp: TimeInterval
}

struct PriceUpdate: Codable {
    let type: String
    let tokenId: String
    let price: String
    let timestamp: TimeInterval
}

struct PricePoint: Codable {
    let price: String
    let timestamp: TimeInterval
}

// MARK: - Price History

struct PriceHistoryPoint: Identifiable, Codable {
    var id: TimeInterval { timestamp }
    let timestamp: TimeInterval
    let price: Double
}

// MARK: - Order

struct OrderResult: Codable {
    let orderId: String
    let clobOrderId: String?
    let status: String
    let asset: String?
    let direction: String?
    let price: Double?
    let size: Double?
    let marketEndDate: String?
    let marketSlug: String?

    init(orderId: String, clobOrderId: String? = nil, status: String, asset: String? = nil, direction: String? = nil, price: Double? = nil, size: Double? = nil, marketEndDate: String? = nil, marketSlug: String? = nil) {
        self.orderId = orderId
        self.clobOrderId = clobOrderId
        self.status = status
        self.asset = asset
        self.direction = direction
        self.price = price
        self.size = size
        self.marketEndDate = marketEndDate
        self.marketSlug = marketSlug
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orderId = (try? c.decode(String.self, forKey: .orderId)) ?? ""
        clobOrderId = try? c.decode(String.self, forKey: .clobOrderId)
        // status can be String or Int
        if let s = try? c.decode(String.self, forKey: .status) {
            status = s
        } else if let n = try? c.decode(Int.self, forKey: .status) {
            status = "\(n)"
        } else {
            status = "unknown"
        }
        asset = try? c.decode(String.self, forKey: .asset)
        direction = try? c.decode(String.self, forKey: .direction)
        price = try? c.decode(Double.self, forKey: .price)
        size = try? c.decode(Double.self, forKey: .size)
        marketEndDate = try? c.decode(String.self, forKey: .marketEndDate)
        marketSlug = try? c.decode(String.self, forKey: .marketSlug)
    }
}

// MARK: - Position

struct Position: Codable, Identifiable {
    let id: String
    let tokenId: String
    let conditionId: String
    let marketSlug: String?
    let outcome: String
    let size: String
    let avgPrice: String
    let realizedPnl: String

    var cashPnl: Double {
        Double(realizedPnl) ?? 0
    }

    var percentPnl: Double {
        guard let avg = Double(avgPrice), let sz = Double(size), avg > 0, sz > 0 else { return 0 }
        return (cashPnl / (avg * sz)) * 100
    }
}

// MARK: - Trade History

struct Trade: Codable, Identifiable {
    let id: String
    let asset: String
    let direction: BetDirection
    let price: Double
    let size: Double
    let status: String
    let pnl: Double
    let date: Date
}

// MARK: - Active Markets Response

struct ActiveMarketsResponse: Codable {
    let markets: [MarketData]
    let spotPrices: [String: Double]?
}

/// Watch-specific response (same structure, used by MarketViewModel)
struct WatchMarketsResponse: Codable {
    let markets: [MarketData]
    let spotPrices: [String: Double]?
    let defaultBetAmount: Double?
}

struct OrdersResponse: Codable {
    let orders: [OrderRecord]
}

struct OrderRecord: Codable, Identifiable {
    let id: String
    let clobOrderId: String?
    let marketSlug: String?
    let side: String
    let orderType: String
    let price: String
    let size: String
    let filledSize: String
    let status: String
    let outcome: String?
    let createdAt: String
}

struct PositionsResponse: Codable {
    let positions: [Position]
}

// MARK: - Prepared Order (for client-side signing)

struct PreparedOrder: Codable {
    let orderId: String
    let domain: OrderDomain
    let types: [String: [OrderField]]
    let message: OrderMessage
    let tokenId: String
    let price: Double
    let marketSlug: String
    let endDate: String
}

struct OrderDomain: Codable {
    let name: String
    let version: String
    let chainId: Int
    let verifyingContract: String
}

struct OrderField: Codable {
    let name: String
    let type: String
}

struct OrderMessage: Codable {
    let salt: String
    let maker: String
    let signer: String
    let taker: String
    let tokenId: String
    let makerAmount: String
    let takerAmount: String
    let expiration: String
    let nonce: String
    let feeRateBps: String
    let side: Int
    let signatureType: Int
}
