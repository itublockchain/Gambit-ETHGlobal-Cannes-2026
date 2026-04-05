import SwiftUI
import DynamicSDKSwift

@main
struct GambitApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var delegationManager = DelegationManager()
    @State private var sdkReady = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Dynamic SDK WebView must be in the hierarchy with real size
                DynamicWebViewContainer()
                    .ignoresSafeArea()
                    .zIndex(sdkReady ? -1 : 1) // Behind content once ready
                    .opacity(sdkReady ? 0 : 1)
                    .onAppear {
                        // Give SDK time to load its webview
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            sdkReady = true
                        }
                    }

                if sdkReady {
                    // App content
                    Group {
                        if !authManager.isAuthenticated {
                            LoginView()
                        } else if !delegationManager.hasCheckedInitial {
                            // Checking delegation status...
                            ProgressView("Loading...")
                                .onAppear {
                                    delegationManager.checkOnLogin()
                                }
                        } else if !delegationManager.isDelegated {
                            OnboardingView()
                        } else {
                            DashboardView()
                        }
                    }
                    .transition(.opacity)
                }
            }
            .environmentObject(authManager)
            .environmentObject(delegationManager)
            .onAppear {
                authManager.onLogout = { [weak delegationManager] in
                    delegationManager?.reset()
                }
            }
        }
    }
}
