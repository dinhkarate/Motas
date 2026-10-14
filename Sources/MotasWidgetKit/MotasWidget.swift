import MotasCore
import MotasDesign
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

    private var measured: [PoolSummary] {
        entry.pools.filter { $0.reserve != nil }.sorted { $0.reserve! < $1.reserve! }
    }

    public var body: some View {
        Group {
            if let headline = measured.first {
                if family == .systemSmall {
                    VStack(alignment: .leading, spacing: 0) {
                        HeadlineBlock(pool: headline, threshold: entry.threshold, numberSize: 34)
                        Spacer(minLength: 6)
                        let others = measured.dropFirst().prefix(2)
                        if !others.isEmpty {
                            HStack(spacing: 10) {
                                ForEach(Array(others)) { pool in
                                    HStack(spacing: 4) {
                                        ProviderBadge(pool.provider, size: 12)
                                        Text(Design.percent(pool.reserve!)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                            .foregroundStyle(Design.text(pool.reserve, threshold: entry.threshold))
                                    }
                                }
                            }
                            .padding(.bottom, 4)
                        }
                        footer
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 0) {
                            HeadlineBlock(pool: headline, threshold: entry.threshold, numberSize: 38)
                            Spacer(minLength: 4)
                            footer
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(measured.dropFirst().prefix(3))) { PoolRow(pool: $0, threshold: entry.threshold) }
                            ForEach(entry.pools.filter { $0.reserve == nil }.prefix(max(0, 4 - measured.count))) { pool in
                                HStack(spacing: 6) {
                                    ProviderBadge(pool.provider, size: 14)
                                    Text(pool.provider.displayName).font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text("—").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.needle").foregroundStyle(.secondary)
                        Text("Motas").font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                    Text(entry.pools.isEmpty ? "No quota yet" : "No figures reported")
                        .font(.system(size: 15, weight: .semibold))
                    footer
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.locale, Design.locale)
    }

    @ViewBuilder private var footer: some View {
        if let problem = entry.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).lineLimit(1)
        } else if let fetchedAt = entry.fetchedAt {
            let stale = entry.date.timeIntervalSince(fetchedAt) > 30 * 60
            Text("Updated \(Design.relative(fetchedAt, now: entry.date))")
                .font(.system(size: 10)).foregroundStyle(stale ? Color.orange : Color.secondary).lineLimit(1)
        }
    }
}

/// Badge + name, big remaining %, usable/reset line, 9pt bar.
struct HeadlineBlock: View {
    let pool: PoolSummary
    let threshold: Double
    let numberSize: CGFloat

    var body: some View {
        let reserve = pool.reserve ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProviderBadge(pool.provider, size: 18)
                Text(pool.provider.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            Text(Design.percent(reserve))
                .font(.system(size: numberSize, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Design.text(reserve, threshold: threshold))
                .padding(.top, 2)
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            CapsuleBar(reserve, color: Design.fill(reserve, provider: pool.provider, threshold: threshold), height: 9)
                .padding(.top, 2)
        }
    }

    private var detail: String {
        var parts = ["\(pool.measuredCount - pool.exhaustedCount)/\(pool.measuredCount) usable"]
        if let reset = pool.nextReset { parts.append("reset \(Design.relative(reset))") }
        return parts.joined(separator: " · ")
    }
}

struct PoolRow: View {
    let pool: PoolSummary
    let threshold: Double

    var body: some View {
        let reserve = pool.reserve ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProviderBadge(pool.provider, size: 14)
                Text(pool.provider.displayName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                Text(Design.percent(reserve)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Design.text(reserve, threshold: threshold))
            }
            CapsuleBar(reserve, color: Design.fill(reserve, provider: pool.provider, threshold: threshold), height: 7)
        }
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
