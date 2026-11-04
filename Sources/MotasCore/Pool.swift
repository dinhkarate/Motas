import Foundation

/// Identifies a pool: the accounts of one provider and tier that share a group of windows.
public struct PoolKey: Codable, Sendable, Hashable {
    public var provider: Provider
    /// Codex plan class ("free" also covers Go); "" for every other provider.
    public var tier: String
    /// A `QuotaGroups` id, or "" when the pool covers whole accounts.
    public var group: String

    public init(provider: Provider, tier: String, group: String) {
        self.provider = provider
        self.tier = tier
        self.group = group
    }

    /// "provider|tier|group": what the menu-bar pin and history store.
    public var id: String { "\(provider.rawValue)|\(tier)|\(group)" }
}

/// One pool across every proxy. See `Pool.summarize`.
public struct PoolSummary: Codable, Sendable, Hashable, Identifiable {
    /// Members' windows of one period, so CPA and 9Router accounts merge.
    public struct Lane: Codable, Sendable, Hashable, Identifiable {
        /// The window period, or "models" for members read per model only.
        public var id: String
        public var label: String
        /// Mean over the members reporting this lane.
        public var mean: Double
        public var count: Int
    }

    public var key: PoolKey
    public var id: String { key.id }
    /// Short: "Codex", "Gemini", "Codex Plus", "Gemini CLI Pro".
    public var title: String
    /// Long: "Codex · Free", "Antigravity · Gemini".
    public var displayName: String
    /// Mean value over the measured members; nil when none is measured.
    public var reserve: Double?
    /// measured + unknown + rejected.
    public var members = 0
    public var measured = 0
    /// Measured above 0.5 %, and not cooling down.
    public var usable = 0
    /// Measured at 0.5 % or less.
    public var exhausted = 0
    /// Members whose figures are too old, or have all reset since they were read.
    public var unknown = 0
    /// Members whose credential was rejected; they have no value.
    public var rejected = 0
    /// Measured members read before their proxy's latest refresh.
    public var stale = 0
    /// Measured above 0.5 % but cooling down.
    public var coolingDown = 0
    public var lanes: [Lane] = []
    /// Earliest instant an exhausted or cooling member comes back.
    public var nextRecoveryAt: Date?
    /// Earliest reset of any window that counts and is below 100 %.
    public var nextResetAt: Date?
    /// Reset credits of the exhausted members.
    public var resetCredits = 0
    /// The window period the reserve was read from; nil = the lowest window.
    public var basis: String?
}

/// One account of a pool, for surfaces that need per-account detail: the
/// desktop widget's thin meters and plan names.
public struct PoolMember: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var plan: String?
    /// nil when the account is unknown or rejected.
    public var value: Double?
}

/// Pool math. Everything here is a pure function of a snapshot.
public enum Pool {
    /// At or below this, an account is out.
    public static let exhaustedThreshold = 0.005

    static let providerOrder = ["codex", "claude", "antigravity", "gemini-cli"]
    static let tierOrder = ["free", "plus", "pro", "team", "business", "enterprise", "edu"]
    static let laneOrder = ["primary", "secondary", "5h", "daily", "weekly"]

    /// Every pool in the fixed order. Accounts of every proxy count, whatever
    /// its health; disabled and unmetered accounts never do. Per provider and
    /// tier there is one pool when any member has a `.limit` window without a
    /// group; otherwise one per group of `.limit` or `.model` windows (image
    /// and other never pool). A provider that never had windows has no pool.
    /// `bases` maps a pool id to the window period its reserve is read from.
    public static func summarize(_ snapshot: Snapshot, now: Date, staleLimit: TimeInterval,
                                 bases: [String: String] = [:]) -> [PoolSummary] {
        var byTier: [PoolKey: [Candidate]] = [:]
        for proxy in snapshot.proxies {
            for account in proxy.accounts where account.state == .active {
                if case .unavailable = account.quota { continue }
                let key = PoolKey(provider: account.provider, tier: tier(account.provider, plan: account.plan), group: "")
                byTier[key, default: []].append(Candidate(account: account, fetchedAt: proxy.fetchedAt))
            }
        }
        var keys: [PoolKey] = []
        for (key, candidates) in byTier {
            let windows = candidates.flatMap(\.account.quota.windows)
            if windows.contains(where: { $0.role == .limit && $0.group == nil }) {
                keys.append(key)
            } else {
                let groups = Set(windows.filter { $0.role != .detail }.compactMap(\.group)).subtracting(["image", "other"])
                keys += groups.map { PoolKey(provider: key.provider, tier: key.tier, group: $0) }
            }
        }
        keys.sort(by: precedes)
        return keys.map { key in
            let candidates = byTier[PoolKey(provider: key.provider, tier: key.tier, group: "")] ?? []
            let tiers = Set(keys.filter { $0.provider == key.provider }.map(\.tier)).count
            return summary(key, candidates, tiers: tiers, now: now, staleLimit: staleLimit, basis: bases[key.id])
        }
    }

