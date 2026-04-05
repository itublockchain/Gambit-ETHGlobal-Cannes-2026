import Foundation

/// Manages wallet setup status (CLOB auth).
/// No longer uses MPC delegation — embedded wallet signs client-side.
@MainActor
class DelegationManager: ObservableObject {
    @Published var isDelegated = false
    @Published var hasCheckedInitial = false
    @Published var walletAddress: String?
    @Published var isChecking = false

    /// One-shot check on login — determines if CLOB credentials exist.
    func checkOnLogin() {
        guard KeychainService.sessionToken != nil else {
            print("[DelegationManager] checkOnLogin — no session token, skipping")
            hasCheckedInitial = true
            return
        }
        isChecking = true
        print("[DelegationManager] checkOnLogin — checking setup status...")
        Task {
            do {
                let status: DelegationStatus = try await APIClient.shared.request(
                    endpoint: "/api/v1/auth/delegation-status",
                    method: "GET"
                )
                print("[DelegationManager] checkOnLogin — delegated: \(status.delegated), wallet: \(status.walletAddress ?? "nil")")
                isDelegated = status.delegated
                walletAddress = status.walletAddress
            } catch {
                print("[DelegationManager] checkOnLogin — ERROR: \(error)")
                isDelegated = false
            }
            hasCheckedInitial = true
            isChecking = false
        }
    }

    func reset() {
        isDelegated = false
        hasCheckedInitial = false
        walletAddress = nil
    }
}

struct DelegationStatus: Codable {
    let delegated: Bool
    let walletAddress: String?
    let usdcBalance: String?
}
