import MotasCore
import MotasDesign
import SwiftUI

/// One unmetered provider's status card. LIVE means at least one active,
/// non-rejected account on a healthy proxy; CHECK means connections exist but
/// every proxy is unhealthy or every active account was rejected; OFF means
/// nothing is active.
struct DesktopStatusCard: Identifiable, Hashable {
    enum State: String, Hashable {
        case live
        case check
        case off
    }

    var provider: Provider
    var name: String
    var state: State
    var detail: String

    var id: String { DesktopWidgetData.statusID(provider) }
}

/// One card on Model Pulse: a metered pool, or an unmetered provider's status.
enum DesktopCard: Identifiable {
    case pool(PoolSummary)
    case status(DesktopStatusCard)

    var id: String {
        switch self {
        case .pool(let pool): pool.id
        case .status(let status): status.id
        }
    }
}

/// The desktop widget's pure data: card order and status rules.
enum DesktopWidgetData {
    /// At most six cards fit on the panel.
    static let limit = 6
    static let statusPrefix = "unmetered|"

    static func statusID(_ provider: Provider) -> String { statusPrefix + provider.rawValue }

    /// One status per provider that has no metered pool. Providers named by a
    /// saved card stay as OFF even when the snapshot no longer lists them.
    static func statuses(_ snapshot: Snapshot, pools: [PoolSummary], order: [String]?) -> [DesktopStatusCard] {
        struct Facts {
            var active = 0
            var rejected = 0
            var live = 0
            var quotaExceeded = false
            var hint: String?
        }

        var facts: [Provider: Facts] = [:]
        for proxy in snapshot.proxies {
            for account in proxy.accounts {
                var fact = facts[account.provider] ?? Facts()
                fact.hint = fact.hint ?? account.displayHint
                if account.state == .active {
                    fact.active += 1
                    switch account.quota {
                    case .rejected:
                        fact.rejected += 1
                    default:
                        if proxy.health.isOK { fact.live += 1 }
                    }
                    if case .unavailable = account.quota, account.extras.quotaExceeded == true {
                        fact.quotaExceeded = true
                    }
                }
                facts[account.provider] = fact
            }
        }

        let metered = Set(pools.map(\.key.provider))
        var cards: [DesktopStatusCard] = []
        for provider in facts.keys.sorted(by: Pool.precedes) where !metered.contains(provider) {
            guard let fact = facts[provider] else { continue }
            let state: DesktopStatusCard.State = fact.live > 0 ? .live : fact.active > 0 ? .check : .off
            let detail: String
            switch state {
            case .live:
                detail = fact.quotaExceeded ? "Quota exceeded" : Design.count(fact.active, "connection")
            case .check:
                detail = fact.rejected == fact.active ? "Needs re-login" : "Proxy unhealthy"
            case .off:
                detail = "No active account"
            }
            cards.append(DesktopStatusCard(provider: provider, name: provider.displayName(hint: fact.hint),
                                           state: state, detail: detail))
        }

        // A saved card keeps its place as OFF when its provider vanished.
        if let order {
            let known = Set(cards.map(\.id))
            for id in order where id.hasPrefix(statusPrefix) && !known.contains(id) {
                let provider = Provider(rawValue: String(id.dropFirst(statusPrefix.count)))
                guard !metered.contains(provider) else { continue }
                cards.append(DesktopStatusCard(provider: provider, name: provider.displayName, state: .off,
                                               detail: "No active account"))
            }
        }
        return cards
    }

    /// The saved order when set, else the metered pools in their fixed order.
    /// Unknown ids are skipped and the result stops at six cards.
    static func cards(pools: [PoolSummary], statuses: [DesktopStatusCard], order: [String]?) -> [DesktopCard] {
        var byID: [String: DesktopCard] = [:]
        for pool in pools { byID[pool.id] = .pool(pool) }
        for status in statuses { byID[status.id] = .status(status) }
        var seen = Set<String>()
        var cards: [DesktopCard] = []
        for id in order ?? pools.map(\.id) {
            guard seen.insert(id).inserted, let card = byID[id] else { continue }
            cards.append(card)
            if cards.count == limit { break }
        }
        return cards
    }
}

// MARK: View

/// Model Pulse: a fixed dark panel, never a system-appearance window.
struct DesktopWidgetView: View {
    @ObservedObject var model: AppModel

    init(model: AppModel) { self.model = model }