    /// Codex only, from the resolved plan: Free and Go share one limit regime,
    /// other plans stay apart. Other providers' plans are not comparable across proxies.
    public static func tier(_ provider: Provider, plan: String?) -> String {
        guard provider == .codex, let plan = plan?.lowercased() else { return "" }
        return plan == "go" ? "free" : plan
    }

    private struct Candidate {
        var account: AccountSnapshot
        /// Its proxy's latest refresh.
        var fetchedAt: Date
    }

    /// One account in one pool: L (`.limit` windows) and M (`.model` windows)
    /// of the pool's group, without the windows that reset since the read.
    private struct Member {
        var account: AccountSnapshot
        var fetchedAt: Date
        var rejected = false
        var limits: [QuotaWindow] = []
        var models: [QuotaWindow] = []
        /// The chosen window period; nil = every limit window counts.
        var basis: String?

        /// min(min(L), max(M)): a family is out only when every text model is.
        /// With a basis, L is the basis windows when the member has any.
        /// nil (unknown) when the figures are older than `staleLimit` or all reset.
        func value(now: Date, staleLimit: TimeInterval) -> Double? {
            guard !rejected, let observed = account.quotaObservedAt, now.timeIntervalSince(observed) <= staleLimit else { return nil }
            let chosen = basis.map { b in limits.filter { $0.period == b } } ?? []
            let counted = chosen.isEmpty ? limits : chosen
            return [counted.map(\.remainingFraction).min(), models.map(\.remainingFraction).max()].compactMap { $0 }.min()
        }

        /// When an exhausted member is back: every out limit window must reset,
        /// and when all models are out, the first of them.
        var recovery: Date? {
            var dates = [limits.filter { $0.remainingFraction <= exhaustedThreshold }.compactMap(\.resetsAt).max()]
            if let best = models.map(\.remainingFraction).max(), best <= exhaustedThreshold {
                dates.append(models.compactMap(\.resetsAt).min())
            }
            return dates.compactMap { $0 }.max()
        }
    }

    /// nil when the account is not a member: it never had windows for the
    /// group. Rejected accounts have no windows and belong to every pool of
    /// their provider and tier.
    private static func member(_ candidate: Candidate, in key: PoolKey, now: Date, basis: String? = nil) -> Member? {
        var member = Member(account: candidate.account, fetchedAt: candidate.fetchedAt, basis: basis)
        if case .rejected = candidate.account.quota {
            member.rejected = true
            return member
        }
        let windows = candidate.account.quota.windows
        let group = key.group.isEmpty ? nil : key.group
        member.limits = windows.filter { $0.role == .limit && ($0.group == group || $0.group == nil) }
        member.models = group == nil ? [] : windows.filter { $0.role == .model && $0.group == group }
        guard !member.limits.isEmpty || !member.models.isEmpty else { return nil }
        if let observed = candidate.account.quotaObservedAt {
            let current = { (w: QuotaWindow) in w.resetsAt.map { !(observed < $0 && $0 <= now) } ?? true }
            member.limits = member.limits.filter(current)
            member.models = member.models.filter(current)
        }
        return member
    }

    /// The same account on several proxies counts once: the newest read wins.
    private static func dedupe(_ members: [Member]) -> [Member] {
        var kept: [Member] = []
        var index: [String: Int] = [:]
        for member in members {
            guard let identity = member.account.identity else {
                kept.append(member)
                continue
            }
            if let i = index[identity] {
                if (member.account.quotaObservedAt ?? .distantPast) > (kept[i].account.quotaObservedAt ?? .distantPast) { kept[i] = member }
            } else {
                index[identity] = kept.count
                kept.append(member)
            }
        }
        return kept
    }

