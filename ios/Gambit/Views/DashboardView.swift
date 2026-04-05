import SwiftUI
import DynamicSDKSwift

struct DashboardView: View {
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var watchSession = WatchSessionManager.shared
    @State private var walletAddress: String = ""
    @State private var usdcBalance: String = "0.00"
    @State private var usdceBalance: String = "0.00"
    @State private var totalBalance: String = "0.00"
    @State private var copiedWallet = false
    @AppStorage("defaultBetAmount") private var defaultBetAmount: Double = 5.0
    @State private var showSettings = false
    @State private var showWithdraw = false
    @State private var withdrawAddress = ""
    @State private var withdrawAmount = ""
    @State private var withdrawing = false
    @State private var withdrawResult: String?
    @State private var claimableCount = 0
    @State private var claimableValue = 0.0
    @State private var claiming = false
    @State private var claimResult: String?
    @State private var isTrading = false
    @State private var tradeResult: String?
    @State private var isApproving = false
    @AppStorage("hasApprovedUSDC") private var hasApproved = false
    @State private var recentTrades: [OrderRecord] = []
    @State private var allTrades: [OrderRecord] = []
    @State private var showAllTrades = false

    private let betAmounts: [Double] = [1, 2, 5, 10, 25]

    @State private var appeared = false
    @State private var polBalance: String = "0.00"
    @State private var balanceTask: Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        ZStack {
            HomeBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    // ── Top bar ──────────────────────────
                    HStack {
                        Button { showSettings = true } label: {
                            HStack(spacing: 8) {
                                GambitEyeLogo()
                                    .frame(width: 74, height: 40)
                                if NetworkMode.isArc {
                                    Text("ARC")
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color(hex: "#00EE77").opacity(0.3)))
                                }
                            }
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = walletAddress
                            copiedWallet = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedWallet = false }
                        } label: {
                            Text(copiedWallet ? "Copied!" : formatAddress(walletAddress))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(.white.opacity(0.06))
                                        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                                )
                        }
                        Button { authManager.logout() } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 56)
                    .padding(.bottom, 20)

                    // ── Balance card + Watch ─────────────
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("YOUR BALANCE")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.35))
                                .kerning(0.8)
                                .padding(.bottom, 14)

                            HStack {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(LinearGradient(
                                            colors: [Color(hex: "#2775CA"), Color(hex: "#1a5ba8")],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        ))
                                        .frame(width: 22, height: 22)
                                        .overlay(Text("$").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                                    Text("USDC.e")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(usdceBalance)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.white)
                                    Text("≈ $\(usdceBalance)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            }
                            .padding(.bottom, 10)

                            HStack {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(LinearGradient(
                                            colors: [Color(hex: "#8247E5"), Color(hex: "#5c2fa8")],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        ))
                                        .frame(width: 22, height: 22)
                                        .overlay(Text("P").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                                    Text("POL")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(polBalance)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.white)
                                    Text("≈ $\(String(format: "%.2f", (Double(polBalance) ?? 0) * 0.09))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            }
                        }
                        .padding(14)
                        .frame(width: 200)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(.white.opacity(0.035))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                                )
                        )

                        Spacer()

                        WatchIconAnimated()
                            .frame(width: 100)
                            .shadow(color: Color(hex: "#CC2244").opacity(0.28), radius: 20, y: 6)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                    // ── Claim banner ─────────────────────
                    if claimableCount > 0 {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hex: "#CC2244").opacity(0.2))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Image(systemName: "trophy")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color(hex: "#CC2244"))
                                )
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(claimableCount) winning positions")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(String(format: "+%.2f USDC.e ready to claim", claimableValue))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Spacer()
                            Button { claimAll() } label: {
                                if claiming {
                                    ProgressView().tint(.white)
                                } else {
                                    Text("Claim")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 8)
                                        .background(
                                            Capsule()
                                                .fill(Color(hex: "#CC2244").opacity(0.85))
                                                .shadow(color: Color(hex: "#CC2244").opacity(0.3), radius: 8, y: 4)
                                        )
                                }
                            }
                            .buttonStyle(PressScaleStyle())
                            .disabled(claiming)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Color(hex: "#CC2244").opacity(0.25), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                    }

                    // ── Action buttons ────────────────────
                    HStack(spacing: 10) {
                        ActionButton(label: "Deposit", icon: "arrow.down.circle", tint: Color(hex: "#CC2244")) {
                            UIPasteboard.general.string = walletAddress
                            copiedWallet = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedWallet = false }
                        }
                        ActionButton(label: "Withdraw", icon: "arrow.up.circle", tint: .white.opacity(0.55)) {
                            showWithdraw = true
                        }
                        ActionButton(
                            label: watchSession.isWatchReachable ? "Watch Connected" : "Watch Offline",
                            icon: "applewatch",
                            tint: watchSession.isWatchReachable ? Color(hex: "#00EE77") : .white.opacity(0.3)
                        ) {}
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)

                    // ── Arc Quick Trade (only in Arc mode) ──
                    if NetworkMode.isArc {
                        VStack(spacing: 10) {
                            HStack {
                                Text("ARC TRADE")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .kerning(0.6)
                                Spacer()
                                Text("Chainlink CRE Settlement")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(hex: "#00EE77").opacity(0.5))
                            }

                            ForEach(["btc", "eth", "xrp"], id: \.self) { asset in
                                HStack(spacing: 8) {
                                    Text(asset.uppercased())
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 40)

                                    Button { arcTrade(asset: asset, direction: "up") } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.up")
                                            Text("UP")
                                        }
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Capsule().fill(Color(hex: "#00EE77").opacity(0.2)).overlay(Capsule().strokeBorder(Color(hex: "#00EE77").opacity(0.3), lineWidth: 1)))
                                    }

                                    Button { arcTrade(asset: asset, direction: "down") } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.down")
                                            Text("DOWN")
                                        }
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Capsule().fill(Color(hex: "#CC2244").opacity(0.2)).overlay(Capsule().strokeBorder(Color(hex: "#CC2244").opacity(0.3), lineWidth: 1)))
                                    }
                                }
                            }

                            if let tradeResult = tradeResult {
                                Text(tradeResult)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(tradeResult.contains("confirmed") ? Color(hex: "#00EE77") : Color(hex: "#CC2244"))
                            }
                            if isTrading {
                                ProgressView().tint(.white)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }

                    // ── Recent trades ─────────────────────
                    VStack(spacing: 0) {
                        HStack {
                            Text("RECENT")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.4))
                                .kerning(0.6)
                            Spacer()
                            Button { showAllTrades = true } label: {
                                Text("See all")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(hex: "#CC2244").opacity(0.8))
                            }
                        }
                        .padding(.bottom, 12)

                        ForEach(recentTrades, id: \.id) { trade in
                            let asset = trade.marketSlug?.contains("btc") == true ? "BTC" : trade.marketSlug?.contains("eth") == true ? "ETH" : trade.marketSlug?.contains("xrp") == true ? "XRP" : "BTC"
                            let dir = trade.outcome ?? "UP"
                            let priceVal = Double(trade.price) ?? 0
                            let sizeVal = Double(trade.size) ?? 0
                            let amount = priceVal * sizeVal
                            let displayAmount = min(amount, 99.99) // cap display
                            let win = trade.status == "filled"
                            TradeRow(
                                pair: "\(asset) / USD",
                                direction: "\(dir == "UP" ? "↑ UP" : "↓ DOWN") · 5m",
                                amount: String(format: "%@%.2f USDC.e", win ? "+" : "−", displayAmount),
                                time: formatTradeTime(trade.createdAt),
                                win: win
                            )
                            if trade.id != recentTrades.last?.id {
                                Divider().background(.white.opacity(0.05))
                            }
                        }

                        if recentTrades.isEmpty {
                            Text("No trades yet — swipe on your Watch to start")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.3))
                                .padding(.vertical, 20)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                    Spacer(minLength: 40)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            appeared = true
            startBalanceStream()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                List {
                    Section("Default Bet Amount") {
                        let betAmounts: [Double] = [1, 2, 5, 10, 25]
                        HStack(spacing: 8) {
                            ForEach(betAmounts, id: \.self) { amount in
                                Button {
                                    defaultBetAmount = amount
                                    syncBetAmount(amount)
                                } label: {
                                    Text("$\(Int(amount))")
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(defaultBetAmount == amount ? Color.blue : Color.secondary.opacity(0.15))
                                        .foregroundStyle(defaultBetAmount == amount ? .white : .primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Section("Network") {
                        HStack {
                            Text(NetworkMode.isArc ? "Arc Testnet" : "Polymarket")
                                .font(.subheadline.bold())
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { NetworkMode.isArc },
                                set: { newValue in
                                    NetworkMode.isArc = newValue
                                    // Reset balances and restart stream
                                    walletAddress = ""
                                    usdcBalance = "0.00"
                                    usdceBalance = "0.00"
                                    polBalance = "0.00"
                                    totalBalance = "0.00"
                                    recentTrades = []
                                    startBalanceStream()
                                }
                            ))
                            .labelsHidden()
                        }
                        Text(NetworkMode.isArc
                            ? "Trading on Arc chain with Chainlink CRE settlement"
                            : "Trading on Polygon via Polymarket CLOB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button(role: .destructive) {
                            showSettings = false
                            authManager.logout()
                        } label: {
                            Text("Sign Out").frame(maxWidth: .infinity)
                        }
                    }
                }
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showSettings = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showWithdraw) { withdrawSheet }
        .sheet(isPresented: $showAllTrades) {
            NavigationStack {
                ZStack {
                    Color(hex: "#0A0A0D").ignoresSafeArea()
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(allTrades, id: \.id) { trade in
                                let asset = trade.marketSlug?.contains("btc") == true ? "BTC" : trade.marketSlug?.contains("eth") == true ? "ETH" : trade.marketSlug?.contains("xrp") == true ? "XRP" : "BTC"
                                let dir = trade.outcome ?? "UP"
                                let priceVal = Double(trade.price) ?? 0
                                let sizeVal = Double(trade.size) ?? 0
                                let pnl = sizeVal * priceVal
                                let win = trade.status == "filled"
                                TradeRow(
                                    pair: "\(asset) / USD",
                                    direction: "\(dir == "UP" ? "↑ UP" : "↓ DOWN") · 5m",
                                    amount: String(format: "%@%.2f USDC.e", win ? "+" : "−", pnl),
                                    time: formatTradeTime(trade.createdAt),
                                    win: win
                                )
                                Divider().background(.white.opacity(0.05))
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .navigationTitle("All Trades")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showAllTrades = false }.foregroundStyle(Color(hex: "#CC2244")) } }
            }
            .onAppear {
                Task {
                    do {
                        let response: OrdersResponse = try await APIClient.shared.request(endpoint: "/api/v1/orders", method: "GET")
                        allTrades = response.orders
                    } catch {}
                }
            }
        }
    }

    // MARK: - Withdraw Sheet

    private var withdrawSheet: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0A0A0D").ignoresSafeArea()
                VStack(spacing: 20) {
                    Text("Withdraw USDC.e")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    TextField("Recipient address (0x...)", text: $withdrawAddress)
                        .font(.system(.body, design: .monospaced))
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1))))
                        .foregroundStyle(.white)
                    TextField("Amount", text: $withdrawAmount)
                        .keyboardType(.decimalPad)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1))))
                        .foregroundStyle(.white)
                    Text("Available: $\(usdceBalance) USDC.e")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                    Button { performWithdraw() } label: {
                        if withdrawing {
                            ProgressView().tint(.white).frame(maxWidth: .infinity).padding()
                        } else {
                            Text("Withdraw")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Capsule().fill(Color(hex: "#CC2244")))
                        }
                    }
                    .disabled(withdrawing || withdrawAddress.isEmpty || withdrawAmount.isEmpty)
                    if let r = withdrawResult {
                        Text(r)
                            .font(.caption)
                            .foregroundStyle(r.contains("0x") ? Color(hex: "#00EE77") : Color(hex: "#CC2244"))
                    }
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Withdraw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showWithdraw = false }.foregroundStyle(Color(hex: "#CC2244"))
                }
            }
        }
    }

    // MARK: - Helpers

    private func arcTrade(asset: String, direction: String) {
        guard !isTrading else { return }
        isTrading = true
        tradeResult = nil

        Task {
            do {
                let result: OrderResult = try await APIClient.shared.requestURL(
                    url: "\(Environment.arcBaseURL)/api/v1/orders",
                    method: "POST",
                    body: ["asset": asset, "direction": direction, "amount": 1.0]
                )
                print("[Arc Trade] \(asset) \(direction): \(result.status)")
                tradeResult = "\(result.status) — \(asset.uppercased()) \(direction.uppercased())"
            } catch {
                print("[Arc Trade] Error: \(error)")
                tradeResult = "Error: \(error.localizedDescription)"
            }
            isTrading = false
        }
    }

    private func formatAddress(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    private func formatTradeTime(_ dateStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) else {
            return dateStr.prefix(10).description
        }
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(diff / 60) min ago" }
        if diff < 86400 { return "\(diff / 3600)h ago" }
        return "\(diff / 86400)d ago"
    }

    private func fetchRecentTrades() {
        Task {
            do {
                let response: OrdersResponse = try await APIClient.shared.request(
                    endpoint: "/api/v1/orders",
                    method: "GET"
                )
                recentTrades = Array(response.orders.prefix(5))
            } catch {}
        }
    }

    private func startBalanceStream() {
        // Cancel previous stream
        balanceTask?.cancel()

        fetchClaimable()
        fetchRecentTrades()

        // Arc mode: polling balance
        if NetworkMode.isArc {
            balanceTask = Task {
                while !Task.isCancelled {
                    if let url = URL(string: "\(Environment.arcBaseURL)/api/v1/wallet/balances") {
                        if let (data, _) = try? await URLSession.shared.data(from: url),
                           let parsed = try? JSONDecoder().decode(WalletBalances.self, from: data) {
                            await MainActor.run {
                                self.walletAddress = parsed.walletAddress ?? ""
                                self.usdcBalance = parsed.usdc
                                self.usdceBalance = parsed.usdce
                                self.polBalance = parsed.pol
                                self.totalBalance = parsed.total
                            }
                        }
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            return
        }

        guard let token = KeychainService.sessionToken,
              let url = URL(string: "\(Environment.apiBaseURL)/api/v1/wallet/balances/stream?token=\(token)") else { return }

        balanceTask = Task.detached {
            while !Task.isCancelled {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(from: url)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "),
                              let jsonData = line.dropFirst(6).data(using: .utf8),
                              let parsed = try? JSONDecoder().decode(WalletBalances.self, from: jsonData) else { continue }

                        await MainActor.run {
                            self.walletAddress = parsed.walletAddress ?? ""
                            self.usdcBalance = parsed.usdc
                            self.usdceBalance = parsed.usdce
                            self.polBalance = parsed.pol
                            self.totalBalance = parsed.total
                        }
                    }
                } catch {
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
                }
            }
        }
    }

    private func fetchClaimable() {
        Task {
            guard let url = URL(string: "\(Environment.apiBaseURL)/api/v1/orders/claimable") else { return }
            do {
                var request = URLRequest(url: url)
                if let token = KeychainService.sessionToken {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let (data, _) = try await URLSession.shared.data(for: request)
                if let response = try? JSONDecoder().decode(ClaimableResponse.self, from: data) {
                    claimableCount = response.claimable.count
                    claimableValue = response.claimable.reduce(0) { $0 + $1.value }
                }
            } catch {}
        }
    }

    private func claimAll() {
        claiming = true
        Task {
            do {
                guard let sdk = DynamicSDK.shared,
                      let wallet = sdk.wallets.userWallets.first else {
                    claimResult = "No wallet"
                    claiming = false
                    return
                }

                try? await sdk.wallets.switchNetwork(wallet: wallet, network: Network(137))

                let claimData: ClaimDataResponse = try await APIClient.shared.request(
                    endpoint: "/api/v1/orders/claim-data",
                    method: "POST",
                    body: [:],
                    authenticated: true
                )

                if claimData.txs.isEmpty {
                    claimResult = "Nothing to claim"
                    claiming = false
                    return
                }

                var totalClaimed = 0.0
                for tx in claimData.txs {
                    let ethTx = EthereumTransaction(from: wallet.address, to: tx.to, data: tx.data)
                    let hash = try await sdk.evm.sendTransaction(transaction: ethTx, wallet: wallet)
                    print("[Claim] \(tx.title): \(hash)")
                    totalClaimed += tx.value
                }

                claimResult = "Claimed $\(String(format: "%.2f", totalClaimed))"
                claimableCount = 0
                claimableValue = 0
            } catch {
                claimResult = "Claim failed: \(error.localizedDescription)"
            }
            claiming = false
        }
    }

    private func syncBetAmount(_ amount: Double) {
        Task {
            let _: [String: String]? = try? await APIClient.shared.request(
                endpoint: "/api/v1/auth/settings",
                method: "POST",
                body: ["defaultBetAmount": amount],
                authenticated: true
            )
        }
    }

    private func testTrade(asset: String, direction: String) {
        guard !isTrading else { return }
        isTrading = true
        tradeResult = nil

        Task {
            do {
                if !hasApproved {
                    print("[Trade] Auto-approving via permit...")
                    await approveUSDCAsync()
                }

                guard let sdk = DynamicSDK.shared,
                      let wallet = sdk.wallets.userWallets.first else {
                    tradeResult = "Error: No wallet"
                    isTrading = false
                    return
                }

                var lastError = ""
                for attempt in 1...3 {
                    let prepared: PreparedOrder = try await APIClient.shared.request(
                        endpoint: "/api/v1/orders/prepare",
                        method: "POST",
                        body: ["asset": asset, "direction": direction, "amount": 1.0]
                    )
                    print("[Trade] Attempt \(attempt): prepared \(prepared.orderId), price: \(prepared.price)")

                    let typedDataJson = buildOrderTypedDataJson(prepared: prepared)
                    let signature = try await sdk.wallets.signTypedData(wallet: wallet, typedDataJson: typedDataJson)

                    let result: OrderResult = try await APIClient.shared.request(
                        endpoint: "/api/v1/orders/submit-signed",
                        method: "POST",
                        body: ["orderId": prepared.orderId, "signature": signature]
                    )
                    print("[Trade] Attempt \(attempt) result: \(result.status)")

                    if result.status == "matched" || result.status == "200" || result.status == "201" {
                        tradeResult = "matched -- \(result.clobOrderId ?? "")"
                        isTrading = false
                        return
                    }
                    lastError = result.status
                    if attempt < 3 {
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                tradeResult = "No liquidity -- \(lastError)"
            } catch {
                print("[Trade] Error: \(error)")
                tradeResult = "Error: \(error.localizedDescription)"
            }
            isTrading = false
        }
    }

    private func approveUSDC() {
        isApproving = true
        Task {
            await approveUSDCAsync()
            isApproving = false
        }
    }

    private func approveUSDCAsync() async {
        do {
            guard let sdk = DynamicSDK.shared,
                  let wallet = sdk.wallets.userWallets.first else { return }

            let response: ApproveHashResponse = try await APIClient.shared.request(
                endpoint: "/api/v1/wallet/approve-hash",
                method: "POST",
                body: ["walletAddress": wallet.address]
            )

            if response.txs.isEmpty {
                print("[Approve] Already approved!")
                hasApproved = true
                return
            }

            for tx in response.txs {
                print("[Approve] Sending \(tx.token)...")
                let ethTx = EthereumTransaction(from: wallet.address, to: tx.to, data: tx.data)
                let txHash = try await sdk.evm.sendTransaction(transaction: ethTx, wallet: wallet)
                print("[Approve] \(tx.token) approved! TX: \(txHash)")
            }
            hasApproved = true
        } catch {
            print("[Approve] Error: \(error)")
        }
    }

    private func sellPosition(asset: String, direction: String) {
        guard !isTrading else { return }
        isTrading = true
        tradeResult = nil

        Task {
            do {
                guard let sdk = DynamicSDK.shared,
                      let wallet = sdk.wallets.userWallets.first else {
                    tradeResult = "Error: No wallet"
                    isTrading = false
                    return
                }

                let ctAddress = "0x4D97DCd97eC945f40cF65F87097ACe5EA0476045"
                let approveData1 = "0xa22cb4650000000000000000000000004bfb41d5b3570defd03c39a9a4d8de6bd8b8982e0000000000000000000000000000000000000000000000000000000000000001"
                let approveData2 = "0xa22cb465000000000000000000000000c5d563a36ae78145c45a50134d48a1215220f80a0000000000000000000000000000000000000000000000000000000000000001"
                for data in [approveData1, approveData2] {
                    let tx = EthereumTransaction(from: wallet.address, to: ctAddress, data: data)
                    _ = try? await sdk.evm.sendTransaction(transaction: tx, wallet: wallet)
                }

                let prepared: PreparedOrder = try await APIClient.shared.request(
                    endpoint: "/api/v1/orders/sell-prepare",
                    method: "POST",
                    body: ["asset": asset, "direction": direction]
                )
                print("[Sell] Prepared: \(prepared.orderId)")

                let typedDataJson = buildOrderTypedDataJson(prepared: prepared)
                let signature = try await sdk.wallets.signTypedData(wallet: wallet, typedDataJson: typedDataJson)

                let result: OrderResult = try await APIClient.shared.request(
                    endpoint: "/api/v1/orders/submit-signed",
                    method: "POST",
                    body: ["orderId": prepared.orderId, "signature": signature]
                )
                print("[Sell] Result: \(result.status)")
                tradeResult = "Sold -- \(result.status)"
            } catch {
                print("[Sell] Error: \(error)")
                tradeResult = "Error: \(error.localizedDescription)"
            }
            isTrading = false
        }
    }

    private func buildOrderTypedDataJson(prepared: PreparedOrder) -> String {
        """
        {
            "types": {
                "EIP712Domain": [
                    {"name": "name", "type": "string"},
                    {"name": "version", "type": "string"},
                    {"name": "chainId", "type": "uint256"},
                    {"name": "verifyingContract", "type": "address"}
                ],
                "Order": [
                    {"name": "salt", "type": "uint256"},
                    {"name": "maker", "type": "address"},
                    {"name": "signer", "type": "address"},
                    {"name": "taker", "type": "address"},
                    {"name": "tokenId", "type": "uint256"},
                    {"name": "makerAmount", "type": "uint256"},
                    {"name": "takerAmount", "type": "uint256"},
                    {"name": "expiration", "type": "uint256"},
                    {"name": "nonce", "type": "uint256"},
                    {"name": "feeRateBps", "type": "uint256"},
                    {"name": "side", "type": "uint8"},
                    {"name": "signatureType", "type": "uint8"}
                ]
            },
            "primaryType": "Order",
            "domain": {
                "name": "\(prepared.domain.name)",
                "version": "\(prepared.domain.version)",
                "chainId": \(prepared.domain.chainId),
                "verifyingContract": "\(prepared.domain.verifyingContract)"
            },
            "message": {
                "salt": "\(prepared.message.salt)",
                "maker": "\(prepared.message.maker)",
                "signer": "\(prepared.message.signer)",
                "taker": "\(prepared.message.taker)",
                "tokenId": "\(prepared.message.tokenId)",
                "makerAmount": "\(prepared.message.makerAmount)",
                "takerAmount": "\(prepared.message.takerAmount)",
                "expiration": "\(prepared.message.expiration)",
                "nonce": "\(prepared.message.nonce)",
                "feeRateBps": "\(prepared.message.feeRateBps)",
                "side": \(prepared.message.side),
                "signatureType": \(prepared.message.signatureType)
            }
        }
        """
    }

    private func performWithdraw() {
        guard let amount = Double(withdrawAmount) else {
            withdrawResult = "Invalid amount"
            return
        }
        withdrawing = true
        withdrawResult = nil

        Task {
            do {
                guard let sdk = DynamicSDK.shared,
                      let wallet = sdk.wallets.userWallets.first else {
                    withdrawResult = "No wallet"
                    withdrawing = false
                    return
                }

                let txData: WithdrawTxData = try await APIClient.shared.request(
                    endpoint: "/api/v1/wallet/withdraw-data",
                    method: "POST",
                    body: ["toAddress": withdrawAddress, "amount": amount, "token": "usdce"],
                    authenticated: true
                )

                try? await sdk.wallets.switchNetwork(wallet: wallet, network: Network(137))
                let ethTx = EthereumTransaction(from: wallet.address, to: txData.to, data: txData.data)
                let txHash = try await sdk.evm.sendTransaction(transaction: ethTx, wallet: wallet)
                print("[Withdraw] TX: \(txHash)")
                withdrawResult = txHash
                showWithdraw = false
            } catch {
                withdrawResult = "Error: \(error.localizedDescription)"
            }
            withdrawing = false
        }
    }
}

// MARK: - Private Model Structs

private struct ApproveHashResponse: Codable {
    let txs: [ApproveTxHash]
}

private struct ApproveTxHash: Codable {
    let token: String
    let to: String
    let data: String
    let hash: String
    let serializedUnsigned: String
    let nonce: Int
}

private struct WalletBalances: Codable {
    let usdc: String
    let usdce: String
    let pol: String
    let total: String
    let walletAddress: String?
}

private struct WithdrawResponse: Codable {
    let txHash: String
    let amount: String
}

private struct WithdrawTxData: Codable {
    let to: String
    let data: String
    let amount: String
    let token: String
}

private struct ClaimableResponse: Codable {
    let claimable: [ClaimablePosition]
}

private struct ClaimDataResponse: Codable {
    let txs: [ClaimTx]
    let totalValue: Double
}

private struct ClaimTx: Codable {
    let to: String
    let data: String
    let title: String
    let value: Double
    let conditionId: String
}

private struct ClaimablePosition: Codable {
    let title: String
    let shares: Double
    let value: Double
    let conditionId: String
}

private struct ClaimResult: Codable {
    let claimed: Double
    let txHashes: [String]
}

// MARK: - UI Components

struct HomeBackground: View {
    @State private var pulse = false
    @State private var gridOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0D").ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    RadialGradient(
                        colors: [Color(hex: "#CC2244").opacity(0.72), Color(hex: "#8C1228").opacity(0.38), .clear],
                        center: .init(x: 1.1, y: -0.05),
                        startRadius: 0,
                        endRadius: geo.size.width * 1.1
                    )
                    RadialGradient(
                        colors: [Color(hex: "#E62850").opacity(0.48), .clear],
                        center: .init(x: 0.95, y: 0.05),
                        startRadius: 0,
                        endRadius: geo.size.width * 0.45
                    )
                }
                .opacity(pulse ? 0.78 : 1.0)
                .ignoresSafeArea()
            }

            GeometryReader { _ in
                Canvas { ctx, size in
                    let spacing: CGFloat = 44
                    let color = Color(hex: "#CC2244").opacity(0.04)
                    let offset = gridOffset.truncatingRemainder(dividingBy: spacing)
                    var y = -spacing + offset
                    while y <= size.height + spacing {
                        var p = Path()
                        p.move(to: .init(x: 0, y: y))
                        p.addLine(to: .init(x: size.width, y: y))
                        ctx.stroke(p, with: .color(color), lineWidth: 1)
                        y += spacing
                    }
                    var x = -spacing + offset
                    while x <= size.width + spacing {
                        var p = Path()
                        p.move(to: .init(x: x, y: 0))
                        p.addLine(to: .init(x: x, y: size.height))
                        ctx.stroke(p, with: .color(color), lineWidth: 1)
                        x += spacing
                    }
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { pulse = true }
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { gridOffset = 44 }
        }
    }
}

