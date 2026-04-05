import SwiftUI
import Combine
import DynamicSDKSwift

struct OnboardingView: View {
    @EnvironmentObject var delegationManager: DelegationManager
    @EnvironmentObject var authManager: AuthManager
    @State private var cancellables = Set<AnyCancellable>()
    @State private var setupError: String?
    @State private var isSettingUp = false
    @State private var walletReady = false
    @State private var currentWallet: BaseWallet?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "applewatch")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Wallet Setup")
                .font(.largeTitle).bold()

            Text("Sign a message to activate trading.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            if isSettingUp {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Setting up trading credentials...")
                        .foregroundStyle(.secondary)
                }
            } else if !walletReady {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Creating wallet...")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    setupWallet()
                } label: {
                    Text("Setup Wallet")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 24)
            }

            if let error = setupError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .padding()
        .onAppear { startListening() }
    }

    private func startListening() {
        guard let sdk = DynamicSDK.shared else { return }

        // Dismiss any delegation prompts
        Task {
            try? await sdk.wallets.waas.delegation.dismissDelegationPrompt()
            try? await sdk.wallets.waas.delegation.clearDelegationSessionState()
        }

        // Check if wallet already available
        if let wallet = sdk.wallets.userWallets.first {
            print("[OnboardingView] Wallet already available: \(wallet.address.prefix(10))...")
            currentWallet = wallet
            walletReady = true
            return
        }

        // Listen for wallet creation
        sdk.wallets.userWalletsChanges
            .receive(on: DispatchQueue.main)
            .compactMap { $0.first }
            .prefix(1)
            .sink { wallet in
                print("[OnboardingView] Wallet created: \(wallet.address.prefix(10))...")
                self.currentWallet = wallet
                self.walletReady = true
            }
            .store(in: &cancellables)
    }

    private func setupWallet() {
        guard let sdk = DynamicSDK.shared else {
            setupError = "SDK not initialized"
            return
        }

        isSettingUp = true
        setupError = nil

        Task {
            do {
                // 1. Get wallet from state
                guard let wallet = currentWallet else {
                    print("[OnboardingView] No wallet found")
                    await MainActor.run {
                        setupError = "No wallet found. Please log in again."
                        isSettingUp = false
                    }
                    return
                }

                let walletAddress = wallet.address
                print("[OnboardingView] Wallet address: \(walletAddress)")

                // 2. Get ClobAuth EIP-712 data from backend
                let authData: ClobAuthData = try await APIClient.shared.request(
                    endpoint: "/api/v1/auth/clob-auth-data",
                    method: "POST",
                    body: ["walletAddress": walletAddress]
                )
                print("[OnboardingView] Got ClobAuth data, timestamp: \(authData.timestamp)")

                // 3. Build EIP-712 JSON for Dynamic SDK
                let typedDataJson = buildClobAuthTypedDataJson(authData: authData)
                print("[OnboardingView] Signing ClobAuth typed data...")

                // 4. Sign with Dynamic embedded wallet
                let signature = try await sdk.wallets.signTypedData(
                    wallet: wallet,
                    typedDataJson: typedDataJson
                )
                print("[OnboardingView] Signature obtained: \(signature.prefix(20))...")

                // 5. Submit signature to backend to derive L2 API keys
                let _: SubmitClobAuthResponse = try await APIClient.shared.request(
                    endpoint: "/api/v1/auth/submit-clob-auth",
                    method: "POST",
                    body: [
                        "walletAddress": walletAddress,
                        "signature": signature,
                        "timestamp": authData.timestamp,
                    ]
                )
                print("[OnboardingView] CLOB auth submitted successfully!")

                // 6. Update delegation manager state
                await MainActor.run {
                    delegationManager.isDelegated = true
                    delegationManager.walletAddress = walletAddress
                    delegationManager.hasCheckedInitial = true
                    isSettingUp = false
                }
            } catch {
                print("[OnboardingView] Setup error: \(error)")
                let errMsg = "\(error)"
                if errMsg.contains("user_not_logged_in") || errMsg.contains("No wallet found") {
                    await MainActor.run { authManager.logout() }
                } else {
                    await MainActor.run {
                        setupError = "Setup failed: \(error.localizedDescription)"
                        isSettingUp = false
                    }
                }
            }
        }
    }

    private func buildClobAuthTypedDataJson(authData: ClobAuthData) -> String {
        """
        {
            "types": {
                "EIP712Domain": [
                    {"name": "name", "type": "string"},
                    {"name": "version", "type": "string"},
                    {"name": "chainId", "type": "uint256"}
                ],
                "ClobAuth": [
                    {"name": "address", "type": "address"},
                    {"name": "timestamp", "type": "string"},
                    {"name": "nonce", "type": "uint256"},
                    {"name": "message", "type": "string"}
                ]
            },
            "primaryType": "ClobAuth",
            "domain": {
                "name": "\(authData.domain.name)",
                "version": "\(authData.domain.version)",
                "chainId": \(authData.domain.chainId)
            },
            "message": {
                "address": "\(authData.message.address)",
                "timestamp": "\(authData.message.timestamp)",
                "nonce": \(authData.message.nonce),
                "message": "\(authData.message.message)"
            }
        }
        """
    }
}

// MARK: - Response Models

struct ClobAuthData: Codable {
    let domain: ClobAuthDomain
    let types: [String: [ClobAuthField]]
    let message: ClobAuthMessage
    let timestamp: String
}

struct ClobAuthDomain: Codable {
    let name: String
    let version: String
    let chainId: Int
}

struct ClobAuthField: Codable {
    let name: String
    let type: String
}

struct ClobAuthMessage: Codable {
    let address: String
    let timestamp: String
    let nonce: Int
    let message: String
}

struct SubmitClobAuthResponse: Codable {
    let success: Bool
    let walletAddress: String
}

