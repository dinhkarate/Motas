import MotasCore
import SwiftUI

enum Format {
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// The UI is English; dates follow it rather than the system locale so a
    /// line never mixes languages.
    static let locale = Locale(identifier: "en_US")

    static func relative(_ date: Date, now: Date = .now) -> String {
        if abs(date.timeIntervalSince(now)) < 45 { return date > now ? "in a moment" : "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func tint(_ fraction: Double?, threshold: Double) -> Color {
        guard let fraction else { return .secondary }
        if fraction < Pool.exhaustedThreshold { return .red }
        if fraction < threshold { return .orange }
        return .green
    }
}

/// Menu bar label: provider + pool reserve of the lowest pool.
public struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        if let pool = model.headline, let reserve = pool.reserve {
            let low = reserve < model.settings.lowReserveThreshold
            let down = model.snapshot.proxies.contains { !$0.health.isOK }
            HStack(spacing: 3) {
                Image(systemName: low || down ? "exclamationmark.triangle" : "gauge.with.needle")
                Text("\(pool.provider.displayName) \(Format.percent(reserve))").monospacedDigit()
            }
        } else if model.snapshot.proxies.contains(where: { !$0.health.isOK }) {
            Image(systemName: "exclamationmark.triangle")
        } else {
            Image(systemName: "gauge.with.needle")
        }
    }
}

public struct PanelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.appError {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.needsKeychainAccess {
                HStack {
                    Label("Motas needs Keychain access to read proxy credentials.", systemImage: "key.fill")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Allow…") { Task { await model.approveKeychainAccess() } }
                        .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
            }
            if model.isConfigured {
                poolsRow
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.snapshot.proxies) { ProxySection(proxy: $0, threshold: model.settings.lowReserveThreshold) }
                        if model.snapshot.proxies.isEmpty {
                            Text(model.isRefreshing ? "Reading proxies…" : "No data yet.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 460)
            } else {
                emptyState
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 380)
        .environment(\.locale, Format.locale)
    }

    private var poolsRow: some View {
        let measured = model.pools
        return Group {
            if measured.isEmpty {
                Text("No quota figures yet").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                    ForEach(measured) { PoolCard(pool: $0, threshold: model.settings.lowReserveThreshold) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No proxy configured").font(.headline)
            Text("Add a CLIProxyAPI or 9Router server to see the quota of every account it holds.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add a proxy…") { open("settings") }
                .buttonStyle(.borderedProminent)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.snapshot.fetchedAt > .distantPast {
                Text("Updated \(Format.relative(model.snapshot.fetchedAt))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                IconButton("arrow.clockwise", help: "Refresh now") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(!model.isConfigured)
            }
            IconButton("chart.xyaxis.line", help: "History") { open("history") }
            IconButton("gearshape", help: "Settings") { open("settings") }
                .keyboardShortcut(",")
            IconButton("power", help: "Quit Motas") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct PoolCard: View {
    let pool: PoolSummary
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pool.provider.displayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let reserve = pool.reserve {
                Text(Format.percent(reserve)).font(.title2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(Format.tint(reserve, threshold: threshold))
                Text("\(pool.measuredCount - pool.exhaustedCount)/\(pool.measuredCount) usable")
                    .font(.caption2).foregroundStyle(.secondary)
                if pool.unknownCount > 0 {
                    Text("+\(pool.unknownCount) without figures").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("—").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(Format.count(pool.unknownCount, "account")), no figures").font(.caption2).foregroundStyle(.secondary)
            }
            if let reset = pool.nextReset {
                Text("reset \(Format.relative(reset))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct ProxySection: View {
    let proxy: ProxySnapshot
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(proxy.health.isOK ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(proxy.name).font(.callout.weight(.semibold))
                Text(proxy.kind.displayName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if proxy.health.isOK {
                    Text(Format.count(proxy.accounts.count, "account")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !proxy.health.isOK {
                Text(proxy.health.summary).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(groups, id: \.0) { provider, accounts in
                ProviderGroup(provider: provider, accounts: accounts, threshold: threshold)
            }
        }
    }

    private var groups: [(Provider, [AccountSnapshot])] {
        Dictionary(grouping: proxy.accounts) { $0.provider }.sorted { $0.key < $1.key }
    }
}

private struct ExpandGroupsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Rendering/debug aid: start every provider group expanded.
    var motasExpandGroups: Bool {
        get { self[ExpandGroupsKey.self] }
        set { self[ExpandGroupsKey.self] = newValue }
    }
}

struct ProviderGroup: View {
    let provider: Provider
    let accounts: [AccountSnapshot]
    let threshold: Double
    @Environment(\.motasExpandGroups) private var expandAll
    @State private var expanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded ?? expandAll }, set: { expanded = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(accounts.sorted { order($0, $1) }) { AccountRow(account: $0, threshold: threshold) }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(provider.displayName).font(.callout)
                Text("\(active.count)\(disabledCount > 0 ? " + \(disabledCount) off" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let reserve = summary?.reserve {
                    Text(Format.percent(reserve)).font(.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle(Format.tint(reserve, threshold: threshold))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded = !(expanded ?? expandAll) } }
        }
    }

    private var active: [AccountSnapshot] { accounts.filter { $0.state != .disabled } }
    private var disabledCount: Int { accounts.count - active.count }
    private var summary: PoolSummary? {
        Pool.summarize(Snapshot(fetchedAt: .now, proxies: [ProxySnapshot(id: UUID(), name: "", kind: .cliProxyAPI, fetchedAt: .now, health: .ok, accounts: accounts)])).first
    }

    /// Disabled last, then lowest remaining first.
    private func order(_ a: AccountSnapshot, _ b: AccountSnapshot) -> Bool {
        if (a.state == .disabled) != (b.state == .disabled) { return b.state == .disabled }
        return (Pool.remaining(a) ?? 2) < (Pool.remaining(b) ?? 2)
    }
}

struct AccountRow: View {
    let account: AccountSnapshot
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(account.label).font(.caption).lineLimit(1).truncationMode(.middle)
                if let plan = account.plan {
                    Text(plan.uppercased()).font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                if account.state == .disabled { Text("disabled").font(.caption2).foregroundStyle(.secondary) }
            }
            switch account.quota {
            case .windows(let windows):
                ForEach(windows) { WindowBar(window: $0, threshold: threshold) }
            case .unavailable(let reason):
                if account.state != .disabled {
                    Text(reason).font(.caption2).foregroundStyle(.secondary)
                }
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
            }
            if let message = account.stateMessage {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .opacity(account.state == .disabled ? 0.5 : 1)
    }
}

struct WindowBar: View {
    let window: QuotaWindow
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let reset = window.resetsAt, window.remainingFraction < 1 {
                    Text("resets \(Format.relative(reset))").font(.caption2).foregroundStyle(.secondary)
                }
                Text(Format.percent(window.remainingFraction)).font(.caption2.weight(.medium)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Format.tint(window.remainingFraction, threshold: threshold))
                        .frame(width: max(0, geo.size.width * window.remainingFraction))
                }
            }
            .frame(height: 4)
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
