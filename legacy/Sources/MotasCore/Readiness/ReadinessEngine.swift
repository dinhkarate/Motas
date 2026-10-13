import Foundation

public struct ReadinessPolicy: Sendable, Equatable {
    public let cautionRemainingFraction: Double
    public let criticalRemainingFraction: Double

    public init(
        cautionRemainingFraction: Double = 0.20,
        criticalRemainingFraction: Double = 0.05
    ) {
        self.cautionRemainingFraction = min(max(cautionRemainingFraction, 0), 1)
        self.criticalRemainingFraction = min(
            max(criticalRemainingFraction, 0),
            self.cautionRemainingFraction
        )
    }
}

public struct ReadinessEngine: Sendable {
    public let policy: ReadinessPolicy

    public init(policy: ReadinessPolicy = .init()) {
        self.policy = policy
    }

    public func evaluate(
        providers: [ProviderStatus],
        proxies: [ProxyStatus],
        at date: Date = Date()
    ) -> ReadinessAssessment {
        let primaryProviders = providers.filter { $0.role == .primary }
        let fallbackProviders = providers.filter { $0.role == .fallback }
        let primaryProxies = proxies.filter { $0.role == .primary }
        let fallbackProxies = proxies.filter { $0.role == .fallback }

        guard !primaryProviders.isEmpty || !primaryProxies.isEmpty else {
            return assessment(
                .unknown,
                title: "Readiness unknown",
                explanation: "Add a primary provider or proxy to evaluate your AI stack.",
                at: date
            )
        }

        if let proxy = requiredProxyOutage(in: primaryProxies) {
            return assessment(
                .proxyDown,
                title: "Proxy unavailable",
                explanation: "\(proxy.name) could not be reached. Check that the local service is running.",
                sourceID: proxy.id,
                at: date
            )
        }

        let usablePrimaryProviders = primaryProviders.filter(isPositivelyUsable)
        let usablePrimaryProxies = primaryProxies.filter(isPositivelyUsable)
        let usablePrimaryExists = !usablePrimaryProviders.isEmpty || !usablePrimaryProxies.isEmpty

        let verifiedFallbackProviders = fallbackProviders.filter(isPositivelyUsable)
        let verifiedFallbackProxies = fallbackProxies.filter(isPositivelyUsable)
        let routeFallbacks = proxies.filter(hasVerifiedFallbackRoute)
        let fallbackExists = !verifiedFallbackProviders.isEmpty
            || !verifiedFallbackProxies.isEmpty
            || !routeFallbacks.isEmpty

        let failedPrimaryProviders = primaryProviders.filter(isKnownFailed)
        let failedPrimaryProxies = primaryProxies.filter(isKnownFailed)
        let knownPrimaryFailureExists = !failedPrimaryProviders.isEmpty || !failedPrimaryProxies.isEmpty

        if !usablePrimaryExists && !fallbackExists {
            if knownPrimaryFailureExists {
                let source = sortedPrimaryFailure(
                    providers: failedPrimaryProviders,
                    proxies: failedPrimaryProxies
                )
                return assessment(
                    .blocked,
                    title: "AI stack blocked",
                    explanation: "\(source.name) is unavailable and no usable fallback was verified.",
                    sourceID: source.id,
                    at: date
                )
            }

            return assessment(
                .unknown,
                title: "Readiness unknown",
                explanation: unknownExplanation(providers: primaryProviders, proxies: primaryProxies),
                sourceID: firstStableID(providers: primaryProviders, proxies: primaryProxies),
                at: date
            )
        }

        if let activeFallback = (
            proxies
                .filter { proxy in
                    proxy.role != .informational && isActiveFallbackTier(proxy)
                }
                .sorted(by: stableProxyOrder)
        ).first {
            let tier = activeFallback.route?.activeTier.displayName ?? "fallback"
            return assessment(
                .fallback,
                title: "Running on fallback",
                explanation: "\(activeFallback.name) is currently using its \(tier) tier.",
                sourceID: activeFallback.id,
                at: date
            )
        }

        if let criticalSource = criticalPrimarySource(
            providers: primaryProviders,
            proxies: primaryProxies
        ), fallbackExists {
            return assessment(
                .fallback,
                title: "Fallback recommended",
                explanation: "\(criticalSource.name) is critically low. A fallback path is ready.",
                sourceID: criticalSource.id,
                at: date
            )
        }

        if knownPrimaryFailureExists && fallbackExists {
            let source = sortedPrimaryFailure(
                providers: failedPrimaryProviders,
                proxies: failedPrimaryProxies
            )
            return assessment(
                .fallback,
                title: "Running on fallback",
                explanation: "\(source.name) is unavailable. A fallback path is ready.",
                sourceID: source.id,
                at: date
            )
        }

        if let risk = strongestCaution(providers: primaryProviders, proxies: primaryProxies) {
            return assessment(
                .caution,
                title: risk.title,
                explanation: risk.explanation,
                sourceID: risk.sourceID,
                at: date
            )
        }

        guard hasFreshVerifiedPrimary(providers: primaryProviders, proxies: primaryProxies) else {
            return assessment(
                .unknown,
                title: "Readiness unknown",
                explanation: unknownExplanation(providers: primaryProviders, proxies: primaryProxies),
                sourceID: firstStableID(providers: primaryProviders, proxies: primaryProxies),
                at: date
            )
        }

        let names = (usablePrimaryProviders.map(\.name) + usablePrimaryProxies.map(\.name))
            .sorted()
        let explanation = names.isEmpty
            ? "Your configured AI route is available."
            : "\(joinedNames(names)) are available."

        return assessment(
            .ready,
            title: "AI stack ready",
            explanation: explanation,
            sourceID: firstStableID(
                providers: usablePrimaryProviders,
                proxies: usablePrimaryProxies
            ),
            at: date
        )
    }
}

