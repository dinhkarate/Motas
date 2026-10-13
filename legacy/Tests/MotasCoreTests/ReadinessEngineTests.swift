import Foundation
import Testing
@testable import MotasCore

private let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)

@Test("Empty widget fallback snapshot is unknown")
func emptyWidgetFallbackIsUnknown() {
    let snapshot = MockData.unknownSnapshot(at: fixedDate)

    #expect(snapshot.readiness.state == .unknown)
    #expect(snapshot.providers.isEmpty)
    #expect(snapshot.proxies.isEmpty)
}

@Test("Healthy fresh primary with comfortable quota is ready")
func readyWhenPrimaryIsHealthy() {
    let provider = MockData.claude(remaining: 0.80, at: fixedDate)

    let result = ReadinessEngine().evaluate(
        providers: [provider],
        proxies: [],
        at: fixedDate
    )

    #expect(result.state == .ready)
    #expect(result.primarySourceID == provider.id)
}

@Test("Caution threshold is inclusive")
func cautionAtThreshold() {
    let provider = MockData.claude(remaining: 0.20, at: fixedDate)

    let result = ReadinessEngine().evaluate(
        providers: [provider],
        proxies: [],
        at: fixedDate
    )

    #expect(result.state == .caution)
    #expect(result.explanation.contains("20%"))
}

@Test("Critically low primary with verified fallback recommends fallback")
func fallbackWhenPrimaryIsCritical() {
    let provider = MockData.claude(remaining: 0.04, at: fixedDate)
    let proxy = MockData.nineRouter(
        role: .fallback,
        health: .healthy,
        activeTier: .subscription,
        fallbackAvailable: true,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [provider],
        proxies: [proxy],
        at: fixedDate
    )

    #expect(result.state == .fallback)
    #expect(result.title == "Fallback recommended")
}

@Test("Exhausted primary with verified fallback is fallback")
func fallbackWhenPrimaryIsExhausted() {
    let provider = MockData.claude(remaining: 0, health: .exhausted, at: fixedDate)
    let proxy = MockData.nineRouter(
        role: .fallback,
        health: .healthy,
        activeTier: .economical,
        fallbackAvailable: true,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [provider],
        proxies: [proxy],
        at: fixedDate
    )

    #expect(result.state == .fallback)
}

@Test("Exhausted primary without fallback is blocked")
func blockedWithoutFallback() {
    let provider = MockData.claude(remaining: 0, health: .exhausted, at: fixedDate)

    let result = ReadinessEngine().evaluate(
        providers: [provider],
        proxies: [],
        at: fixedDate
    )

    #expect(result.state == .blocked)
}

@Test("Required primary proxy outage has highest precedence")
func requiredProxyOutage() {
    let provider = MockData.claude(remaining: 0.80, at: fixedDate)
    let proxy = MockData.nineRouter(
        health: .unreachable,
        isRequiredRoute: true,
        activeTier: .unknown,
        fallbackAvailable: nil,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [provider],
        proxies: [proxy],
        at: fixedDate
    )

    #expect(result.state == .proxyDown)
    #expect(result.primarySourceID == proxy.id)
}

@Test("Optional proxy outage does not hide healthy direct provider")
func optionalProxyOutage() {
    let provider = MockData.claude(remaining: 0.80, at: fixedDate)
    let proxy = MockData.nineRouter(
        role: .informational,
        health: .unreachable,
        isRequiredRoute: false,
        activeTier: .unknown,
        fallbackAvailable: nil,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [provider],
        proxies: [proxy],
        at: fixedDate
    )

    #expect(result.state == .ready)
}

@Test("Unauthorized monitoring is unknown, not proxy down")
func unauthorizedIsUnknown() {
    let proxy = MockData.nineRouter(
        health: .unauthorized,
        isRequiredRoute: true,
        activeTier: .unknown,
        fallbackAvailable: nil,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [],
        proxies: [proxy],
        at: fixedDate
    )

    #expect(result.state == .unknown)
    #expect(result.explanation.contains("authorization"))
}

@Test("Stale healthy primary cannot produce ready")
func stalePrimaryIsUnknown() {
    let provider = MockData.claude(
        remaining: 0.80,
        quality: .stale,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [provider],
        proxies: [],
        at: fixedDate
    )

    #expect(result.state == .unknown)
    #expect(result.explanation.contains("stale"))
}

@Test("Fresh partial primary is caution")
func partialPrimaryIsCaution() {
    let provider = MockData.claude(
        remaining: 0.80,
        quality: .partial,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [provider],
        proxies: [],
        at: fixedDate
    )

    #expect(result.state == .caution)
    #expect(result.explanation.contains("not all quota details"))
}

@Test("No primary source is unknown")
func noPrimaryIsUnknown() {
    let fallback = MockData.claude(
        remaining: 0.80,
        role: .fallback,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [fallback],
        proxies: [],
        at: fixedDate
    )

    #expect(result.state == .unknown)
}

@Test("Active economical proxy tier reports fallback")
func activeEconomicalTierIsFallback() {
    let proxy = MockData.nineRouter(
        health: .healthy,
        activeTier: .economical,
        fallbackAvailable: true,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [],
        proxies: [proxy],
        at: fixedDate
    )

    #expect(result.state == .fallback)
    #expect(result.explanation.contains("economical"))
}

@Test("Informational custom proxy route does not trigger fallback")
func informationalCustomProxyDoesNotTriggerFallback() {
    let primary = MockData.claude(remaining: 0.80, at: fixedDate)
    let informationalProxy = MockData.cliProxyAPI(
        health: .healthy,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [primary],
        proxies: [informationalProxy],
        at: fixedDate
    )

    #expect(result.state == .ready)
}

@Test("Informational exhausted source does not affect healthy primary")
func informationalSourceDoesNotAffectReadiness() {
    let primary = MockData.claude(remaining: 0.80, at: fixedDate)
    let informational = MockData.claude(
        remaining: 0,
        health: .exhausted,
        role: .informational,
        at: fixedDate
    )

    let result = ReadinessEngine().evaluate(
        providers: [primary, informational],
        proxies: [],
        at: fixedDate
    )

    #expect(result.state == .ready)
}

@Test("Quota remaining fraction is clamped")
func quotaFractionIsClamped() {
    let over = QuotaWindow(
        id: "over",
        name: "Over",
        unit: .percentage,
        remainingFraction: 1.5
    )
    let under = QuotaWindow(
        id: "under",
        name: "Under",
        unit: .percentage,
        remainingFraction: -0.5
    )

    #expect(over.remainingFraction == 1)
    #expect(under.remainingFraction == 0)
}