    private static func summary(_ key: PoolKey, _ candidates: [Candidate], tiers: Int, now: Date, staleLimit: TimeInterval,
                                basis: String?) -> PoolSummary {
        let (title, displayName) = names(key, hint: candidates.lazy.compactMap(\.account.displayHint).first, tiers: tiers)
        var pool = PoolSummary(key: key, title: title, displayName: displayName)
        pool.basis = basis
        var total = 0.0
        var lanes: [String: (sum: Double, count: Int, duration: TimeInterval?)] = [:]
        func lane(_ id: String, _ value: Double, duration: TimeInterval?) {
            let lane = lanes[id] ?? (0, 0, nil)
            lanes[id] = (lane.sum + value, lane.count + 1, lane.duration ?? duration)
        }
        for member in dedupe(candidates.compactMap { member($0, in: key, now: now, basis: basis) }) {
            pool.members += 1
            if member.rejected {
                pool.rejected += 1
                continue
            }
            guard let value = member.value(now: now, staleLimit: staleLimit) else {
                pool.unknown += 1
                continue
            }
            let account = member.account
            pool.measured += 1
            total += value
            if let observed = account.quotaObservedAt, observed < member.fetchedAt { pool.stale += 1 }
            let cooldown = account.cooldownUntil.flatMap { $0 > now ? $0 : nil }
            var back = cooldown
            if value <= exhaustedThreshold {
                pool.exhausted += 1
                pool.resetCredits += account.extras.resetCredits ?? 0
                // Back when its windows recover, not before a cooldown ends; unknown when they do not say.
                back = member.recovery.map { max($0, cooldown ?? $0) }
            } else if cooldown != nil || account.coolingDown {
                pool.coolingDown += 1
            } else {
                pool.usable += 1
            }
            if let back { pool.nextRecoveryAt = min(pool.nextRecoveryAt ?? back, back) }
            if let reset = (member.limits + member.models).filter({ $0.remainingFraction < 1 }).compactMap(\.resetsAt).min() {
                pool.nextResetAt = min(pool.nextResetAt ?? reset, reset)
            }
            if member.limits.isEmpty {
                lane("models", value, duration: nil)
            }
            for (period, windows) in Dictionary(grouping: member.limits.filter { $0.period != nil }, by: { $0.period ?? "" }) {
                lane(period, windows.map(\.remainingFraction).min() ?? 0, duration: windows.lazy.compactMap(\.duration).first)
            }
        }
        if pool.measured > 0 { pool.reserve = total / Double(pool.measured) }
        pool.lanes = lanes
            .map { id, lane in
                PoolSummary.Lane(id: id, label: id == "models" ? "Models" : QuotaGroups.periodLabel(id, duration: lane.duration),
                                 mean: lane.sum / Double(lane.count), count: lane.count)
            }
            .sorted { rank($0.id, laneOrder, last: "models") < rank($1.id, laneOrder, last: "models") }
        return pool
    }

    /// The pool's members, deduped and in label order. A pool card can draw one
    /// meter per member only when there are at most three of them.
    public static func members(_ snapshot: Snapshot, key: PoolKey, now: Date,
                               staleLimit: TimeInterval, basis: String? = nil) -> [PoolMember] {
        var candidates: [Candidate] = []
        for proxy in snapshot.proxies {
            for account in proxy.accounts where account.state == .active && account.provider == key.provider
                && tier(account.provider, plan: account.plan) == key.tier {
                candidates.append(Candidate(account: account, fetchedAt: proxy.fetchedAt))
            }
        }
        return dedupe(candidates.compactMap { member($0, in: key, now: now, basis: basis) })
            .map { member in
                PoolMember(id: member.account.id, label: member.account.label, plan: member.account.plan,
                           value: member.value(now: now, staleLimit: staleLimit))
            }
            .sorted { ($0.label, $0.id) < ($1.label, $1.id) }
    }

    /// Antigravity pools are titled by their family ("Gemini"); others by the
    /// provider, plus the tier when the provider has several, plus the group.
    private static func names(_ key: PoolKey, hint: String?, tiers: Int) -> (title: String, displayName: String) {
        let provider = key.provider.displayName(hint: hint)
        let tier = key.tier.isEmpty ? nil : key.tier.prefix(1).uppercased() + key.tier.dropFirst()
        let group = key.group.isEmpty ? nil : QuotaGroups.label(provider: key.provider, group: key.group)
        let title: String
        if key.provider == .antigravity, let group {
            title = group
        } else {
            title = [provider, tiers > 1 ? tier : nil, group].compactMap { $0 }.joined(separator: " ")
        }
        return (title, [provider, tier, group].compactMap { $0 }.joined(separator: " · "))
    }

