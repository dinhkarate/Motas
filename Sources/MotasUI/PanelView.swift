import AppKit
import Combine
import MotasCore
import MotasDesign
import SwiftUI

// MARK: Menu bar

/// Menu bar label: a two-bar gauge (the headline and the next pool) plus the
/// headline as text. Drawn with AppKit into a template NSImage — a MenuBarExtra label
/// must stay a plain Image/Text (ImageRenderer there crashes).
public struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let gauge = Pool.gauge(model.pools, pinned: model.menuBarPool)
        HStack(spacing: 4) {
            if model.needsKeychainAccess {
                Image(systemName: "key.fill").font(.system(size: 12, weight: .semibold))
            } else if model.isConfigured, !gauge.isEmpty {
                Image(nsImage: MenuBarGauge.image(top: gauge.first?.reserve, bottom: gauge.dropFirst().first?.reserve,
                                                  dimmed: dimmed(gauge.first)))
            }
            if !model.isConfigured || gauge.isEmpty {
                Text("Motas")
            } else if let pool = gauge.first {
                Text("\(hasActionableProblem ? "⚠︎ " : "")\(pool.title) \(pool.reserve.map(Design.percentWhole) ?? "—")")
                    .monospacedDigit()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .motasOpenSettings)) { _ in
            WindowPresenter.show("settings", using: openWindow)
        }
    }

    /// The headline's measured accounts are all stale, or it has no reserve.
    private func dimmed(_ pool: PoolSummary?) -> Bool {
        guard let pool, let reserve = pool.reserve else { return true }
        return reserve >= 0 && pool.measured > 0 && pool.stale >= pool.measured
    }

    /// A proxy problem worth a glyph, or rejected accounts in a metered pool.
    private var hasActionableProblem: Bool {
        guard model.isOnline else { return false }
        return model.snapshot.proxies.contains(where: \.isUnhealthy)
            || model.pools.contains { $0.rejected > 0 && $0.members > 0 }
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
    @State private var filter: PoolFilter?
    @State private var contentHeight: CGFloat = 0

    public init(model: AppModel) { self.model = model }

    private var threshold: Double { model.settings.lowReserveThreshold }
    private var now: Date { model.now }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            banners
            if model.isConfigured {
                if showFirstRun { FirstRunCard(model: model) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        poolGrid
                        hiddenPoolsRow
                        ForEach(model.snapshot.proxies) { proxy in
                            ProxySection(proxy: proxy, model: model, filter: filter, threshold: threshold,
                                         now: now, staleAfter: staleAfter)
                        }
                        if model.snapshot.proxies.isEmpty {
                            Text(model.isRefreshing ? "Reading proxies…" : "No data yet.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
                }
                // A ScrollView in a menu-bar window shrinks to almost nothing:
                // size it to its content, up to what fits under the menu bar.
                .frame(height: contentHeight > 0 ? min(contentHeight, maxScrollHeight) : nil)
                .frame(maxHeight: maxScrollHeight)
                .onPreferenceChange(ContentHeightKey.self) { height in MainActor.assumeIsolated { contentHeight = height } }
            } else {
                emptyState
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
        .environment(\.locale, Design.locale)
        .onAppear { model.panelOpened() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Motas").font(.system(size: 15, weight: .semibold))
            Spacer()
            if let status = headerStatus {
                Text(status.text).font(.caption).foregroundStyle(status.color).lineLimit(1)
            }
            if model.isRefreshing {
                ProgressView().controlSize(.mini).frame(width: 20)
            } else {
                IconButton("arrow.clockwise", help: "Refresh now") { model.refresh(force: true, reason: "manual") }
                    .keyboardShortcut("r")
                    .disabled(!model.isConfigured)
            }
        }
    }

    /// "Updated 2 min ago", "1 of 2 proxies stale · data from 14 min ago", or "Offline".
    private var headerStatus: (text: String, color: Color)? {
        if !model.isOnline { return ("Offline", .secondary) }
        guard model.isConfigured else { return nil }
        let enabled = model.settings.proxies.filter(\.isEnabled)
        let stale = enabled.filter { config in
            guard let proxy = model.snapshot.proxies.first(where: { $0.id == config.id }) else { return true }
            return now.timeIntervalSince(proxy.fetchedAt) > staleAfter
        }.count
        if stale > 0 {
            let age = model.snapshot.fetchedAt > .distantPast ? Design.relative(model.snapshot.fetchedAt, now: now) : "never"
            return ("\(stale) of \(enabled.count) proxies stale · data from \(age)", .orange)
        }
        guard model.snapshot.fetchedAt > .distantPast else { return nil }
        return ("Updated \(Design.relative(model.snapshot.fetchedAt, now: now))", .secondary)
    }

    private var maxScrollHeight: CGFloat {
        min(640, max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 220))
    }

    private var staleAfter: TimeInterval { max(120, model.settings.clampedRefreshInterval * 1.5) }

    @ViewBuilder private var banners: some View {
        ForEach([model.settingsError, model.secretError, model.saveError].compactMap { $0 }, id: \.self) { error in
            Banner(text: error, symbol: "exclamationmark.octagon.fill", tint: .red)
        }
        if model.needsKeychainAccess {
            Banner(text: "Motas needs Keychain access to read proxy credentials.", symbol: "key.fill", tint: .orange,
                   action: ("Allow…", { Task { await model.approveKeychain() } }))
        }
        ForEach(model.snapshot.proxies.filter(\.isUnhealthy)) { proxy in
            ProxyProblemBanner(proxy: proxy, now: now,
                               dashboardURL: model.settings.proxies.first { $0.id == proxy.id }?.dashboardURL)
        }
    }

    private var showFirstRun: Bool {
        !model.onboardingDone && model.snapshot.proxies.contains { $0.health.isOK && !$0.accounts.isEmpty }
    }

    private var poolGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), spacing: 8, alignment: .top)],
                  alignment: .leading, spacing: 8) {
            ForEach(model.pools) { pool in
                PoolCard(pool: pool, threshold: model.settings.threshold(for: pool.id), now: now,
                         pinned: model.menuBarPool == pool.id, selected: filter == pool.filterKey,
                         muted: !model.settings.options(for: pool.id).notify) {
                    filter = filter == pool.filterKey ? nil : pool.filterKey
                }
                .overlay(alignment: .topTrailing) {
                    Menu { PoolOptionsMenu(pool: pool, model: model) } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("\(pool.title) options: warning level, which window counts, notifications")
                    .padding(6)
                }
                .contextMenu { PoolOptionsMenu(pool: pool, model: model) }
            }
        }
    }

    @ViewBuilder private var hiddenPoolsRow: some View {
        if !model.hiddenPools.isEmpty {
            Menu("\(model.hiddenPools.count) hidden: \(model.hiddenPools.map(\.title).joined(separator: ", "))") {
                ForEach(model.hiddenPools) { pool in
                    Button("Show \(pool.title)") { model.setOptions(for: pool.id) { $0.hidden = false } }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .font(.caption).foregroundStyle(.secondary)
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
        HStack(spacing: 2) {
            FooterButton("History", symbol: "chart.xyaxis.line") { open("history") }
            FooterButton("Settings", symbol: "gearshape") { open("settings") }.keyboardShortcut(",")
            FooterButton("Desktop", symbol: model.desktopWidgetEnabled ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle") {
                model.desktopWidgetEnabled.toggle()
            }
            .help(model.desktopWidgetEnabled ? "Hide Model Pulse" : "Show Model Pulse on the desktop")
            Spacer()
            FooterButton("Quit", symbol: "power", showsTitle: false) { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }

    private func open(_ id: String) {
        WindowPresenter.show(id, using: openWindow)
    }
}

// MARK: First run

/// Shown once, after the first successful refresh: two toggles and Done.
struct FirstRunCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Motas is reading your proxies").font(.system(size: 12, weight: .semibold))
            Toggle("Show Model Pulse on desktop", isOn: $model.desktopWidgetEnabled)
                .toggleStyle(.checkbox).font(.caption)
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchesAtLogin },
                set: { on in do { try model.setLaunchAtLogin(on) } catch {} }
            ))
            .toggleStyle(.checkbox).font(.caption)
            HStack {
                Spacer()
                Button("Done") { model.onboardingDone = true }.controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1))
    }
}

