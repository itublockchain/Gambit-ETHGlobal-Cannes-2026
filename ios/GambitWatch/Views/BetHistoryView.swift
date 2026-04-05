import SwiftUI

struct BetHistoryView: View {
    @State private var positions: [PositionInfo] = []
    @State private var isLoading = true

    private let apiBaseURL: String = {
        #if DEBUG
        return "https://89-167-35-173.nip.io"
        #else
        return "https://api.gambit.app"
        #endif
    }()

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
            } else if positions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No trades yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                List(positions) { pos in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pos.assetName)
                                .font(.caption).bold()
                            HStack(spacing: 4) {
                                Text(pos.direction)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(pos.direction == "Up" ? Color.green.opacity(0.3) : Color.red.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                Text(pos.sharesText)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(pos.pnlText)
                                .font(.caption2).bold()
                                .foregroundStyle(pos.pnlColor)
                            Text(pos.pctText)
                                .font(.system(size: 9))
                                .foregroundStyle(pos.pnlColor)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("History")
        .task {
            await loadPositions()
        }
    }

    private func loadPositions() async {
        // Get wallet address
        guard let walletUrl = URL(string: "\(apiBaseURL)/api/v1/wallet/balances") else {
            isLoading = false
            return
        }

        do {
            var walletRequest = URLRequest(url: walletUrl)
            if let token = UserDefaults.standard.string(forKey: "sessionToken") {
                walletRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (walletData, _) = try await URLSession.shared.data(for: walletRequest)
            guard let walletJson = try? JSONDecoder().decode(WalletInfo.self, from: walletData),
                  let address = walletJson.walletAddress else {
                isLoading = false
                return
            }

            // Fetch positions from Polymarket Data API
            guard let url = URL(string: "https://data-api.polymarket.com/positions?user=\(address)") else {
                isLoading = false
                return
            }

            let (data, _) = try await URLSession.shared.data(from: url)
            let raw = try JSONDecoder().decode([RawPosition].self, from: data)

            positions = raw
                .filter { $0.title?.contains("Up or Down") == true }
                .sorted { ($0.endDate ?? $0.createdAt ?? "") > ($1.endDate ?? $1.createdAt ?? "") }
                .prefix(20)
                .map { pos in
                    let asset = pos.title?.hasPrefix("Bitcoin") == true ? "BTC" :
                                pos.title?.hasPrefix("Ethereum") == true ? "ETH" :
                                pos.title?.hasPrefix("XRP") == true ? "XRP" : "?"

                    let direction = pos.title?.contains("Up") == true ? "Up" : "Down"
                    let shares = pos.size ?? 0
                    let pnl = pos.cashPnl ?? 0
                    let pct = pos.percentPnl ?? 0
                    let cost = (pos.avgPrice ?? 0) * shares

                    return PositionInfo(
                        id: pos.id ?? UUID().uuidString,
                        assetName: asset,
                        direction: direction,
                        shares: shares,
                        cost: cost,
                        pnl: pnl,
                        pct: pct,
                        title: pos.title ?? ""
                    )
                }
        } catch {}
        isLoading = false
    }
}

private struct PositionInfo: Identifiable {
    let id: String
    let assetName: String
    let direction: String
    let shares: Double
    let cost: Double
    let pnl: Double
    let pct: Double
    let title: String

    var sharesText: String {
        String(format: "%.1f shares", shares)
    }

    var pnlText: String {
        if pnl >= 0 {
            return String(format: "+$%.2f", pnl)
        } else {
            return String(format: "-$%.2f", abs(pnl))
        }
    }

    var pctText: String {
        String(format: "%.1f%%", pct)
    }

    var pnlColor: Color {
        pnl >= 0 ? .green : .red
    }
}

private struct WalletInfo: Codable {
    let walletAddress: String?
}

private struct RawPosition: Codable {
    let id: String?
    let title: String?
    let size: Double?
    let avgPrice: Double?
    let curPrice: Double?
    let cashPnl: Double?
    let percentPnl: Double?
    let createdAt: String?
    let endDate: String?
}