    private var threshold: Double { model.settings.lowReserveThreshold }
    private var now: Date { model.now }
    private var cards: [DesktopCard] { model.desktopCards }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if cards.isEmpty {
                empty
            } else {
                grid
            }
            footer
        }
        .padding(16)
        .frame(width: 340)
        .background(background)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Design.locale)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI CAPACITY")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Design.Pulse.eyebrow)
                Text("Model Pulse")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Design.Pulse.text)
            }
            Spacer(minLength: 0)
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button { model.refresh(force: true, reason: "desktop") } label: {
            Group {
                if model.isRefreshing {
                    ProgressView().controlSize(.small).tint(Design.Pulse.button)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 31, height: 31)
            .foregroundStyle(Design.Pulse.button)
            .background(Circle().fill(Color.white.opacity(0.055)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isConfigured || model.isRefreshing)
        .help("Refresh now")
        .accessibilityLabel("Refresh now")
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
            ForEach(cards) { card in
                switch card {
                case .pool(let pool):
                    PulsePoolCard(pool: pool,
                                  members: Pool.members(model.snapshot, key: pool.key, now: now,
                                                        staleLimit: model.settings.staleLimit),
                                  threshold: threshold)
                case .status(let status):
                    PulseStatusCard(status: status)
                }
            }
        }
    }

    private var empty: some View {
        Text(model.isConfigured ? "No pools yet" : "No proxy yet")
            .font(.system(size: 11))
            .foregroundStyle(Design.Pulse.detail)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Circle().fill(footerColor).frame(width: 5, height: 5)
                .shadow(color: footerColor.opacity(0.8), radius: 4)
            Text(footerText)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Design.Pulse.footer)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(ageText)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Design.Pulse.age)
                .lineLimit(1)
        }
        .padding(.horizontal, 3)
    }

    private var footerText: String {
        if !model.isConfigured { return "NO PROXY" }
        if !model.isOnline { return "OFFLINE" }
        let stale = staleProxies
        return stale == 1 ? "1 PROXY STALE" : stale > 0 ? "\(stale) PROXIES STALE" : "ALL PROXIES CONNECTED"
    }

    private var footerColor: Color {
        if !model.isConfigured { return Design.Pulse.unknown }
        if !model.isOnline { return Design.Level.critical.color }
        return staleProxies > 0 ? Design.Level.low.color : Design.Level.good.color
    }

    private var ageText: String {
        guard model.snapshot.fetchedAt > .distantPast else { return "never" }
        return Design.relative(model.snapshot.fetchedAt, now: now)
    }

    private var staleProxies: Int {
        let enabled = model.settings.proxies.filter(\.isEnabled)
        let limit = max(120, model.settings.clampedRefreshInterval * 1.5)
        return enabled.filter { config in
            guard let proxy = model.snapshot.proxies.first(where: { $0.id == config.id }) else { return true }
            return !proxy.health.isOK || now.timeIntervalSince(proxy.fetchedAt) > limit
        }.count
    }

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Design.Pulse.panelTop.opacity(0.97), Design.Pulse.panelBottom.opacity(0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RadialGradient(colors: [Design.Pulse.glow.opacity(0.12), .clear], center: .topTrailing,
                           startRadius: 0, endRadius: 220)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
        }
    }
}

// MARK: Cards

struct PulsePoolCard: View {
    let pool: PoolSummary
    let members: [PoolMember]
    let threshold: Double

    private var accent: Color { Design.accent(for: pool.familyProvider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ProviderBadge(pool.familyProvider, size: 20)
                Text(pool.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(Design.Pulse.name)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Circle().fill(accent).frame(width: 5, height: 5)
                    .shadow(color: accent.opacity(0.8), radius: 4)
            }
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(levelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 13)
            detailText
                .padding(.top, 7)
            meter.padding(.top, 10)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Circle().fill(accent.opacity(0.18)).frame(width: 72, height: 72).blur(radius: 18)
                .offset(x: 30, y: -40)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pool.title), \(value), \(detail)")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.025)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var value: String {
        guard let reserve = pool.reserve else { return "—" }
        return Design.percent(reserve)
    }

    private var levelColor: Color {
        guard let reserve = pool.reserve else { return Design.Pulse.unknown }
        return Design.levelColor(reserve, threshold: threshold)
    }

    private var detail: String {
        [planLabel, "\(pool.usable)/\(pool.members) usable"].compactMap { $0 }.joined(separator: " · ")
    }

    /// The plan may truncate, but the usable count never does.
    private var detailText: some View {
        HStack(spacing: 0) {
            if let planLabel {
                Text(planLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(" · ")
            }
            Text("\(pool.usable)/\(pool.members) usable")
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 9))
        .foregroundStyle(Design.Pulse.detail)
    }

    /// Codex's tier, else the distinct plans of the members: "Free", "AI Plus + Starter".
    private var planLabel: String? {
        if !pool.key.tier.isEmpty {
            return pool.key.tier.prefix(1).uppercased() + String(pool.key.tier.dropFirst())
        }
        let plans = Set(members.compactMap(\.plan)).sorted()
        return plans.isEmpty ? nil : plans.joined(separator: " + ")
    }

    @ViewBuilder private var meter: some View {
        if !members.isEmpty && members.count <= 3 {
            HStack(spacing: 3) {
                ForEach(members) { member in
                    CapsuleBar(member.value,
                               color: member.value.map { Design.levelColor($0, threshold: threshold) }
                                   ?? Color.white.opacity(0.18),
                               height: 3)
                }
            }
        } else {
            CapsuleBar(pool.reserve, color: Design.levelColor(pool.reserve, threshold: threshold), height: 3)
        }
    }
}

struct PulseStatusCard: View {
    let status: DesktopStatusCard

    private var accent: Color { Design.accent(for: status.provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ProviderBadge(status.provider, size: 20)
                Text(status.name.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(Design.Pulse.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Circle().fill(accent).frame(width: 5, height: 5)
                    .shadow(color: accent.opacity(0.8), radius: 4)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(levelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 14)
            Text(status.detail)
                .font(.system(size: 9))
                .foregroundStyle(Design.Pulse.detail)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 7)
            PulseIdleMeter(color: accent).padding(.top, 10)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Circle().fill(accent.opacity(0.18)).frame(width: 72, height: 72).blur(radius: 18)
                .offset(x: 30, y: -40)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .opacity(status.state == .off ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.name), \(value), \(status.detail)")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.025)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var value: String {
        switch status.state {
        case .live: "LIVE"
        case .check: "CHECK"
        case .off: "OFF"
        }
    }

    private var levelColor: Color {
        switch status.state {
        case .live: Design.Level.good.color
        case .check: Design.Level.low.color
        case .off: Design.Pulse.unknown
        }
    }
}

/// The dashed idle meter a status card keeps from the old Übersicht widget.
private struct PulseIdleMeter: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1.5))
                path.addLine(to: CGPoint(x: geo.size.width, y: 1.5))
            }
            .stroke(color.opacity(0.32), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 4]))
        }
        .frame(height: 3)
    }
}
