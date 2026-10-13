import MotasCore
import SwiftUI
import WidgetKit

/// Widget content. The extension target only adds `@main` around
/// `MotasWidgetBundle`; everything else lives here so it builds with SwiftPM.
public struct PoolEntry: TimelineEntry {
    public let date: Date
    public let pools: [PoolSummary]
    public let fetchedAt: Date?
    public let threshold: Double
    public let problem: String?

    public init(date: Date, pools: [PoolSummary], fetchedAt: Date?, threshold: Double, problem: String?) {
        self.date = date
        self.pools = pools
        self.fetchedAt = fetchedAt
        self.threshold = threshold
        self.problem = problem
    }
}

public struct PoolProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> PoolEntry {
        PoolEntry(date: .now, pools: [], fetchedAt: nil, threshold: 0.2, problem: nil)
    }

    public func getSnapshot(in context: Context, completion: @escaping (PoolEntry) -> Void) {
        completion(Self.entry())
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<PoolEntry>) -> Void) {
        completion(Timeline(entries: [Self.entry()], policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    /// Reads the app's last real snapshot. Never fabricates: no file → empty.
    static func entry() -> PoolEntry {
        guard let shared = SharedSnapshot.load() else {
            return PoolEntry(date: .now, pools: [], fetchedAt: nil, threshold: 0.2, problem: "Open Motas to add a proxy")
        }
        let down = shared.snapshot.proxies.filter { !$0.health.isOK }.count
        return PoolEntry(date: .now, pools: Pool.summarize(shared.snapshot), fetchedAt: shared.snapshot.fetchedAt,
                         threshold: shared.threshold, problem: down > 0 ? "\(down) proxy unavailable" : nil)
    }
}

public struct PoolWidgetView: View {
    let entry: PoolEntry
    let familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    /// `family` overrides the environment (previews / offscreen rendering).
    public init(entry: PoolEntry, family: WidgetFamily? = nil) {
        self.entry = entry
        familyOverride = family
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let headline = Pool.headline(entry.pools), let reserve = headline.reserve {
                Text(headline.provider.displayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(percent(reserve)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(tint(reserve))
                Text("\(headline.measuredCount - headline.exhaustedCount)/\(headline.measuredCount) usable")
                    .font(.caption2).foregroundStyle(.secondary)
                if let reset = headline.nextReset {
                    Text("reset \(relative(reset))").font(.caption2).foregroundStyle(.secondary)
                }
                if family != .systemSmall {
                    ForEach(entry.pools.filter { $0.provider != headline.provider && $0.reserve != nil }.prefix(3)) { pool in
                        HStack {
                            Text(pool.provider.displayName).font(.caption)
                            Spacer()
                            Text(percent(pool.reserve!)).font(.caption.weight(.medium)).monospacedDigit()
                                .foregroundStyle(tint(pool.reserve!))
                        }
                    }
                }
            } else {
                Text("Motas").font(.headline)
                Text("No quota figures yet").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let problem = entry.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
            } else if let fetchedAt = entry.fetchedAt {
                Text("Updated \(relative(fetchedAt))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    /// English, like the rest of Motas (`Text(_:style:)` ignores the locale).
    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: entry.date)
    }

    private func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    private func tint(_ f: Double) -> Color {
        f < Pool.exhaustedThreshold ? .red : (f < entry.threshold ? .orange : .green)
    }
}

public struct MotasPoolWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.motas.pool", provider: PoolProvider()) { PoolWidgetView(entry: $0) }
            .configurationDisplayName("Quota pool")
            .description("Lowest pool reserve across your proxies.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
