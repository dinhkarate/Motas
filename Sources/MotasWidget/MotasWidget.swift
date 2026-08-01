import WidgetKit
import SwiftUI
import MotasCore

struct MotasWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: StatusSnapshot
}

struct MotasWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MotasWidgetEntry {
        MotasWidgetEntry(date: Date(), snapshot: MockData.unknownSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (MotasWidgetEntry) -> Void) {
        completion(MotasWidgetEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MotasWidgetEntry>) -> Void) {
        let snapshot = loadSnapshot()
        let entry = MotasWidgetEntry(date: Date(), snapshot: snapshot)
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadSnapshot() -> StatusSnapshot {
        guard let store = try? SnapshotStore(
            appGroupIdentifier: MotasConfiguration.appGroupIdentifier
        ),
              let snapshot = try? store.load()
        else {
            return MockData.unknownSnapshot()
        }
        return snapshot
    }
}

struct MotasWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MotasWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Motas", systemImage: entry.snapshot.readiness.state.symbolName)
                    .font(.headline)
                Spacer()
                Text(entry.snapshot.capturedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(entry.snapshot.readiness.title)
                .font(.title3.weight(.semibold))
            Text(entry.snapshot.readiness.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(family == .systemLarge ? 3 : 2)

            Divider()

            ForEach(Array(rows.prefix(family == .systemLarge ? 5 : 3))) { row in
                HStack {
                    Circle()
                        .fill(row.color)
                        .frame(width: 7, height: 7)
                    Text(row.name)
                        .lineLimit(1)
                    Spacer()
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "motas://status"))
    }

    private var rows: [WidgetRow] {
        let providers = entry.snapshot.providers.map { provider in
            WidgetRow(
                id: "provider-\(provider.id)",
                name: provider.name,
                detail: provider.quotaWindows
                    .compactMap(\.remainingFraction)
                    .min()
                    .map { "\(Int(($0 * 100).rounded()))% left" }
                    ?? provider.health.rawValue.capitalized,
                color: provider.health.color
            )
        }
        let proxies = entry.snapshot.proxies.map { proxy in
            WidgetRow(
                id: "proxy-\(proxy.id)",
                name: proxy.name,
                detail: proxy.route?.activeTier.rawValue.capitalized
                    ?? proxy.health.rawValue.capitalized,
                color: proxy.health.color
            )
        }
        return providers + proxies
    }
}

private struct WidgetRow: Identifiable {
    let id: String
    let name: String
    let detail: String
    let color: Color
}

@main
struct MotasWidget: Widget {
    let kind = "MotasWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MotasWidgetProvider()) { entry in
            MotasWidgetView(entry: entry)
        }
        .configurationDisplayName("Motas AI Stack")
        .description("See AI quota and proxy health at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private extension ReadinessState {
    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .fallback: "arrow.triangle.branch"
        case .blocked: "xmark.octagon.fill"
        case .proxyDown: "network.slash"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

private extension OperationalHealth {
    var color: Color {
        switch self {
        case .healthy: .green
        case .degraded: .orange
        case .exhausted, .unreachable: .red
        case .unauthorized, .unsupported, .unknown: .secondary
        }
    }
}
