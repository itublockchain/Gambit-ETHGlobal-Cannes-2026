import WidgetKit
import SwiftUI

struct PriceEntry: TimelineEntry {
    let date: Date
    let btcPrice: String
    let btcChange: Double
}

struct PriceComplicationProvider: TimelineProvider {
    private let apiBaseURL: String = {
        #if DEBUG
        return "https://89-167-35-173.nip.io"
        #else
        return "https://api.gambit.app"
        #endif
    }()

    func placeholder(in context: Context) -> PriceEntry {
        PriceEntry(date: .now, btcPrice: "$0.50", btcChange: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (PriceEntry) -> Void) {
        let entry = PriceEntry(date: .now, btcPrice: "$0.52", btcChange: 2.0)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PriceEntry>) -> Void) {
        guard let url = URL(string: "\(apiBaseURL)/api/v1/markets/active") else {
            let entry = PriceEntry(date: .now, btcPrice: "—", btcChange: 0)
            let timeline = Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300)))
            completion(timeline)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let response = try? JSONDecoder().decode(WidgetMarketsResponse.self, from: data),
                  let btcMarket = response.markets.first(where: { $0.asset == "btc" }) else {
                let entry = PriceEntry(date: .now, btcPrice: "—", btcChange: 0)
                let timeline = Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300)))
                completion(timeline)
                return
            }

            let entry = PriceEntry(
                date: .now,
                btcPrice: "$\(btcMarket.upPrice)",
                btcChange: 0
            )

            let nextUpdate = Date().addingTimeInterval(5 * 60)
            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            completion(timeline)
        }.resume()
    }
}

// Lightweight models for widget extension (avoids importing Shared)
private struct WidgetMarketsResponse: Codable {
    let markets: [WidgetMarket]
}

private struct WidgetMarket: Codable {
    let asset: String
    let upPrice: String
    let downPrice: String
    let question: String
}

struct PriceComplicationView: View {
    let entry: PriceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BTC")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(entry.btcPrice)
                .font(.caption)
                .monospacedDigit()
                .bold()
        }
    }
}

@main
struct GambitComplication: Widget {
    let kind = "GambitPriceComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PriceComplicationProvider()) { entry in
            PriceComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("BTC Price")
        .description("Shows current BTC 5-min market price")
        .supportedFamilies([.accessoryInline, .accessoryCorner, .accessoryCircular, .accessoryRectangular])
    }
}