// MARK: Pool card

/// The filter a pool card sets: provider and tier, as §9.2 defines it.
struct PoolFilter: Equatable {
    var provider: Provider
    var tier: String

    init(_ key: PoolKey) {
        provider = key.provider
        tier = key.tier
    }
}

extension PoolSummary {
    var filterKey: PoolFilter { PoolFilter(key) }
}

/// One compact pool card: title, big reserve, meter, detail and lanes.
struct PoolCard: View {
    let pool: PoolSummary
    let threshold: Double
    let now: Date
    let pinned: Bool
    let selected: Bool
    var muted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(pool.title.uppercased())
                        .font(.system(size: 9, weight: .bold)).tracking(0.6)
                        .foregroundStyle(.secondary).lineLimit(1)
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 7)).foregroundStyle(.tertiary) }
                    if muted { Image(systemName: "bell.slash.fill").font(.system(size: 7)).foregroundStyle(.tertiary) }
                    Spacer(minLength: 0)
                    if pool.stale > 0 { Marker("stale", color: .orange) }
                    if pool.unknown > 0 { Marker("?", color: .secondary) }
                }
                .padding(.trailing, 16)   // room for the options button
                if let reserve = pool.reserve {
                    Text(Design.percent(reserve))
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Design.levelColor(reserve, threshold: threshold))
                    CapsuleBar(reserve, color: Design.levelColor(reserve, threshold: threshold), height: 4)
                } else {
                    Text("—").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    CapsuleBar(nil, color: .secondary, height: 4)
                }
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let basis {
                    Text("By \(basis)").font(.system(size: 9)).foregroundStyle(.tertiary)
                } else if pool.lanes.count > 1 {
                    Text(lanes).font(.system(size: 9)).foregroundStyle(.tertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(selected ? 0.10 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pool.title), \(pool.reserve.map(Design.percent) ?? "unknown")")
    }

    private var basis: String? {
        guard let id = pool.basis, let lane = pool.lanes.first(where: { $0.id == id }) else { return nil }
        return pool.lanes.filter { $0.id != id }.isEmpty ? lane.label : "\(lane.label) · " + pool.lanes.filter { $0.id != id }
            .map { "\($0.label) \(Design.percent($0.mean))" }.joined(separator: " · ")
    }

    private var detail: String {
        var parts = ["\(pool.usable)/\(pool.members) usable"]
        if pool.rejected > 0 { parts.append("\(pool.rejected) need re-login") }
        if let back = pool.nextRecoveryAt { parts.append("back \(Design.day(back))") }
        if pool.resetCredits > 0 {
            parts.append("\(pool.resetCredits) reset credit\(pool.resetCredits == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private var lanes: String {
        pool.lanes.map { "\($0.label) \(Design.percent($0.mean))" }.joined(separator: " · ")
    }
}

private struct Marker: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: Proxy → provider → account

struct ProxySection: View {
    let proxy: ProxySnapshot
    @ObservedObject var model: AppModel
    let filter: PoolFilter?
    let threshold: Double
    let now: Date
    let staleAfter: TimeInterval

    @State private var collapsed = false
    @State private var showNotMetered = false

    var body: some View {
        if filter == nil || !groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header
                if !proxy.health.isOK {
                    Text(proxy.health.summary)
                        .font(.caption).foregroundStyle(proxy.health == .needsKeychainAccess ? .orange : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isStale, proxy.health.isOK {
                    Text("Data from \(Design.relative(proxy.fetchedAt, now: now))")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
                if !collapsed {
                    ForEach(groups) { group in
                        ProviderBlock(group: group, proxy: proxy, threshold: threshold, now: now, dashboardURL: dashboardURL)
                    }
                    if !disabledSummary.isEmpty {
                        Text("Disabled: \(disabledSummary)")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if !unmeteredGroups.isEmpty { notMetered }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                HStack(spacing: 6) {
                    Circle().fill(healthColor).frame(width: 7, height: 7)
                    Text(proxy.name).font(.system(size: 12, weight: .semibold))
                    Text(proxy.kind.displayName).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if let dashboardURL {
                Button("Open dashboard") { NSWorkspace.shared.open(dashboardURL) }
                    .buttonStyle(.link).font(.system(size: 10))
            }
        }
        .padding(.top, 6)
    }

    private var healthColor: Color {
        switch proxy.health {
        case .ok: .green
        case .needsKeychainAccess: .orange
        case .failed: .red
        }
    }

    private var dashboardURL: URL? {
        model.settings.proxies.first { $0.id == proxy.id }?.dashboardURL
    }

    private var isStale: Bool { now.timeIntervalSince(proxy.fetchedAt) > staleAfter }

    private var groups: [ProviderAccounts] {
        var byProvider: [Provider: [AccountSnapshot]] = [:]
        for account in proxy.accounts where account.state == .active {
            if case .unavailable = account.quota { continue }
            byProvider[account.provider, default: []].append(account)
        }
        return byProvider.compactMap { provider, accounts in
            let matching = accounts.filter { account in
                guard let filter else { return true }
                return account.provider == filter.provider
                    && Pool.tier(account.provider, plan: account.plan) == filter.tier
            }
            guard !matching.isEmpty else { return nil }
            return ProviderAccounts(provider: provider, accounts: matching, now: now,
                                    staleLimit: model.settings.staleLimit)
        }
        .sorted { Pool.precedes($0.provider, $1.provider) }
    }

    private var unmeteredGroups: [Pool.UnmeteredGroup] { Pool.unmetered(proxy) }

    private var unmeteredAccounts: [AccountSnapshot] {
        proxy.accounts.filter {
            guard $0.state == .active else { return false }
            if case .unavailable = $0.quota { return true }
            return false
        }
    }

    private var unmeteredSummary: String {
        unmeteredGroups.map { group in
            var text = group.name + (group.count > 1 ? " ×\(group.count)" : "")
            if group.quotaExceeded { text += " (quota exceeded)" }
            return text
        }
        .joined(separator: " · ")
    }

    private var disabledSummary: String {
        Dictionary(grouping: proxy.accounts.filter { $0.state == .disabled }, by: \.provider)
            .map { provider, accounts in
                let name = provider.displayName(hint: accounts.first?.displayHint)
                return accounts.count > 1 ? "\(name) ×\(accounts.count)" : name
            }
            .sorted()
            .joined(separator: ", ")
    }

    private var notMetered: some View {
        DisclosureRow(title: "Not metered: \(unmeteredSummary)", color: .secondary, expanded: $showNotMetered) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(unmeteredGroups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(group.name + (group.count > 1 ? " ×\(group.count)" : ""))
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            if group.quotaExceeded {
                                Text("quota exceeded").font(.system(size: 9)).foregroundStyle(.orange)
                            }
                            Spacer(minLength: 4)
                            if !hasPool(group.provider) {
                                Button(model.isOnDesktop(provider: group.provider) ? "Hide from desktop" : "Show on desktop") {
                                    model.toggleDesktopCard(DesktopWidgetData.statusID(group.provider))
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 9))
                                .disabled(!model.isOnDesktop(provider: group.provider)
                                    && model.desktopCards.count >= DesktopWidgetData.limit)
                                .help(model.isOnDesktop(provider: group.provider)
                                    ? "Hide \(group.name) from Model Pulse" : "Show \(group.name) on Model Pulse")
                            }
                        }
                        ForEach(unmeteredAccounts.filter { $0.provider == group.provider }) { account in
                            Text("\(account.label) — \(message(account))")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.leading, 12)
        }
    }

    private func hasPool(_ provider: Provider) -> Bool {
        model.pools.contains { $0.key.provider == provider }
    }

    private func message(_ account: AccountSnapshot) -> String {
        if case .unavailable(let message) = account.quota { return message }
        return ""
    }
}

/// One provider's accounts inside a proxy, split by what the panel shows.
struct ProviderAccounts: Identifiable {
    var provider: Provider
    var name: String
    var usable: [AccountSnapshot]
    var exhausted: [AccountSnapshot]
    var rejected: [AccountSnapshot]
    var unknown: [AccountSnapshot]

    var id: Provider { provider }

    init(provider: Provider, accounts: [AccountSnapshot], now: Date, staleLimit: TimeInterval) {
        self.provider = provider
        name = provider.displayName(hint: accounts.first?.displayHint)
        var usable: [AccountSnapshot] = [], exhausted: [AccountSnapshot] = [], rejected: [AccountSnapshot] = []
        var unknown: [AccountSnapshot] = []
        for account in accounts {
            switch account.quota {
            case .unavailable:
                continue
            case .rejected:
                rejected.append(account)
            case .failed:
                unknown.append(account)
            case .windows:
                let stale = account.quotaObservedAt.map { now.timeIntervalSince($0) > staleLimit } ?? true
                if stale {
                    unknown.append(account)
                } else if (account.quota.effectiveRemaining ?? 1) <= Pool.exhaustedThreshold {
                    exhausted.append(account)
                } else {
                    usable.append(account)
                }
            }
        }
        self.usable = usable.sorted { ($0.quota.effectiveRemaining ?? 2) < ($1.quota.effectiveRemaining ?? 2) }
        self.exhausted = exhausted.sorted { $0.label < $1.label }
        self.rejected = rejected.sorted { $0.label < $1.label }
        self.unknown = unknown.sorted { $0.label < $1.label }
    }
}

struct ProviderBlock: View {
    let group: ProviderAccounts
    let proxy: ProxySnapshot
    let threshold: Double
    let now: Date
    let dashboardURL: URL?

    @Environment(\.motasExpandGroups) private var expandAll
    @State private var showExhausted = false
    @State private var showRejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(group.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(group.usable.count + group.exhausted.count + group.rejected.count + group.unknown.count)")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.leading, 4)
            ForEach(group.usable) { account in row(account) }
            if !group.exhausted.isEmpty {
                DisclosureRow(title: exhaustedTitle, color: .red, expanded: $showExhausted) {
                    VStack(spacing: 2) { ForEach(group.exhausted) { row($0) } }
                }
            }
            if !group.rejected.isEmpty {
                DisclosureRow(title: "Needs re-login ×\(group.rejected.count)", color: .orange, expanded: $showRejected) {
                    VStack(spacing: 2) { ForEach(group.rejected) { row($0) } }
                }
            }
            ForEach(group.unknown) { account in row(account) }
        }
    }

    private func row(_ account: AccountSnapshot) -> some View {
        AccountRow(account: account, proxyKind: proxy.kind, dashboardURL: dashboardURL,
                   threshold: threshold, now: now, expanded: expandAll)
    }

    private var exhaustedTitle: String {
        var parts = ["Exhausted ×\(group.exhausted.count)"]
        if let back = nextBack { parts.append("next back \(Design.day(back))") }
        let credits = group.exhausted.compactMap(\.extras.resetCredits).reduce(0, +)
        if credits > 0 { parts.append("\(credits) reset credit\(credits == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// The earliest instant an exhausted account is back: its last out window,
    /// but not before a cooldown ends.
    private var nextBack: Date? {
        group.exhausted.compactMap { account -> Date? in
            let windows = account.quota.windows.filter { $0.remainingFraction <= Pool.exhaustedThreshold }
            let windowBack = windows.compactMap(\.resetsAt).max()
            let cooldown = account.cooldownUntil.flatMap { $0 > now ? $0 : nil }
            return [windowBack, cooldown].compactMap { $0 }.max()
        }.min()
    }
}

struct DisclosureRow<Content: View>: View {
    let title: String
    let color: Color
    @Binding var expanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(.system(size: 10)).foregroundStyle(color)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            if expanded { content().padding(.leading, 4) }
        }
    }
}

/// Compact row: family mark, account, plan, one mini bar per pool group,
/// percentage. Click to see every window with its reset time.
struct AccountRow: View {
    let account: AccountSnapshot
    let proxyKind: ProxyKind
    let dashboardURL: URL?
    let threshold: Double
    let now: Date
    @State private var expanded: Bool
    @State private var hovering = false

    init(account: AccountSnapshot, proxyKind: ProxyKind, dashboardURL: URL?, threshold: Double, now: Date,
         expanded: Bool = false) {
        self.account = account
        self.proxyKind = proxyKind
        self.dashboardURL = dashboardURL
        self.threshold = threshold
        self.now = now
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
        .contextMenu {
            if let email = account.email { Button("Copy email") { copy(email) } }
            Button("Copy connection id") { copy(account.id) }
            if let dashboardURL { Button("Open dashboard") { NSWorkspace.shared.open(dashboardURL) } }
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            ProviderBadge(account.provider, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(account.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if let chip = planChip {
                        Text(chip.text).font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(chip.color.opacity(0.12)))
                            .foregroundStyle(chip.color)
                            .lineLimit(1)
                            .help(chip.help)
                    }
                }
                if let note { Text(note.text).font(.system(size: 10)).foregroundStyle(note.color).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if !bars.isEmpty {
                HStack(spacing: 4) {
                    ForEach(bars) { bar in
                        VStack(spacing: 2) {
                            if let tag = bar.tag {
                                Text(tag).font(.system(size: 6, weight: .bold)).foregroundStyle(.secondary)
                            }
                            CapsuleBar(bar.value, color: Design.levelColor(bar.value, threshold: threshold), height: 4)
                        }
                        .frame(width: bar.tag == nil ? 40 : 30)
                    }
                }
            }
            Text(percentText).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(isStale ? Color.secondary : Design.levelColor(account.quota.effectiveRemaining, threshold: threshold))
                .frame(minWidth: 36, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    private var percentText: String {
        if account.state == .disabled { return "off" }
        guard let remaining = account.quota.effectiveRemaining else { return "—" }
        return Design.percent(remaining)
    }

    /// The plan chip, amber and with "was" when the sign-in and the usage disagree.
    private var planChip: (text: String, color: Color, help: String)? {
        guard let plan = account.plan, !plan.isEmpty else { return nil }
        if let metadata = account.metadataPlan, metadata.caseInsensitiveCompare(plan) != .orderedSame {
            return ("\(plan.uppercased()) · was \(metadata.uppercased())", .orange,
                    "Sign-in says \(metadata.capitalized), usage says \(plan.capitalized)")
        }
        return (plan.uppercased(), .secondary, "Plan: \(plan.capitalized)")
    }

    private struct Bar: Identifiable {
        var id: String
        var tag: String?
        var value: Double
    }

    /// One bar per pool group; an account without groups gets one bar.
    private var bars: [Bar] {
        let windows = account.quota.windows.filter { $0.role != .detail }
        let groups = Set(windows.compactMap(\.group)).subtracting(["image", "other"])
        if groups.isEmpty {
            guard let value = windows.filter({ $0.role == .limit }).map(\.remainingFraction).min() else { return [] }
            return [Bar(id: "", tag: nil, value: value)]
        }
        return groups.sorted(by: QuotaGroups.precedes).compactMap { group in
            let limits = windows.filter { $0.group == group && $0.role == .limit }
            let models = windows.filter { $0.group == group && $0.role == .model }
            guard let value = limits.map(\.remainingFraction).min() ?? models.map(\.remainingFraction).max() else { return nil }
            return Bar(id: group, tag: tag(for: group), value: value)
        }
    }

    /// Antigravity bars carry the family: G for Gemini, C&G for Claude & GPT.
    private func tag(for group: String) -> String? {
        guard account.provider == .antigravity else { return nil }
        switch group {
        case "gemini": return "G"
        case "claude-gpt": return "C&G"
        default: return nil
        }
    }

    private var isStale: Bool {
        guard case .windows = account.quota, let observed = account.quotaObservedAt else { return false }
        return now.timeIntervalSince(observed) > 3 * 3600
    }

    @ViewBuilder private var details: some View {
        switch account.quota {
        case .windows(let windows):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(windows.filter { $0.role == .limit }.sorted(by: Self.windowOrder)) { window in
                    limitWindow(window)
                }
                let compact = windows.filter { $0.role != .limit }.sorted(by: Self.windowOrder)
                if !compact.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(compact) { window in
                            HStack(spacing: 6) {
                                Text(window.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(Design.percent(window.remainingFraction)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(Design.levelColor(window.remainingFraction, threshold: threshold))
                                if let reset = window.resetsAt {
                                    Text(Design.day(reset)).font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                facts
            }
        case .unavailable(let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary)
        case .failed(let reason), .rejected(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
    }

    private func limitWindow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(Design.percent(window.remainingFraction)) left").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Design.levelColor(window.remainingFraction, threshold: threshold))
            }
            CapsuleBar(window.remainingFraction, color: Design.levelColor(window.remainingFraction, threshold: threshold), height: 5)
            if let reset = window.resetsAt, window.remainingFraction < 1 {
                Text("\(window.remainingFraction <= Pool.exhaustedThreshold ? "Back" : "Resets") \(Design.relative(reset, now: now)) · \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Design.locale)))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var facts: some View {
        if let observed = account.quotaObservedAt {
            Text("Read \(Design.relative(observed, now: now))").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        if let next = account.nextReadAt, next > now {
            Text("Next read \(Design.time(next))").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        ForEach(account.lockedModels.keys.sorted(), id: \.self) { model in
            if let until = account.lockedModels[model] {
                Text("\(model) locked until \(Design.time(until))").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        if let credits = account.extras.resetCredits, credits > 0 {
            Text("\(credits) reset credit\(credits == 1 ? "" : "s")").font(.system(size: 9)).foregroundStyle(.orange)
        }
        if account.extras.quotaExceeded == true {
            Text("Quota exceeded").font(.system(size: 9)).foregroundStyle(.orange)
        }
    }

    /// Limit first; model and detail after, by label.
    private static func windowOrder(_ a: QuotaWindow, _ b: QuotaWindow) -> Bool {
        let rank: (WindowRole) -> Int = { $0 == .limit ? 0 : 1 }
        if rank(a.role) != rank(b.role) { return rank(a.role) < rank(b.role) }
        return a.label < b.label
    }

    /// The first note that applies: re-login, cooling, read failed, ran out, proxy note.
    private var note: (text: String, color: Color)? {
        if case .rejected(let reason) = account.quota {
            return (reason.isEmpty ? "Needs re-login" : "Needs re-login: \(reason)", .orange)
        }
        if let until = account.cooldownUntil, until > now {
            return ("Cooling down until \(Design.time(until))", .orange)
        }
        if account.coolingDown { return ("Cooling down", .orange) }
        if case .failed(let reason) = account.quota { return ("Read failed: \(reason)", .orange) }
        if account.lastReadError != nil, let observed = account.quotaObservedAt {
            return ("Read failed · showing data from \(Design.relative(observed, now: now))", .orange)
        }
        if case .windows(let windows) = account.quota,
           let empty = windows.first(where: { $0.remainingFraction <= Pool.exhaustedThreshold }) {
            var text = "\(empty.label) ran out"
            if let reset = empty.resetsAt { text += " · back \(Design.day(reset))" }
            let credits = account.extras.resetCredits ?? 0
            if credits > 0 { text += " · \(credits) reset credit\(credits == 1 ? "" : "s")" }
            return (text, credits > 0 ? .orange : .red)
        }
        if let note = account.proxyNote, shows(note) { return (note.message, .secondary) }
        if isStale, let observed = account.quotaObservedAt {
            return ("Data from \(Design.relative(observed, now: now))", .secondary)
        }
        return nil
    }

    /// 9Router's note is a dashboard label, so only a recent one; CPA only
    /// sets it for an error status or an unavailable account.
    private func shows(_ note: ProxyNote) -> Bool {
        switch proxyKind {
        case .nineRouter: note.at.map { now.timeIntervalSince($0) <= 86_400 } ?? false
        case .cliProxyAPI, .orca: true
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: Small pieces

struct ProxyProblemBanner: View {
    let proxy: ProxySnapshot
    let now: Date
    let dashboardURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(proxy.name): \(proxy.health.summary)").font(.caption).fixedSize(horizontal: false, vertical: true)
                if proxy.fetchedAt > .distantPast {
                    Text("Showing data from \(Design.relative(proxy.fetchedAt, now: now))")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let dashboardURL {
                Button("Open dashboard") { NSWorkspace.shared.open(dashboardURL) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.12)))
    }
}

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

struct FooterButton: View {
    let title: String
    let symbol: String
    let showsTitle: Bool
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, showsTitle: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.showsTitle = showsTitle
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                if showsTitle { Text(title).font(.system(size: 11)) }
            }
            .padding(.horizontal, showsTitle ? 7 : 5).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
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

/// One pool's choices, for its card's ⋯ button and context menu.
struct PoolOptionsMenu: View {
    let pool: PoolSummary
    @ObservedObject var model: AppModel

    static let levels: [Double] = [0.05, 0.1, 0.2, 0.3, 0.5]

    private var options: PoolOptions { model.settings.options(for: pool.id) }

    var body: some View {
        Section(pool.displayName) {
            Picker("Warn below", selection: Binding<Double?>(
                get: { options.lowReserveThreshold },
                set: { level in model.setOptions(for: pool.id) { $0.lowReserveThreshold = level } })) {
                Text("Default (\(Design.percent(model.settings.lowReserveThreshold)))").tag(Double?.none)
                ForEach(Self.levels, id: \.self) { Text(Design.percent($0)).tag(Double?.some($0)) }
            }
            if pool.lanes.filter({ $0.id != "models" }).count > 1 {
                Picker("Percentage from", selection: Binding<String?>(
                    get: { options.basis },
                    set: { basis in model.setOptions(for: pool.id) { $0.basis = basis } })) {
                    Text("Lowest window").tag(String?.none)
                    ForEach(pool.lanes.filter { $0.id != "models" }) { Text("\($0.label) window").tag(String?.some($0.id)) }
                }
            }
            Toggle("Notifications", isOn: Binding(
                get: { options.notify },
                set: { on in model.setOptions(for: pool.id) { $0.notify = on } }))
        }
        Divider()
        Button(model.menuBarPool == pool.id ? "Unpin from menu bar" : "Pin to menu bar") {
            model.menuBarPool = model.menuBarPool == pool.id ? nil : pool.id
        }
        Button(model.isOnDesktop(poolID: pool.id) ? "Hide from desktop" : "Show on desktop") {
            model.toggleDesktopCard(pool.id)
        }
        .disabled(!model.isOnDesktop(poolID: pool.id) && model.desktopCards.count >= DesktopWidgetData.limit)
        Button("Hide \(pool.title)") {
            if model.menuBarPool == pool.id { model.menuBarPool = nil }
            model.setOptions(for: pool.id) { $0.hidden = true }
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ExpandGroupsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Rendering/debug aid: start every account row expanded.
    var motasExpandGroups: Bool {
        get { self[ExpandGroupsKey.self] }
        set { self[ExpandGroupsKey.self] = newValue }
    }
}
