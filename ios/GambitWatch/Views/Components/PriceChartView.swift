import SwiftUI
import Charts

struct PriceChartView: View {
    let priceHistory: [PriceHistoryPoint]
    let priceChange: Double
    var chartNow: Date = .now

    private var color: Color {
        priceChange >= 0 ? .green : .red
    }

    private var timeWindow: ClosedRange<Date> {
        let start = chartNow.addingTimeInterval(-60)
        return start...chartNow
    }

    private var visiblePoints: [PriceHistoryPoint] {
        let cutoff = chartNow.timeIntervalSince1970 - 60
        let raw = priceHistory.filter { $0.timestamp >= cutoff }
        // EMA smoothing (alpha=0.3) for cleaner chart
        guard raw.count > 1 else { return raw }
        var smoothed = [raw[0]]
        let alpha = 0.3
        for i in 1..<raw.count {
            let ema = alpha * raw[i].price + (1 - alpha) * smoothed[i-1].price
            smoothed.append(PriceHistoryPoint(timestamp: raw[i].timestamp, price: ema))
        }
        return smoothed
    }

    private var priceRange: ClosedRange<Double> {
        let prices = visiblePoints.map(\.price)
        guard let minPrice = prices.min(), let maxPrice = prices.max() else {
            return 0...1
        }
        var spread = maxPrice - minPrice
        let minSpread = maxPrice * 0.0003
        if spread < minSpread { spread = minSpread }

        let mid = (minPrice + maxPrice) / 2
        return (mid - spread * 1.2)...(mid + spread * 1.2)
    }

    var body: some View {
        Chart(visiblePoints) { point in
            LineMark(
                x: .value("Time", Date(timeIntervalSince1970: point.timestamp)),
                y: .value("Price", point.price)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)

            AreaMark(
                x: .value("Time", Date(timeIntervalSince1970: point.timestamp)),
                yStart: .value("Min", priceRange.lowerBound),
                yEnd: .value("Price", point.price)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [color.opacity(0.2), color.opacity(0.05), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: priceRange)
        .chartXScale(domain: timeWindow)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .animation(.easeInOut(duration: 0.4), value: chartNow)
    }
}
