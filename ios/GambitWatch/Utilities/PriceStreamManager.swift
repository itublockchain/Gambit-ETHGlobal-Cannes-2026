import Foundation
import Combine

/// Singleton that maintains ONE SSE connection and distributes prices to all MarketViews.
@MainActor
class PriceStreamManager: ObservableObject {
    static let shared = PriceStreamManager()

    @Published var prices: [String: Double] = [:]

    private var isConnected = false
    private let apiBaseURL: String = {
        #if DEBUG
        return "https://89-167-35-173.nip.io"
        #else
        return "https://api.gambit.app"
        #endif
    }()

    private init() {}

    func startIfNeeded() {
        guard !isConnected else { return }
        isConnected = true
        connectToStream()
    }

    private func connectToStream() {
        guard let url = URL(string: "\(apiBaseURL)/api/v1/markets/stream") else { return }

        // Use a dedicated session to avoid blocking other requests
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)

        Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let (bytes, _) = try await session.bytes(from: url)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "),
                              let jsonData = line.dropFirst(6).data(using: .utf8),
                              let parsed = try? JSONDecoder().decode(SSEPrices.self, from: jsonData) else { continue }

                        await MainActor.run { [weak self] in
                            for (asset, price) in parsed.spotPrices {
                                self?.prices[asset] = price
                            }
                        }
                    }
                } catch {
                    // Reconnect after 2s
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                }
            }
        }
    }
}

private struct SSEPrices: Codable {
    let spotPrices: [String: Double]
}
