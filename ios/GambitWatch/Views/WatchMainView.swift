import SwiftUI

struct WatchMainView: View {
    @StateObject private var connector = PhoneConnector.shared
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            MarketView(asset: .btc)
                .tag(0)

            MarketView(asset: .eth)
                .tag(1)

            MarketView(asset: .xrp)
                .tag(2)

            BetHistoryView()
                .tag(3)
        }
        .tabViewStyle(.verticalPage)
        .onAppear {
            connector.updateConnectionMethod()
        }
    }
}
