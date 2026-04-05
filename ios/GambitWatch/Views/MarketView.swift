import SwiftUI
import Charts
import WatchKit
import WatchConnectivity
import Combine

struct MarketView: View {
    let asset: CryptoAsset
    @StateObject private var viewModel: MarketViewModel

    init(asset: CryptoAsset) {
        self.asset = asset
        _viewModel = StateObject(wrappedValue: MarketViewModel(asset: asset))
    }

    @State private var showBetConfirmation = false
    @State private var betDirection: BetDirection?
    @State private var showPosition = false
    @State private var showPlacing = false
    @State private var positionEntryPrice: Double = 0
    @State private var positionDirection: BetDirection = .up
    @State private var marketEndDate: Date = .now

    var body: some View {
        VStack(spacing: 4) {
            // Header: Asset + price + bet amount
            HStack {
                Text("\(asset.symbol)/USD")
                    .font(.headline).bold()
                Spacer()
                Text(viewModel.displayPrice)
                    .font(.caption)
                    .monospacedDigit()
            }

            // Chart — needs at least 2 points to render
            if viewModel.priceHistory.count >= 2 {
                PriceChartView(
                    priceHistory: viewModel.priceHistory,
                    priceChange: viewModel.priceChange,
                    chartNow: viewModel.chartNow
                )
                .frame(maxHeight: .infinity)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.secondary.opacity(0.1))
                    .frame(maxHeight: .infinity)
                    .overlay {
                        if viewModel.displayPrice == "—" {
                            ProgressView()
                        } else {
                            VStack(spacing: 4) {
                                ProgressView()
                                Text("Building chart...")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
            }

            Spacer(minLength: 0)

            // Swipe instruction
            Text("← DOWN  |  UP →")
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(.leading, 4)
        .padding(.trailing, 12) // Clear scroll indicator
        .padding(.top, 2)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    if value.translation.width > 60 {
                        betDirection = .up
                        WKInterfaceDevice.current().play(.directionUp)
                        showBetConfirmation = true
                    } else if value.translation.width < -60 {
                        betDirection = .down
                        WKInterfaceDevice.current().play(.directionDown)
                        showBetConfirmation = true
                    }
                }
        )
        .sheet(isPresented: $showBetConfirmation) {
            if let direction = betDirection {
                BetConfirmSheet(
                    direction: direction,
                    betAmount: $viewModel.betAmount,
                    maxBetAmount: viewModel.maxBetAmount
                ) {
                    showBetConfirmation = false
                    positionDirection = direction
                    showPlacing = true
                    viewModel.placeBet(direction: direction) { result in
                        if let result = result {
                            positionEntryPrice = viewModel.lastKnownPrice ?? 0
                            if let endStr = result.marketEndDate {
                                let fmt = ISO8601DateFormatter()
                                marketEndDate = fmt.date(from: endStr) ?? Date().addingTimeInterval(300)
                            } else {
                                marketEndDate = Date().addingTimeInterval(300 - Double(Int(Date().timeIntervalSince1970) % 300))
                            }
                            showPlacing = false
                            showPosition = true
                        } else {
                            showPlacing = false
                        }
                    }
                } onCancel: {
                    showBetConfirmation = false
                }
            }
        }
        .task {
            await viewModel.start()
        }
        .sheet(isPresented: $showPlacing) {
            NavigationStack {
                PlacingOrderView(asset: asset, direction: positionDirection, amount: viewModel.betAmount)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $showPosition) {
            NavigationStack {
                ActivePositionView(
                    asset: asset,
                    direction: positionDirection,
                    entryPrice: positionEntryPrice,
                    marketEndDate: marketEndDate,
                    isPresented: $showPosition
                )
                .toolbar(.hidden, for: .navigationBar)
            }
            .interactiveDismissDisabled(true)
        }
    }
}

// MARK: - ViewModel

@MainActor
class MarketViewModel: ObservableObject {
    let asset: CryptoAsset

    @Published var displayPrice: String = "—"
    @Published var priceHistory: [PriceHistoryPoint] = []
    @Published var priceChange: Double = 0
    @Published var chartNow: Date = .now  // drives the sliding window
    @Published var betAmount: Double = UserDefaults.standard.double(forKey: "defaultBetAmount").nonZero ?? 1.0
    @Published var maxBetAmount: Double = 1
    @Published var isBetting = false
    var activePosition: Position?

    private let connector = PhoneConnector.shared
    private let priceStream = PriceStreamManager.shared
    var lastKnownPrice: Double?
    private var priceCancellable: AnyCancellable?
    private var streamCancellable: AnyCancellable?

    private let apiBaseURL: String = {
        #if DEBUG
        return "https://89-167-35-173.nip.io"
        #else
        return "https://api.gambit.app"
        #endif
    }()

    init(asset: CryptoAsset) {
        self.asset = asset
    }

    func start() async {
        // Fetch bet amount + max from server
        await fetchBetAmount()

        // Subscribe to shared price stream (single SSE connection for all assets)
        priceStream.startIfNeeded()
        streamCancellable = priceStream.$prices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prices in
                guard let self, let price = prices[self.asset.rawValue] else { return }
                self.updatePrice(price)
            }

        // Periodic balance refresh (every 10s)
        Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { break }
                await refreshMaxBet()
            }
        }