struct WatchIconAnimated: View {
    @State private var showLeft = true

    var body: some View {
        WatchIcon()
            .overlay(
                VStack(spacing: 4) {
                    Text("SWIPE")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.4))
                        .kerning(1.5)
                    Image(systemName: showLeft ? "arrow.left" : "arrow.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(showLeft ? Color(hex: "#CC2244") : Color(hex: "#00EE77"))
                        .contentTransition(.symbolEffect(.replace))
                }
                .offset(y: 6)
            )
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { _ in
                    withAnimation { showLeft.toggle() }
                }
            }
    }
}

struct WatchIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = w * (140 / 110.0)
            Canvas { ctx, size in
                let bw: CGFloat = w * 0.36, bx = (w - bw) / 2
                let bandFill = GraphicsContext.Shading.color(.white.opacity(0.06))
                let bandStroke = GraphicsContext.Shading.color(.white.opacity(0.10))
                let bodyFill = GraphicsContext.Shading.color(.white.opacity(0.05))
                let bodyStroke = GraphicsContext.Shading.color(.white.opacity(0.12))
                let screenFill = GraphicsContext.Shading.color(Color(hex: "#0A0A0D").opacity(0.9))

                let bt = Path(roundedRect: CGRect(x: bx, y: 0, width: bw, height: h * 0.20), cornerRadius: 6)
                ctx.fill(bt, with: bandFill)
                ctx.stroke(bt, with: bandStroke, lineWidth: 1)

                let body_ = Path(roundedRect: CGRect(x: w * 0.09, y: h * 0.17, width: w * 0.82, height: h * 0.66), cornerRadius: w * 0.20)
                ctx.fill(body_, with: bodyFill)
                ctx.stroke(body_, with: bodyStroke, lineWidth: 1.5)

                let screen = Path(roundedRect: CGRect(x: w * 0.16, y: h * 0.23, width: w * 0.68, height: h * 0.54), cornerRadius: w * 0.14)
                ctx.fill(screen, with: screenFill)

                let crown = Path(roundedRect: CGRect(x: w * 0.92, y: h * 0.37, width: w * 0.055, height: h * 0.13), cornerRadius: 3)
                ctx.fill(crown, with: .color(.white.opacity(0.15)))

                // SWIPE + arrow drawn by WatchIconAnimated overlay

                let bb = Path(roundedRect: CGRect(x: bx, y: h * 0.80, width: bw, height: h * 0.20), cornerRadius: 6)
                ctx.fill(bb, with: bandFill)
                ctx.stroke(bb, with: bandStroke, lineWidth: 1)
            }
            .frame(width: w, height: h)
        }
        .aspectRatio(110 / 140, contentMode: .fit)
    }
}

struct TradeRow: View {
    let pair: String
    let direction: String
    let amount: String
    let time: String
    let win: Bool

    var body: some View {
        HStack {
            HStack(spacing: 10) {
                Circle()
                    .fill(win ? Color(hex: "#00EE77") : Color(hex: "#CC2244"))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pair)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(direction)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amount)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(win ? Color(hex: "#00EE77") : Color(hex: "#CC2244"))
                Text(time)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.vertical, 11)
    }
}

struct ActionButton: View {
    let label: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}
