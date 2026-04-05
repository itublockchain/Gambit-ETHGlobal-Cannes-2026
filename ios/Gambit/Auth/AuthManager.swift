import Foundation
import Combine
import DynamicSDKSwift

/// Manages Dynamic SDK authentication and session state.
@MainActor
class AuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var userName: String?
    @Published var error: String?

    private var cancellables = Set<AnyCancellable>()
    private var sdk: DynamicSDK?

    init() {
        // Clear stale keychain on fresh install (UserDefaults resets on app delete, keychain doesn't)
        let launchKey = "appInstallId"
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let currentId = "\(bundleVersion)-\(Bundle.main.bundleIdentifier ?? "")"
        if UserDefaults.standard.string(forKey: launchKey) != currentId {
            KeychainService.sessionToken = nil
            KeychainService.userId = nil
            UserDefaults.standard.set(currentId, forKey: launchKey)
        }

        // Initialize Dynamic SDK first
        setupDynamicSDK()

        // Validate existing session against backend
        if KeychainService.sessionToken != nil {
            isAuthenticated = true
            validateSession()
        }
    }

    /// Check if existing session token is still valid.
    private func validateSession() {
        Task {
            do {
                let _: DelegationStatus = try await APIClient.shared.request(
                    endpoint: "/api/v1/auth/delegation-status",
                    method: "GET"
                )
                print("[AuthManager] Session valid")
            } catch {
                print("[AuthManager] Session invalid, clearing: \(error)")
                KeychainService.sessionToken = nil
                KeychainService.userId = nil
                isAuthenticated = false
                onLogout?()
            }
        }
    }

    private func setupDynamicSDK() {
        // Custom Polygon network with working RPC
        let polygonNetwork = GenericNetwork(
            blockExplorerUrls: ["https://polygonscan.com"],
            chainId: 137,
            iconUrls: [],
            name: "Polygon",
            nativeCurrency: NativeCurrency(decimals: 18, name: "POL", symbol: "POL"),
            networkId: 137,
            rpcUrls: ["https://polygon-bor-rpc.publicnode.com"]
        )

        let props = ClientProps(
            environmentId: Environment.dynamicEnvironmentId,
            appName: "Gambit",
            evmNetworks: [polygonNetwork]
        )
        sdk = DynamicSDK.initialize(props: props)

        // Listen for JWT token changes — fires when user completes auth
        sdk?.auth.tokenChanges
            .receive(on: DispatchQueue.main)
            .compactMap { $0 } // Only non-nil tokens
            .sink { [weak self] token in
                self?.handleToken(token)
            }
            .store(in: &cancellables)
    }

    /// Show Dynamic auth modal (Email, Google, etc.)
    func showAuth() {
        sdk?.ui.showAuth()
    }

    /// Handle Dynamic JWT token after successful auth.
    private func handleToken(_ dynamicJwt: String) {
        guard !isAuthenticated else { return } // Avoid re-processing

        isLoading = true
        error = nil

        Task {
            do {
                let response: AuthResponse = try await APIClient.shared.request(
                    endpoint: "/api/v1/auth/verify",
                    method: "POST",
                    body: ["dynamicJwt": dynamicJwt],
                    authenticated: false
                )

                KeychainService.sessionToken = response.sessionToken
                KeychainService.userId = response.userId

                // Send session token to Watch for HTTP fallback auth
                WatchSessionManager.shared.sendSessionTokenToWatch()

                isAuthenticated = true
                isLoading = false
            } catch {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    var onLogout: (() -> Void)?

    func logout() {
        Task { try? await sdk?.auth.logout() }
        KeychainService.sessionToken = nil
        KeychainService.userId = nil
        isAuthenticated = false
        userName = nil
        onLogout?()
    }
}

struct AuthResponse: Codable {
    let sessionToken: String
    let userId: String
    let isNewUser: Bool
}
