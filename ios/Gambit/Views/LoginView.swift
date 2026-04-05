import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager

    @State private var brandVisible  = false
    @State private var buttonVisible = false

    var body: some View {
        ZStack {
            GambitBackground()

            VStack(spacing: 0) {
                Spacer()

                // ── Brand block ──────────────────────────
                VStack(spacing: 20) {
                    GambitEyeLogo()
                        .frame(width: 124, height: 68)

                    Text("GAMBIT")
                        .font(.system(size: 52, weight: .black))
                        .foregroundStyle(.white)
                        .tracking(-2)

                    Text("\"The market fits on your wrist.\"")
                        .font(.system(size: 15, weight: .medium))
                        .italic()
                        .foregroundStyle(Color(hex: "#E8A0A8"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                }
                .opacity(brandVisible ? 1 : 0)
                .offset(y: brandVisible ? 0 : 22)
                .animation(.spring(response: 0.7, dampingFraction: 0.82).delay(0.15), value: brandVisible)

                Spacer()

                // ── CTA block ────────────────────────────
                VStack(spacing: 12) {
                    Button {
                        authManager.showAuth()
                    } label: {
                        Text("Get Started")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background {
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .overlay {
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: [.white.opacity(0.18), .clear],
                                                    startPoint: .top,
                                                    endPoint: .center
                                                )
                                            )
                                    }
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(
                                                LinearGradient(
                                                    colors: [
                                                        .white.opacity(0.38),
                                                        .white.opacity(0.08),
                                                        Color(hex: "#CC2244").opacity(0.2)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                ),
                                                lineWidth: 1
                                            )
                                    }
                            }
                            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    }
                    .buttonStyle(PressScaleStyle())

                    if authManager.isLoading {
                        ProgressView()
                            .tint(.white)
                    }

                    if let error = authManager.error {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    Text("Powered by Dynamic · No seed phrases")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.28))

                    Text("Built for ETHGlobal Cannes 2026")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.18))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 52)
                .opacity(buttonVisible ? 1 : 0)
                .offset(y: buttonVisible ? 0 : 28)
                .animation(.spring(response: 0.7, dampingFraction: 0.82).delay(0.32), value: buttonVisible)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            brandVisible  = true
            buttonVisible = true
        }
    }
}

// MARK: - Background

struct GambitBackground: View {
    @State private var pulse1 = false
    @State private var pulse2 = false
    @State private var gridOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0D").ignoresSafeArea()

            RadialGradient(
                colors: [Color(hex: "#CC2244").opacity(0.32), .clear],
                center: .init(x: 0.85, y: 0.08),
                startRadius: 0,
                endRadius: 340
            )
            .scaleEffect(pulse1 ? 1.18 : 1.0)
            .opacity(pulse1 ? 0.7 : 1.0)
            .ignoresSafeArea()

            RadialGradient(
                colors: [Color(hex: "#CC2244").opacity(0.14), .clear],
                center: .init(x: 0.12, y: 0.92),
                startRadius: 0,
                endRadius: 260
            )
            .scaleEffect(pulse2 ? 1.22 : 1.0)
            .opacity(pulse2 ? 0.6 : 1.0)
            .ignoresSafeArea()

            GeometryReader { _ in
                Canvas { ctx, size in
                    let spacing: CGFloat = 44
                    let color = Color(hex: "#CC2244").opacity(0.045)
                    let offset = gridOffset.truncatingRemainder(dividingBy: spacing)

                    var y = -spacing + offset
                    while y <= size.height + spacing {
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(p, with: .color(color), lineWidth: 1)
                        y += spacing
                    }
                    var x = -spacing + offset
                    while x <= size.width + spacing {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(p, with: .color(color), lineWidth: 1)
                        x += spacing
                    }
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { pulse1 = true }
            withAnimation(.easeInOut(duration: 7).delay(1.5).repeatForever(autoreverses: true)) { pulse2 = true }
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { gridOffset = 44 }
        }
    }
}

// MARK: - Eye Logo

struct GambitEyeLogo: View {
    var body: some View {
        Image("gambitLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

// MARK: - Helpers

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        self.init(
            red:   Double((int >> 16) & 0xFF) / 255,
            green: Double((int >>  8) & 0xFF) / 255,
            blue:  Double( int        & 0xFF) / 255
        )
    }
}
