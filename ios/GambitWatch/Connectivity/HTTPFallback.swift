import Foundation

/// Direct HTTP polling for when iPhone is unreachable (LTE-only Watch).
class HTTPFallback {
    private var timer: Timer?
    private let session = URLSession.shared
    private let baseURL: String = {
        #if DEBUG
        return "https://89-167-35-173.nip.io"
        #else
        return "https://api.gambit.app"
        #endif
    }()

    /// Start polling for prices every 3 seconds.
    func startPolling(onUpdate: @escaping ([String: PriceUpdate]) -> Void) {
        stopPolling()

        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.fetchPrices(onUpdate: onUpdate)
        }

        // Immediate first fetch
        fetchPrices(onUpdate: onUpdate)
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Fetch active markets directly from backend.
    func fetchMarkets() async throws -> [MarketData] {
        guard let url = URL(string: "\(baseURL)/api/v1/markets/active") else {
            throw URLError(.badURL)
        }

        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(ActiveMarketsResponse.self, from: data)
        return response.markets
    }

    /// Place a bet directly via backend HTTP (for LTE-only Watch).
    func placeBet(asset: CryptoAsset, direction: BetDirection, amount: Double) async throws -> OrderResult {
        guard let url = URL(string: "\(baseURL)/api/v1/orders") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Auth token from Watch's local storage
        if let token = UserDefaults.standard.string(forKey: "sessionToken") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "asset": asset.rawValue,
            "direction": direction.rawValue,
            "amount": amount,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(OrderResult.self, from: data)
    }

    // MARK: - Private

    private func fetchPrices(onUpdate: @escaping ([String: PriceUpdate]) -> Void) {
        guard let url = URL(string: "\(baseURL)/api/v1/markets/active") else { return }

        session.dataTask(with: url) { data, _, error in
            guard let data = data, error == nil else { return }
            guard let response = try? JSONDecoder().decode(ActiveMarketsResponse.self, from: data) else { return }

            var prices: [String: PriceUpdate] = [:]
            let now = Date().timeIntervalSince1970

            for market in response.markets {
                prices[market.upTokenId] = PriceUpdate(
                    type: "price",
                    tokenId: market.upTokenId,
                    price: market.upPrice,
                    timestamp: now
                )
                prices[market.downTokenId] = PriceUpdate(
                    type: "price",
                    tokenId: market.downTokenId,
                    price: market.downPrice,
                    timestamp: now
                )
            }

            DispatchQueue.main.async {
                onUpdate(prices)
                // Cache for offline
                PriceCache.save(prices)
            }
        }.resume()
    }
}