private extension ReadinessEngine {
    struct SourceIdentity {
        let id: String
        let name: String
    }

    struct CautionReason {
        let title: String
        let explanation: String
        let sourceID: String
        let severity: Double
    }

    func assessment(
        _ state: ReadinessState,
        title: String,
        explanation: String,
        sourceID: String? = nil,
        at date: Date
    ) -> ReadinessAssessment {
        ReadinessAssessment(
            state: state,
            title: title,
            explanation: explanation,
            primarySourceID: sourceID,
            evaluatedAt: date
        )
    }

    func isPositivelyUsable(_ provider: ProviderStatus) -> Bool {
        guard provider.observation.quality == .fresh || provider.observation.quality == .partial else {
            return false
        }
        guard provider.health == .healthy || provider.health == .degraded else {
            return false
        }
        return !hasExhaustedEnforcedWindow(provider.quotaWindows)
    }

    func isPositivelyUsable(_ proxy: ProxyStatus) -> Bool {
        guard proxy.observation.quality == .fresh || proxy.observation.quality == .partial else {
            return false
        }
        guard proxy.health == .healthy || proxy.health == .degraded else {
            return false
        }
        return !hasExhaustedEnforcedWindow(proxy.quotaWindows)
    }

    func isKnownFailed(_ provider: ProviderStatus) -> Bool {
        provider.health == .unreachable
            || (hasCurrentData(provider.observation) && (
                provider.health == .exhausted
                    || hasExhaustedEnforcedWindow(provider.quotaWindows)
            ))
    }

    func isKnownFailed(_ proxy: ProxyStatus) -> Bool {
        proxy.health == .unreachable
            || (hasCurrentData(proxy.observation) && (
                proxy.health == .exhausted
                    || hasExhaustedEnforcedWindow(proxy.quotaWindows)
            ))
    }

    func hasCurrentData(_ observation: Observation) -> Bool {
        observation.quality == .fresh || observation.quality == .partial
    }

