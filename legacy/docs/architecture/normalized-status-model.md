# Motas Normalized Status Model

- Status: Accepted
- Date: 2026-07-23
- Roadmap task: `P0.7`
- Swift source of truth: `Sources/MotasCore/Models`

## Purpose

Every connector exposes different concepts. Motas normalizes those inputs into a stable snapshot so the menu bar, widget, notifications and diagnostics do not depend on connector-specific payloads.

The contract must represent:

- Direct provider quota.
- Proxy/router reachability and routing.
- Account-pool health.
- Fallback availability.
- Multiple quota windows and reset times.
- Fresh, stale, partial and unavailable observations.
- Honest unknown states.

## Top-level snapshot

```swift
public struct StatusSnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let capturedAt: Date
    public let readiness: ReadinessAssessment
    public let providers: [ProviderStatus]
    public let proxies: [ProxyStatus]
}
```

Rules:

- `schemaVersion` starts at `1` and changes only for incompatible persisted snapshot changes.
- `capturedAt` is the time Motas assembled the normalized snapshot.
- A widget renders only the snapshot; it does not need connector credentials or raw payloads.
- Arrays have deterministic ordering chosen by the containing app.

## Shared concepts

### Source role

```swift
public enum SourceRole: String, Codable, Sendable {
    case primary
    case fallback
    case informational
}
```

- `primary`: normally required for the user's intended coding route.
- `fallback`: can keep the stack usable when a primary is constrained or unavailable.
- `informational`: useful to display but does not control global readiness.

### Operational health

```swift
public enum OperationalHealth: String, Codable, Sendable {
    case healthy
    case degraded
    case exhausted
    case unreachable
    case unauthorized
    case unsupported
    case unknown
}
```

Semantics:

- `healthy`: operation was verified.
- `degraded`: reachable but impaired.
- `exhausted`: known usable capacity is exhausted.
- `unreachable`: endpoint/process could not be reached.
- `unauthorized`: monitoring access failed; this does not prove the service itself is down.
- `unsupported`: connector/version cannot expose the requested information.
- `unknown`: no defensible conclusion is possible.

### Data quality

```swift
public enum DataQuality: String, Codable, Sendable {
    case fresh
    case stale
    case partial
    case unavailable
}
```

Operational health and data quality are independent. A proxy may be `healthy` while account-level data is `partial`; a previously healthy provider may have `stale` data.

### Observation metadata

```swift
public struct Observation: Codable, Sendable, Equatable {
    public let checkedAt: Date
    public let lastSuccessfulAt: Date?
    public let quality: DataQuality
    public let message: String?
}
```

- `checkedAt` records the last attempt.
- `lastSuccessfulAt` records the last valid normalized observation.
- `message` is user-safe and contains no raw credentials or unredacted response body.

## Quota windows

```swift
public enum QuotaUnit: String, Codable, Sendable {
    case requests
    case tokens
    case credits
    case currency
    case percentage
    case unknown
}

public struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let unit: QuotaUnit
    public let used: Double?
    public let limit: Double?
    public let remainingFraction: Double?
    public let resetsAt: Date?
    public let isEnforced: Bool
}
```

Normalization rules:

1. `remainingFraction` uses `0...1`; connectors clamp invalid upstream values.
2. If upstream exposes only used percentage, calculate `1 - usedFraction`.
3. `used` and `limit` retain display context when upstream exposes them.
4. `remainingFraction = nil` means unknown, not unlimited.
5. `isEnforced = false` prevents informational cost counters from being treated as hard quota.
6. All dates are absolute; presentation converts them to the user's locale/timezone.
7. Never infer a reset time that upstream does not expose reliably.

## Provider status

```swift
public struct ProviderStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let role: SourceRole
    public let health: OperationalHealth
    public let observation: Observation
    public let quotaWindows: [QuotaWindow]
    public let detail: String?
}
```

Examples:

- Claude Code session and weekly windows.
- OpenRouter credit balance.
- Codex rolling and weekly windows.