    /// The fixed order: codex, claude, antigravity, gemini-cli, then alphabetical. Never by value.
    public static func precedes(_ a: Provider, _ b: Provider) -> Bool {
        rank(a.rawValue, providerOrder) < rank(b.rawValue, providerOrder)
    }

    /// Provider; tier (free, plus, pro, team, business, enterprise, edu, others
    /// alphabetical, then none); group in `QuotaGroups` order.
    static func precedes(_ a: PoolKey, _ b: PoolKey) -> Bool {
        if a.provider != b.provider { return precedes(a.provider, b.provider) }
        if a.tier != b.tier { return rank(a.tier, tierOrder, last: "") < rank(b.tier, tierOrder, last: "") }
        return QuotaGroups.precedes(a.group, b.group)
    }

    /// Position in `order`, then alphabetical; `last` sorts after everything.
    private static func rank(_ value: String, _ order: [String], last: String? = nil) -> (Int, String) {
        value == last ? (order.count + 1, value) : (order.firstIndex(of: value) ?? order.count, value)
    }

    // MARK: Headline

    /// The menu-bar pool: the pinned one when present; a pin that is missing
    /// falls back to its provider's pool with the most members; otherwise automatic.
    public static func headline(_ pools: [PoolSummary], pinned: String?) -> PoolSummary? {
        if let pinned {
            if let pool = pools.first(where: { $0.id == pinned }) { return pool }
            let provider = String(pinned.prefix { $0 != "|" })
            if let pool = pools.filter({ $0.key.provider.rawValue == provider }).max(by: { $0.members < $1.members }) { return pool }
        }
        return automatic(pools)
    }

    /// The menu-bar gauge: the headline, then the next pool by the automatic rule.
    public static func gauge(_ pools: [PoolSummary], pinned: String?) -> [PoolSummary] {
        guard let headline = headline(pools, pinned: pinned) else { return [] }
        return [headline] + [automatic(pools.filter { $0.id != headline.id })].compactMap { $0 }
    }

    /// The lowest reserve among pools with at least two measured accounts;
    /// else the most measured accounts, then the lower reserve, then the fixed order.
    static func automatic(_ pools: [PoolSummary]) -> PoolSummary? {
        if let pool = pools.filter({ $0.measured >= 2 }).min(by: { ($0.reserve ?? 1) < ($1.reserve ?? 1) }) { return pool }
        return pools.min { a, b in
            a.measured != b.measured ? a.measured > b.measured : (a.reserve ?? .infinity) < (b.reserve ?? .infinity)
        }
    }

    // MARK: Accounts outside pools

    /// One proxy's unmetered accounts of one provider.
    public struct UnmeteredGroup: Sendable, Hashable, Identifiable {
        public var provider: Provider
        /// `Provider.displayName(hint:)`: "OpenRouter", "quotax-oss".
        public var name: String
        public var count: Int
        /// Each message, with how many of the accounts report it.
        public var messages: [String: Int]
        /// Qoder reports its quota exceeded, without figures.
        public var quotaExceeded: Bool
        public var id: Provider { provider }
    }

    /// The proxy's active accounts that report no figures by design, per provider, in the fixed order.
    public static func unmetered(_ proxy: ProxySnapshot) -> [UnmeteredGroup] {
        var groups: [Provider: UnmeteredGroup] = [:]
        for account in proxy.accounts where account.state == .active {
            guard case .unavailable(let message) = account.quota else { continue }
            var group = groups[account.provider] ?? UnmeteredGroup(
                provider: account.provider, name: account.provider.displayName(hint: account.displayHint), count: 0, messages: [:],
                quotaExceeded: false)
            group.count += 1
            group.messages[message, default: 0] += 1
            if account.extras.quotaExceeded == true { group.quotaExceeded = true }
            groups[account.provider] = group
        }
        return groups.values.sorted { precedes($0.provider, $1.provider) }
    }

    /// The proxy's disabled accounts.
    public static func disabled(_ proxy: ProxySnapshot) -> [AccountSnapshot] {
        proxy.accounts.filter { $0.state == .disabled }
    }
}