    func hasExhaustedEnforcedWindow(_ windows: [QuotaWindow]) -> Bool {
        windows.contains { window in
            window.isEnforced && window.remainingFraction.map { $0 <= 0 } == true
        }
    }

    func minimumRemaining(_ windows: [QuotaWindow]) -> (window: QuotaWindow, value: Double)? {
        windows
            .filter(\.isEnforced)
            .compactMap { window -> (QuotaWindow, Double)? in
                guard let remaining = window.remainingFraction else { return nil }
                return (window, remaining)
            }
            .min { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
                return lhs.1 < rhs.1
            }
    }

    func requiredProxyOutage(in primaryProxies: [ProxyStatus]) -> ProxyStatus? {
        let requiredProxies = primaryProxies.filter(\.isRequiredRoute)
        guard !requiredProxies.isEmpty else { return nil }
        guard requiredProxies.allSatisfy({ $0.health == .unreachable }) else { return nil }
        return requiredProxies.sorted(by: stableProxyOrder).first
    }

    func hasVerifiedFallbackRoute(_ proxy: ProxyStatus) -> Bool {
        guard isPositivelyUsable(proxy) else { return false }
        return proxy.route?.fallbackAvailable == true || isActiveFallbackTier(proxy)
    }

    func isActiveFallbackTier(_ proxy: ProxyStatus) -> Bool {
        guard isPositivelyUsable(proxy), let route = proxy.route else { return false }
        switch route.activeTier {
        case .economical, .free:
            return true
        case .custom:
            return route.primaryAvailable == false && route.fallbackAvailable == true
        case .primary, .subscription, .unknown:
            return false
        }
    }

    func hasFreshVerifiedPrimary(
        providers: [ProviderStatus],
        proxies: [ProxyStatus]
    ) -> Bool {
        providers.contains { $0.observation.quality == .fresh && isPositivelyUsable($0) }
            || proxies.contains { $0.observation.quality == .fresh && isPositivelyUsable($0) }
    }