        // Chart tick — every 0.5s for smoother animation
        var tickCount = 0
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break }
            guard let price = lastKnownPrice else { continue }
            let now = Date()
            let ts = now.timeIntervalSince1970
            tickCount += 1

            priceHistory.append(PriceHistoryPoint(timestamp: ts, price: price))
            chartNow = now

            if priceHistory.count > 180 {
                priceHistory.removeAll { $0.timestamp < ts - 65 }
            }
            if let first = priceHistory.first {
                priceChange = price - first.price
            }
        }
    }

    private func fetchBetAmount() async {
        // Get default bet amount
        if let url = URL(string: "\(apiBaseURL)/api/v1/markets/active"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let response = try? JSONDecoder().decode(WatchMarketsResponse.self, from: data),
           let amount = response.defaultBetAmount, amount > 0 {
            betAmount = amount
        }

        // Get max bet from wallet balance
        if let url = URL(string: "\(apiBaseURL)/api/v1/wallet/balances") {
            var balRequest = URLRequest(url: url)
            if let token = UserDefaults.standard.string(forKey: "sessionToken") {
                balRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let (data, _) = try? await URLSession.shared.data(for: balRequest),
               let wallet = try? JSONDecoder().decode(WalletBalance.self, from: data) {
                maxBetAmount = max(floor(Double(wallet.usdce ?? wallet.total) ?? 1), 1)
            }
        }
    }

    func refreshMaxBet() async {
        if let url = URL(string: "\(apiBaseURL)/api/v1/wallet/balances") {
            var balRequest = URLRequest(url: url)
            if let token = UserDefaults.standard.string(forKey: "sessionToken") {
                balRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let (data, _) = try? await URLSession.shared.data(for: balRequest),
               let wallet = try? JSONDecoder().decode(WalletBalance.self, from: data) {
                let newMax = max(floor(Double(wallet.usdce ?? wallet.total) ?? 1), 1)
                maxBetAmount = newMax
                if betAmount > newMax { betAmount = newMax }
            }
        }
    }

    private func updatePrice(_ price: Double) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let formatted = formatter.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price)
        displayPrice = "$\(formatted)"
        lastKnownPrice = price
    }

}

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

private struct WalletBalance: Codable {
    let total: String
    let usdce: String?
}

extension MarketViewModel {
    /// Place bet — try WatchConnectivity first, fallback to HTTP.
    func placeBet(direction: BetDirection, completion: @escaping (OrderResult?) -> Void) {
        isBetting = true

        // Try WatchConnectivity first
        if WCSession.default.isReachable {
            let message: [String: Any] = [
                WCKey.requestType: WCRequestType.placeBet.rawValue,
                WCKey.asset: asset.rawValue,
                WCKey.direction: direction.rawValue,
                WCKey.amount: betAmount,
            ]
            WCSession.default.sendMessage(message, replyHandler: { reply in
                DispatchQueue.main.async {
                    if let status = reply[WCKey.status] as? String, status == "confirmed",
                       let orderId = reply[WCKey.orderId] as? String {
                        WKInterfaceDevice.current().play(.success)
                        let result = OrderResult(
                            orderId: orderId,
                            clobOrderId: "",
                            status: "matched",
                            asset: self.asset.rawValue,
                            direction: direction.rawValue,
                            price: reply[WCKey.price] as? Double,
                            size: nil,
                            marketEndDate: nil,
                            marketSlug: nil
                        )
                        completion(result)
                        Task { await self.refreshMaxBet() }
                    } else {
                        WKInterfaceDevice.current().play(.failure)
                        completion(nil)
                    }
                    self.isBetting = false
                }
            }, errorHandler: { _ in
                // WC failed — fall through to HTTP
                self.placeBetHTTP(direction: direction, completion: completion)
            })
            return
        }

        // HTTP fallback
        placeBetHTTP(direction: direction, completion: completion)
    }

    private func placeBetHTTP(direction: BetDirection, completion: @escaping (OrderResult?) -> Void) {
        Task {
            let apiBaseURL: String = {
                #if DEBUG
                return "https://89-167-35-173.nip.io"
                #else
                return "https://api.gambit.app"
                #endif
            }()

            guard let url = URL(string: "\(apiBaseURL)/api/v1/orders") else {
                isBetting = false
                completion(nil)
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = UserDefaults.standard.string(forKey: "sessionToken") {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = 15 // 15s timeout for orders
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "asset": asset.rawValue,
                "direction": direction.rawValue,
                "amount": betAmount,
            ] as [String: Any])

            // Use dedicated session (not shared — shared may be blocked by SSE stream)
            let orderSession = URLSession(configuration: .ephemeral)

            do {
                let (data, response) = try await orderSession.data(for: request)
                let httpResponse = response as? HTTPURLResponse

                if httpResponse?.statusCode == 201,
                   let result = try? JSONDecoder().decode(OrderResult.self, from: data) {
                    WKInterfaceDevice.current().play(.success)
                    completion(result)
                    await self.refreshMaxBet()
                } else {
                    WKInterfaceDevice.current().play(.failure)
                    completion(nil)
                }
            } catch {
                WKInterfaceDevice.current().play(.failure)
                completion(nil)
            }

            isBetting = false
        }
    }
}

struct BetConfirmSheet: View {
    let direction: BetDirection
    @Binding var betAmount: Double
    let maxBetAmount: Double
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            // Direction icon
            Image(systemName: direction == .up ? "arrow.up" : "arrow.down")
                .font(.title2).bold()
                .foregroundStyle(direction == .up ? .green : .red)

            // Amount with crown control
            Text("$\(Int(betAmount))")
                .font(.title).bold()
                .focusable()
                .digitalCrownRotation(
                    $betAmount,
                    from: 1,
                    through: max(maxBetAmount, 1),
                    by: 1,
                    sensitivity: .low,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )

            Text("Scroll to adjust")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            // Confirm button
            Button(action: onConfirm) {
                Text("Confirm \(direction.label)")
                    .font(.subheadline).bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(direction == .up ? Color.green : Color.red)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button("Cancel", action: onCancel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal)
    }
}
