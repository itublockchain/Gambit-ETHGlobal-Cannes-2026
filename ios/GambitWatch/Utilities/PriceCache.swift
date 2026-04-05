import Foundation

/// Cache prices in UserDefaults for offline fallback.
enum PriceCache {
    private static let pricesKey = "cachedPrices"
    private static let timestampKey = "cachedPricesDate"

    static func save(_ prices: [String: PriceUpdate]) {
        if let data = try? JSONEncoder().encode(prices) {
            UserDefaults.standard.set(data, forKey: pricesKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)
        }
    }

    static func load() -> (prices: [String: PriceUpdate], isStale: Bool)? {
        guard let data = UserDefaults.standard.data(forKey: pricesKey),
              let prices = try? JSONDecoder().decode([String: PriceUpdate].self, from: data) else {
            return nil
        }

        let savedTimestamp = UserDefaults.standard.double(forKey: timestampKey)
        let age = Date().timeIntervalSince1970 - savedTimestamp
        let isStale = age > 30 // 30 seconds

        return (prices, isStale)
    }
}