    func criticalPrimarySource(
        providers: [ProviderStatus],
        proxies: [ProxyStatus]
    ) -> SourceIdentity? {
        let providerSources = providers.compactMap { provider -> (SourceIdentity, Double)? in
            guard let remaining = minimumRemaining(provider.quotaWindows)?.value,
                  remaining > 0,
                  remaining <= policy.criticalRemainingFraction
            else {
                return nil
            }
            return (SourceIdentity(id: provider.id, name: provider.name), remaining)
        }
        let proxySources = proxies.compactMap { proxy -> (SourceIdentity, Double)? in
            guard let remaining = minimumRemaining(proxy.quotaWindows)?.value,
                  remaining > 0,
                  remaining <= policy.criticalRemainingFraction
            else {
                return nil
            }
            return (SourceIdentity(id: proxy.id, name: proxy.name), remaining)
        }
        return (providerSources + proxySources)
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
                return lhs.1 < rhs.1
            }
            .first?.0
    }

    func strongestCaution(
        providers: [ProviderStatus],
        proxies: [ProxyStatus]
    ) -> CautionReason? {
        var reasons: [CautionReason] = []

        for provider in providers {
            if let minimum = minimumRemaining(provider.quotaWindows),
               minimum.value <= policy.cautionRemainingFraction,
               minimum.value > 0
            {
                let percent = Int((minimum.value * 100).rounded())
                reasons.append(
                    CautionReason(
                        title: "Quota running low",
                        explanation: "\(provider.name)'s \(minimum.window.name) window has \(percent)% remaining.",
                        sourceID: provider.id,
                        severity: minimum.value
                    )
                )
            }
            if provider.health == .degraded {
                reasons.append(
                    CautionReason(
                        title: "Provider degraded",
                        explanation: "\(provider.name) is available but degraded.",
                        sourceID: provider.id,
                        severity: 0.30
                    )
                )
            }
            if provider.observation.quality == .partial && isPositivelyUsable(provider) {
                reasons.append(
                    CautionReason(
                        title: "Provider data partial",
                        explanation: "\(provider.name) is usable, but not all quota details could be verified.",
                        sourceID: provider.id,
                        severity: 0.40
                    )
                )
            }
        }

        for proxy in proxies {
            if let minimum = minimumRemaining(proxy.quotaWindows),
               minimum.value <= policy.cautionRemainingFraction,
               minimum.value > 0
            {
                let percent = Int((minimum.value * 100).rounded())
                reasons.append(
                    CautionReason(
                        title: "Proxy quota running low",
                        explanation: "\(proxy.name)'s \(minimum.window.name) window has \(percent)% remaining.",
                        sourceID: proxy.id,
                        severity: minimum.value
                    )
                )
            }
            if proxy.health == .degraded {
                reasons.append(
                    CautionReason(
                        title: "Proxy degraded",
                        explanation: "\(proxy.name) is reachable but degraded.",
                        sourceID: proxy.id,
                        severity: 0.30
                    )
                )
            }
            if proxy.observation.quality == .partial && isPositivelyUsable(proxy) {
                reasons.append(
                    CautionReason(
                        title: "Proxy data partial",
                        explanation: "\(proxy.name) is reachable, but account or route details are incomplete.",
                        sourceID: proxy.id,
                        severity: 0.40
                    )
                )
            }
            if proxy.route?.fallbackAvailable == false && isPositivelyUsable(proxy) {
                reasons.append(
                    CautionReason(
                        title: "Fallback unavailable",
                        explanation: "\(proxy.name) is available, but no fallback route is currently ready.",
                        sourceID: proxy.id,
                        severity: 0.25
                    )
                )
            }
        }

        return reasons.sorted { lhs, rhs in
            if lhs.severity == rhs.severity { return lhs.sourceID < rhs.sourceID }
            return lhs.severity < rhs.severity
        }.first
    }

    func sortedPrimaryFailure(
        providers: [ProviderStatus],
        proxies: [ProxyStatus]
    ) -> SourceIdentity {
        let all = providers.map { SourceIdentity(id: $0.id, name: $0.name) }
            + proxies.map { SourceIdentity(id: $0.id, name: $0.name) }
        return all.sorted { $0.id < $1.id }.first
            ?? SourceIdentity(id: "unknown", name: "The primary route")
    }

    func unknownExplanation(
        providers: [ProviderStatus],
        proxies: [ProxyStatus]
    ) -> String {
        let sources: [(id: String, name: String, health: OperationalHealth, quality: DataQuality)] =
            providers.map { ($0.id, $0.name, $0.health, $0.observation.quality) }
            + proxies.map { ($0.id, $0.name, $0.health, $0.observation.quality) }

        guard let source = sources.sorted(by: { $0.id < $1.id }).first else {
            return "No primary source is configured."
        }

        switch source.health {
        case .unauthorized:
            return "\(source.name) could not be monitored because authorization failed."
        case .unsupported:
            return "\(source.name) does not expose enough data to verify readiness."
        default:
            if source.quality == .stale {
                return "\(source.name)'s last known status is stale."
            }
            return "\(source.name)'s current readiness could not be verified."
        }
    }

    func firstStableID(
        providers: [ProviderStatus],
        proxies: [ProxyStatus]
    ) -> String? {
        (providers.map(\.id) + proxies.map(\.id)).sorted().first
    }

    func stableProxyOrder(_ lhs: ProxyStatus, _ rhs: ProxyStatus) -> Bool {
        lhs.id < rhs.id
    }

    func joinedNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Your configured AI route"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
    }
}

private extension RouteTier {
    var displayName: String {
        switch self {
        case .primary: "primary"
        case .subscription: "subscription"
        case .economical: "economical"
        case .free: "free"
        case .custom: "custom"
        case .unknown: "unknown"
        }
    }
}
