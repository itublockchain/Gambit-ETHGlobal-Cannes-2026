import Foundation

/// Generic API client for backend communication.
class APIClient {
    static let shared = APIClient()

    private let session = URLSession.shared
    private let baseURL: String

    private init() {
        self.baseURL = Environment.apiBaseURL
    }

    /// Make a request to an explicit URL (no base URL prefix).
    func requestURL<T: Decodable>(
        url urlString: String,
        method: String = "POST",
        body: [String: Any]? = nil
    ) async throws -> T {
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(httpResponse.statusCode, errorBody)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// Make an authenticated (or unauthenticated) API request.
    func request<T: Decodable>(
        endpoint: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Inject auth header
        if authenticated, let token = KeychainService.sessionToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Body
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(httpResponse.statusCode, errorBody)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// Place a bet through the backend.
    func placeBet(asset: CryptoAsset, direction: BetDirection, amount: Double) async throws -> OrderResult {
        try await request(
            endpoint: "/api/v1/orders",
            method: "POST",
            body: [
                "asset": asset.rawValue,
                "direction": direction.rawValue,
                "amount": amount,
            ]
        )
    }

    /// Get active markets.
    func getActiveMarkets() async throws -> [MarketData] {
        let response: ActiveMarketsResponse = try await request(
            endpoint: "/api/v1/markets/active",
            authenticated: false
        )
        return response.markets
    }

    /// Get user positions.
    func getPositions() async throws -> [Position] {
        let response: PositionsResponse = try await request(endpoint: "/api/v1/positions")
        return response.positions
    }

    /// Get order history.
    func getOrderHistory() async throws -> [OrderRecord] {
        let response: OrdersResponse = try await request(endpoint: "/api/v1/orders")
        return response.orders
    }
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .unauthorized: return "Session expired"
        case .serverError(let code, let body): return "Server error \(code): \(body)"
        }
    }
}
