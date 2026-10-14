import AppKit
import MotasCore
import MotasDesign
import SwiftUI

// MARK: Menu bar

/// Menu bar label: a two-bar gauge (the two lowest pools) plus the lowest pool
/// as text. Drawn with AppKit into a template NSImage — a MenuBarExtra label
/// must stay a plain Image/Text (ImageRenderer there crashes).
public struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let measured = model.pools.filter { $0.reserve != nil }.sorted { $0.reserve! < $1.reserve! }
        let problem = model.snapshot.proxies.contains { !$0.health.isOK }
        HStack(spacing: 4) {
            Image(nsImage: MenuBarGauge.image(top: measured.first?.reserve, bottom: measured.dropFirst().first?.reserve,
                                              dimmed: problem || measured.isEmpty))
            if let pool = measured.first, let reserve = pool.reserve {
                Text("\(problem ? "⚠︎ " : "")\(pool.provider.displayName) \(Design.percent(reserve))").monospacedDigit()
            } else if problem {
                Text("⚠︎")
            }
        }
    }
}

enum MenuBarGauge {
    /// 18×18 template: top bar 6pt, bottom bar 4pt, 15pt wide, filled by what is left.
    static func image(top: Double?, bottom: Double?, dimmed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let alpha: CGFloat = dimmed ? 0.55 : 1
            func bar(y: CGFloat, height: CGFloat, fraction: Double?) {
                let track = NSBezierPath(roundedRect: NSRect(x: 1.5, y: y, width: 15, height: height), xRadius: height / 2, yRadius: height / 2)
                NSColor.black.withAlphaComponent(0.28 * alpha).setFill()
                track.fill()
                guard let fraction, fraction > 0 else { return }
                let width = max(height, 15 * min(fraction, 1))
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: NSRect(x: 1.5, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
            }
            bar(y: 3, height: 6, fraction: top)
            bar(y: 11, height: 4, fraction: bottom ?? top)
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: Panel

public struct PanelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var filter: Provider?

    public init(model: AppModel) { self.model = model }

    private var threshold: Double { model.settings.lowReserveThreshold }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.appError {
                Banner(text: error, symbol: "exclamationmark.octagon.fill", tint: .red)
            }
            if model.needsKeychainAccess {
                Banner(text: "Motas needs Keychain access to read proxy credentials.", symbol: "key.fill", tint: .orange,
                       action: ("Allow…", { Task { await model.approveKeychainAccess() } }))
            }
            if model.isConfigured {
                if providers.count > 1 { filterPills }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(visiblePools) { PoolCard(pool: $0, threshold: threshold) }
                        ForEach(model.snapshot.proxies) { proxy in
                            ProxySection(proxy: proxy, filter: filter, threshold: threshold)
                        }
                        if model.snapshot.proxies.isEmpty {
                            Text(model.isRefreshing ? "Reading proxies…" : "No data yet.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 520)
            } else {
                emptyState
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
        .environment(\.locale, Design.locale)
    }

    private var providers: [Provider] { model.pools.map(\.provider) }
    private var visiblePools: [PoolSummary] { model.pools.filter { filter == nil || $0.provider == filter } }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Motas").font(.system(size: 15, weight: .semibold))
            Spacer()
            if model.snapshot.fetchedAt > .distantPast {
                Text("Updated \(Design.relative(model.snapshot.fetchedAt))").font(.caption).foregroundStyle(.secondary)
            }
            if model.isRefreshing {
                ProgressView().controlSize(.mini).frame(width: 20)
            } else {
                IconButton("arrow.clockwise", help: "Refresh now") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(!model.isConfigured)
            }
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Pill(title: "All", selected: filter == nil) { filter = nil }
                ForEach(providers, id: \.self) { provider in
                    Pill(title: provider.displayName, color: Design.color(for: provider), selected: filter == provider) {
                        filter = filter == provider ? nil : provider
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("No proxy yet").font(.headline)
            Text("Add a CLIProxyAPI or 9Router server to see the quota of every account it holds.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add Proxy…") { open("settings") }.buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton("Settings…", symbol: "gearshape") { open("settings") }.keyboardShortcut(",")
            FooterButton("History", symbol: "chart.xyaxis.line") { open("history") }
            Spacer()
            FooterButton("Quit", symbol: "power") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

// MARK: Pool card

/// One provider across every proxy: big reserve, bar, usable count, next reset.
struct PoolCard: View {
    let pool: PoolSummary
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProviderBadge(pool.provider, size: 18)
                Text(pool.provider.displayName).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            if let reserve = pool.reserve {
                HStack(spacing: 10) {
                    Text(Design.percent(reserve))
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Design.text(reserve, threshold: threshold))
                        .frame(minWidth: 58, alignment: .leading)
                    CapsuleBar(reserve, color: Design.fill(reserve, provider: pool.provider, threshold: threshold), height: 6)
                }
            } else {
                Text("No quota figures reported").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var detail: String {
        var parts = [usable]
        if let reset = pool.nextReset { parts.append("reset \(Design.relative(reset))") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var usable: String {
        var parts: [String] = []
        if pool.measuredCount > 0 { parts.append("\(pool.measuredCount - pool.exhaustedCount)/\(pool.measuredCount) usable") }
        if pool.unknownCount > 0 { parts.append("\(pool.unknownCount) unknown") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Proxy → provider → account

struct ProxySection: View {
    let proxy: ProxySnapshot
    let filter: Provider?
    let threshold: Double
    @Environment(\.motasExpandGroups) private var expandAll
    @State private var collapsed = false

    var body: some View {
        let groups = Dictionary(grouping: proxy.accounts) { $0.provider }
            .filter { filter == nil || $0.key == filter }
            .sorted { $0.key < $1.key }
        if filter == nil || !groups.isEmpty || !proxy.health.isOK {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                    HStack(spacing: 6) {
                        Circle().fill(proxy.health.isOK ? Color.green : Color.red).frame(width: 7, height: 7)
                        Text(proxy.name).font(.system(size: 12, weight: .semibold))
                        Text(proxy.kind.displayName).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if proxy.health.isOK {
                            Text(Design.count(proxy.accounts.count, "account")).font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                if !proxy.health.isOK {
                    Text(proxy.health.summary).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !collapsed {
                    ForEach(groups, id: \.key) { provider, accounts in
                        VStack(spacing: 2) {
                            ForEach(accounts.sorted { tightestFirst($0, $1) }) { AccountRow(account: $0, threshold: threshold, expanded: expandAll) }
                        }
                    }
                }
            }
        }
    }

    /// Disabled last, unknown after measured, lowest remaining first.
    private func tightestFirst(_ a: AccountSnapshot, _ b: AccountSnapshot) -> Bool {
        if (a.state == .disabled) != (b.state == .disabled) { return b.state == .disabled }
        return (Pool.remaining(a) ?? 2) < (Pool.remaining(b) ?? 2)
    }
}

/// Compact row: badge, account, plan, mini bars for the two tightest windows,
/// percentage. Click to see every window with its reset time.
struct AccountRow: View {
    let account: AccountSnapshot
    let threshold: Double
    @State private var expanded: Bool
    @State private var hovering = false

    init(account: AccountSnapshot, threshold: Double, expanded: Bool = false) {
        self.account = account
        self.threshold = threshold
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: { summary }
                .buttonStyle(.plain)
            if expanded { details.padding(.leading, 24) }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering || expanded ? 0.06 : 0)))
        .onHover { hovering = $0 }
        .opacity(account.state == .disabled ? 0.45 : 1)
    }

    private var summary: some View {
        HStack(spacing: 8) {
            ProviderBadge(account.provider, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(account.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if let plan = account.plan {
                        Text(plan.uppercased()).font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .foregroundStyle(.secondary)
                    }
                }
                if let note { Text(note).font(.system(size: 10)).foregroundStyle(noteColor).lineLimit(1) }
            }
            Spacer(minLength: 6)
            let tight = account.quota.windows.sorted { $0.remainingFraction < $1.remainingFraction }.prefix(2)
            if !tight.isEmpty {
                VStack(spacing: 3) {
                    ForEach(Array(tight)) { window in
                        CapsuleBar(window.remainingFraction,
                                   color: Design.fill(window.remainingFraction, provider: account.provider, threshold: threshold),
                                   height: 4)
                    }
                }
                .frame(width: 56)
            }
            Text(percentText).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Design.text(Pool.remaining(account), threshold: threshold))
                .frame(minWidth: 36, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var details: some View {
        switch account.quota {
        case .windows(let windows):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(windows) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(window.label).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Design.percent(window.remainingFraction)) left").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Design.text(window.remainingFraction, threshold: threshold))
                        }
                        CapsuleBar(window.remainingFraction,
                                   color: Design.fill(window.remainingFraction, provider: account.provider, threshold: threshold), height: 5)
                        if let reset = window.resetsAt, window.remainingFraction < 1 {
                            Text("\(window.remainingFraction <= 0.005 ? "Back" : "Resets") \(Design.relative(reset)) · \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Design.locale)))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .unavailable(let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
        if let message = account.stateMessage {
            Text(message).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var percentText: String {
        if account.state == .disabled { return "off" }
        guard let remaining = Pool.remaining(account) else { return "—" }
        return Design.percent(remaining)
    }

    /// One line under the account name: what is wrong, or which window ran out.
    private var note: String? {
        switch account.quota {
        case .failed(let reason): return reason
        case .unavailable(let reason): return account.state == .disabled ? nil : reason
        case .windows(let windows):
            guard let empty = windows.first(where: { $0.remainingFraction <= 0.005 }) else { return nil }
            return "\(empty.label) ran out" + (empty.resetsAt.map { " · back \(Design.relative($0))" } ?? "")
        }
    }

    private var noteColor: Color {
        if case .windows = account.quota { return .red }
        if case .failed = account.quota { return .orange }
        return .secondary
    }
}

// MARK: Small pieces

struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action { Button(action.0, action: action.1).controlSize(.small).accessibilityLabel(action.0) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
    }
}

struct Pill: View {
    let title: String
    var color: Color? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
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
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

private struct ExpandGroupsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Rendering/debug aid: start every account row expanded.
    var motasExpandGroups: Bool {
        get { self[ExpandGroupsKey.self] }
        set { self[ExpandGroupsKey.self] = newValue }
    }
}
