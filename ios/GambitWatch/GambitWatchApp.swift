import SwiftUI

@main
struct GambitWatchApp: App {
    @StateObject private var connector = PhoneConnector.shared
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchMainView()
                .environmentObject(connector)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                connector.updateConnectionMethod()
            case .inactive, .background:
                // Background: stop polling, rely on complication
                break
            @unknown default:
                break
            }
        }
    }
}
