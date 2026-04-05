import SwiftUI

struct PlacingOrderView: View {
    let asset: CryptoAsset
    let direction: BetDirection
    let amount: Double

    @State private var dots = ""
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // Pulsing icon
            Circle()
                .fill(direction == .up ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                .frame(width: 60, height: 60)
                .overlay {
                    Image(systemName: direction == .up ? "arrow.up" : "arrow.down")
                        .font(.title2).bold()
                        .foregroundStyle(direction == .up ? .green : .red)
                }
                .scaleEffect(pulse ? 1.1 : 0.9)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)

            Text("Placing Order\(dots)")
                .font(.headline)

            HStack(spacing: 4) {
                Text(asset.symbol)
                    .font(.caption).bold()
                Text(direction.label)
                    .font(.caption2).bold()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(direction == .up ? Color.green.opacity(0.3) : Color.red.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("$\(Int(amount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.trailing, 10)
        .onAppear {
            pulse = true
            animateDots()
        }
    }

    private func animateDots() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if dots.count >= 3 {
                dots = ""
            } else {
                dots += "."
            }
        }
    }
}