`detail` is concise display text such as `Resets in 2h` and must not contain secrets.

## Proxy/router status

```swift
public struct ProxyStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let role: SourceRole
    public let health: OperationalHealth
    public let observation: Observation
    public let isRequiredRoute: Bool
    public let route: RouteStatus?
    public let accounts: [ProxyAccountStatus]
    public let quotaWindows: [QuotaWindow]
    public let endpointLabel: String?
}
```

`isRequiredRoute` records whether the user's configured workflow must traverse this proxy. A required unreachable proxy can produce `proxyDown` even when upstream provider data is healthy, because healthy upstream data does not prove a direct bypass exists.

`endpointLabel` is a redacted display value. Credentials, query secrets and headers are never persisted.

### Route status

```swift
public enum RouteTier: String, Codable, Sendable {
    case primary
    case subscription
    case economical
    case free
    case custom
    case unknown
}

public struct RouteStatus: Codable, Sendable, Equatable {
    public let activeTier: RouteTier
    public let primaryAvailable: Bool?
    public let fallbackAvailable: Bool?
    public let description: String?
}
```

Boolean values are optional because not every proxy exposes a defensible answer.

### Proxy account status

```swift
public struct ProxyAccountStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let provider: String?
    public let health: OperationalHealth
    public let quotaWindows: [QuotaWindow]
}
```

Account IDs and labels are connector-generated, stable and non-secret. Email addresses should be masked before entering the normalized model unless the user explicitly enables them.

## Readiness assessment

```swift
public enum ReadinessState: String, Codable, Sendable {
    case ready
    case caution
    case fallback
    case blocked
    case proxyDown
    case unknown
}

public struct ReadinessAssessment: Codable, Sendable, Equatable {
    public let state: ReadinessState
    public let title: String
    public let explanation: String
    public let primarySourceID: String?
    public let evaluatedAt: Date
}
```

The assessment is derived by the readiness engine, never set by a connector.

## Connector contract

```swift
public protocol StatusConnector: Sendable {
    var id: String { get }
    var displayName: String { get }
    func refresh() async -> ConnectorResult
}

public enum ConnectorResult: Sendable, Equatable {
    case provider(ProviderStatus)
    case proxy(ProxyStatus)
}
```

Connector responsibilities:

- Authenticate/read upstream data.
- Normalize units and dates.
- Redact errors.
- State unsupported/partial data honestly.

Connector non-responsibilities:

- Compute global readiness.
- Write widget snapshots.
- Schedule notifications.
- Store raw credentials in normalized models.

## Freshness defaults

Initial defaults:

```text
Normal app refresh: 5 minutes

The current prototype uses the same five-minute interval for active sessions and quota warnings. Adaptive one-minute refresh is deferred until its connector cost and WidgetKit behavior can be validated safely.
Provider stale threshold: 15 minutes
Local proxy stale threshold: 5 minutes
Widget display: show captured time and stale marker from snapshot
```

Connectors may recommend slower intervals when upstream rate limits or authentication flows require them. The scheduler remains authoritative.

## Persistence and privacy

Allowed in App Group snapshot:

- Normalized enum values.
- Display names.
- Quota values and reset times.
- Masked account labels.
- Redacted endpoint label.
- Sanitized explanation.

Forbidden:

- API and management keys.
- OAuth/session tokens.
- Cookies.
- Authorization headers.
- Raw config file contents.
- Raw upstream error payloads.

## Compatibility rules

- Unknown enum values from a future snapshot must fail safely to `unknown`/`unavailable` at migration boundaries.
- Connectors keep raw response DTOs private to their module.
- UI code depends only on normalized public models.
- Persisted snapshots are written atomically.

## Acceptance mapping

This model covers the `P0.7` exit criteria:

- `ProviderStatus`: defined.
- `ProxyStatus`: defined.
- `QuotaWindow`: defined.
- Health: operational and independent data-quality models defined.
- Reset: absolute optional `resetsAt` defined.
- Freshness: observation metadata and default thresholds defined.
