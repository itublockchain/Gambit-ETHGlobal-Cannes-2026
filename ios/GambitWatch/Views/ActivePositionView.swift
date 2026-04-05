import SwiftUI
import Charts
import WatchKit
import WatchConnectivity

struct ActivePositionView: View {
    let asset: CryptoAsset
    let direction: BetDirection
    let entryPrice: Double
    let marketEndDate: Date
    @Binding var isPresented: Bool

    @State private var currentPrice: Double = 0
    @State private var priceHistory: [PriceHistoryPoint] = []
    @State private var timeRemaining: String = ""
    @State private var chartNow: Date = .now
    @State private var pnlDollar: Double = 0
    @State private var pnlPercent: Double = 0
    @State private var positionValue: Double = 0
    @State private var isSelling = false
    @State private var lastHapticPnl: Double = 0 // Track last haptic threshold

    private var isWinning: Bool { pnlDollar >= 0 }
    private var pnlColor: Color { isWinning ? .green : .red }

    private let apiBaseURL: String = {
        #if DEBUG
        return "https://89-167-35-173.nip.io"
        #else
        return "https://api.gambit.app"
        #endif
    }()

    var body: some View {
        VStack(spacing: 3) {
            // Header
            HStack {
                Text("\(asset.symbol)")
                    .font(.headline).bold()
                Text(direction.label)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(direction == .up ? Color.green.opacity(0.3) : Color.red.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Spacer()
                Text(timeRemaining)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            .padding(.top, 4)

            // P&L from Polymarket
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(pnlDollar >= 0 ? "+\(formatPrice(pnlDollar))" : formatPrice(pnlDollar))
                        .font(.title3).bold()
                        .foregroundStyle(pnlColor)
                    Text(String(format: "%.1f%%", pnlPercent))
                        .font(.caption)
                        .foregroundStyle(pnlColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Value")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text(formatPrice(positionValue))
                        .font(.caption).bold()
                }
            }

            // Current price + status
            HStack {
                Text(formatPrice(currentPrice))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(pnlColor)
                Spacer()
                Text(isWinning ? "WINNING" : "LOSING")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(pnlColor)
            }

            // Chart
            if priceHistory.count >= 2 {
                Chart(priceHistory) { point in
                    LineMark(
                        x: .value("T", Date(timeIntervalSince1970: point.timestamp)),
                        y: .value("P", point.price)
                    )
                    .foregroundStyle(pnlColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }
                .chartYScale(domain: chartYRange)
                .chartXScale(domain: chartTimeWindow)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(maxHeight: .infinity)
                .animation(.linear(duration: 0.9), value: chartNow)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }

            // Sell button
            Button {
                sellPosition()
            } label: {
                if isSelling {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("SELL")
                        .font(.caption).bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.8))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .buttonStyle(.plain)
            .disabled(isSelling)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .task {
            await startTracking()
        }
    }

    // MARK: - Chart helpers

    private var chartYRange: ClosedRange<Double> {
        let prices = priceHistory.map(\.price)
        guard let minP = prices.min(), let maxP = prices.max() else { return 0...1 }
        var spread = maxP - minP
        if spread < maxP * 0.0003 { spread = maxP * 0.0003 }
        let mid = (minP + maxP) / 2
        return (mid - spread * 1.2)...(mid + spread * 1.2)
    }

    private var chartTimeWindow: ClosedRange<Date> {
        return chartNow.addingTimeInterval(-60)...chartNow
    }

    // MARK: - Tracking

    private func startTracking() async {
        currentPrice = entryPrice

        // SSE for live price
        Task.detached {
            guard let url = URL(string: "\(apiBaseURL)/api/v1/markets/stream") else { return }
            while !Task.isCancelled {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(from: url)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "),
                              let data = line.dropFirst(6).data(using: .utf8),
                              let parsed = try? JSONDecoder().decode(SSEData.self, from: data),
                              let price = parsed.spotPrices[asset.rawValue] else { continue }
                        await MainActor.run { currentPrice = price }
                    }
                } catch {
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                }
            }
        }

        // Poll Polymarket for real P&L every 5s
        Task.detached {
            while !Task.isCancelled {
                await fetchPositionPnL()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
            }
        }

        // Chart tick + countdown
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }

            let now = Date()
            let remaining = marketEndDate.timeIntervalSince(now)
            if remaining <= 0 {
                WKInterfaceDevice.current().play(.notification)
                isPresented = false
                return
            }
            timeRemaining = String(format: "%d:%02d", Int(remaining) / 60, Int(remaining) % 60)

            priceHistory.append(PriceHistoryPoint(timestamp: now.timeIntervalSince1970, price: currentPrice))
            chartNow = now
            if priceHistory.count > 90 {
                priceHistory.removeAll { $0.timestamp < now.timeIntervalSince1970 - 65 }
            }
        }
    }

    @MainActor
    private func fetchPositionPnL() async {
        guard let balUrl = URL(string: "\(apiBaseURL)/api/v1/wallet/balances") else { return }
        var balReq = URLRequest(url: balUrl)
        if let token = UserDefaults.standard.string(forKey: "sessionToken") {
            balReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let balData = try? await URLSession.shared.data(for: balReq).0,
              let wallet = try? JSONDecoder().decode(WalletResp.self, from: balData),
              let address = wallet.walletAddress else { return }

        guard let url = URL(string: "https://data-api.polymarket.com/positions?user=\(address)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let positions = try? JSONDecoder().decode([PMPos].self, from: data) else { return }

        let name = asset == .btc ? "Bitcoin" : asset == .eth ? "Ethereum" : "XRP"
        // Find the most recently created active position for this asset
        let matching = positions
            .filter { $0.title?.contains(name) == true && ($0.curPrice ?? 0) > 0 && ($0.curPrice ?? 0) < 1 }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        if let pos = matching.first {
            let newPnl = pos.cashPnl ?? 0
            let newValue = pos.currentValue ?? 0

            // Haptic at milestones: every $0.50 change in position value
            let newThreshold = (newValue * 2).rounded() / 2 // Round to nearest $0.50
            if newThreshold != lastHapticPnl && lastHapticPnl != 0 {
                if newValue > 1.0 { // Only when position is significant
                    if newPnl > 0 {
                        WKInterfaceDevice.current().play(.success) // Winning haptic
                    } else {
                        WKInterfaceDevice.current().play(.failure) // Losing haptic
                    }
                }
            }
            lastHapticPnl = newThreshold

            pnlDollar = newPnl
            pnlPercent = pos.percentPnl ?? 0
            positionValue = newValue
        }
    }

    // MARK: - Sell

    private func sellPosition() {
        isSelling = true
        Task {
            let message: [String: Any] = [
                WCKey.requestType: "sellPosition",
                WCKey.asset: asset.rawValue,
                WCKey.direction: direction.rawValue,
            ]

            if WCSession.default.isReachable {
                WCSession.default.sendMessage(message, replyHandler: { reply in
                    DispatchQueue.main.async {
                        if let status = reply[WCKey.status] as? String, status == "ok" {
                            WKInterfaceDevice.current().play(.success)
                            isPresented = false
                        } else {
                            WKInterfaceDevice.current().play(.failure)
                        }
                        isSelling = false
                    }
                }, errorHandler: { _ in
                    DispatchQueue.main.async {
                        WKInterfaceDevice.current().play(.failure)
                        isSelling = false
                    }
                })
            } else {
                // HTTP fallback — can't sell without iOS signing
                WKInterfaceDevice.current().play(.failure)
                isSelling = false
            }
        }
    }

    private func formatPrice(_ price: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        return "$\(fmt.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price))"
    }
}

private struct SSEData: Codable { let spotPrices: [String: Double] }
private struct WalletResp: Codable { let walletAddress: String? }
private struct PMPos: Codable {
    let title: String?
    let size: Double?
    let avgPrice: Double?
    let curPrice: Double?
    let cashPnl: Double?
    let percentPnl: Double?
    let currentValue: Double?
    let createdAt: String?
    let endDate: String?
}
