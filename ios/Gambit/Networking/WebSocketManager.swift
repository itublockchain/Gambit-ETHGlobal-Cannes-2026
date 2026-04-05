import Foundation
import Combine

/// Manages WebSocket connection to backend for real-time price updates.
class WebSocketManager: ObservableObject {
    static let shared = WebSocketManager()

    @Published var isConnected = false

    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var subscribedTokenIds = Set<String>()

    /// Publisher for incoming price updates.
    let priceUpdateSubject = PassthroughSubject<PriceUpdate, Never>()

    private init() {}

    func connect() {
        guard webSocketTask == nil else { return }

        let wsURL = "\(Environment.wsBaseURL)/ws/prices"
        guard let url = URL(string: wsURL) else { return }

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        isConnected = true

        // Re-subscribe to previously tracked tokens
        if !subscribedTokenIds.isEmpty {
            sendSubscribe(Array(subscribedTokenIds))
        }

        receiveMessages()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    /// Subscribe to price updates for given token IDs.
    func subscribe(tokenIds: [String]) {
        for id in tokenIds {
            subscribedTokenIds.insert(id)
        }
        if isConnected {
            sendSubscribe(tokenIds)
        }
    }

    /// Unsubscribe from token IDs.
    func unsubscribe(tokenIds: [String]) {
        for id in tokenIds {
            subscribedTokenIds.remove(id)
        }
        if isConnected {
            sendUnsubscribe(tokenIds)
        }
    }

    // MARK: - Private

    private func sendSubscribe(_ tokenIds: [String]) {
        let message: [String: Any] = ["action": "subscribe", "tokenIds": tokenIds]
        send(message)
    }

    private func sendUnsubscribe(_ tokenIds: [String]) {
        let message: [String: Any] = ["action": "unsubscribe", "tokenIds": tokenIds]
        send(message)
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(string)) { _ in }
    }

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self?.receiveMessages()

            case .failure:
                DispatchQueue.main.async {
                    self?.isConnected = false
                }
                // Reconnect after delay
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    self?.webSocketTask = nil
                    self?.connect()
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let update = try? JSONDecoder().decode(PriceUpdate.self, from: data) else { return }

        DispatchQueue.main.async {
            self.priceUpdateSubject.send(update)
        }
    }
}
