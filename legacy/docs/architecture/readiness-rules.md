# Motas Readiness Rules

- Status: Accepted
- Date: 2026-07-23
- Roadmap task: `P0.8`
- Swift source of truth: `Sources/MotasCore/Readiness`

## Goal

Return one deterministic, conservative answer to:

> Can the user's configured AI coding stack support a serious session now?

The engine consumes normalized status. It never calls providers and never guesses missing quota.

## Inputs

```text
ProviderStatus[]
ProxyStatus[]
evaluation time
threshold policy
```

Only sources with role `primary` or `fallback` affect global readiness. `informational` sources remain visible but do not change the result.

## Default thresholds

```swift
public struct ReadinessPolicy: Sendable, Equatable {
    public let cautionRemainingFraction: Double  // 0.20
    public let criticalRemainingFraction: Double // 0.05
}
```

The lowest remaining value across enforced quota windows is the source's quota pressure. Windows with unknown remaining fraction are not interpreted as unlimited.

## State precedence

Evaluate in this order:

```text
1. proxyDown
2. blocked
3. fallback
4. caution
5. unknown
6. ready
```

Precedence prevents a healthy secondary source from hiding a broken configured route.

## Decision rules

### Proxy Down

Return `proxyDown` when all are true:

- At least one proxy is configured as `primary`.
- Every primary proxy has health `unreachable`.
- No verified alternate primary path bypasses those proxies.

User-facing form:

```text
Title: Proxy unavailable
Explanation: 9Router could not be reached. Check that the local service is running.
```

Do not return `proxyDown` for `unauthorized`; monitoring authorization failure does not prove traffic is down.

### Blocked

Return `blocked` when no verified usable primary or fallback path remains, including:

- Primary provider quota is known exhausted and no verified fallback is available.
- Primary proxy is known exhausted/blocked and no fallback route is available.
- All relevant providers/proxies are known exhausted, unreachable or unsupported for the intended route.

User-facing form:

```text
Title: AI stack blocked
Explanation: Claude quota is exhausted and no usable fallback was verified.
```

### Fallback

Return `fallback` when:

- A primary source is known exhausted, unreachable or below the critical threshold; and
- At least one fallback source or proxy route is verified available.

Also return `fallback` when a proxy explicitly reports an active non-primary tier while it remains usable.

User-facing form:

```text
Title: Running on fallback
Explanation: Claude quota is exhausted. 9Router's economical tier is available.
```

### Caution

Return `caution` when the stack is currently usable but risk is verified:

- Any primary enforced quota window has remaining fraction `<= 0.20`; or
- A primary source is degraded; or
- A primary observation is partial but contains enough data to verify current usability; or
- A fallback path expected by the configuration is unavailable while the primary remains usable.

User-facing form:

```text
Title: Quota running low
Explanation: Claude's 5-hour window has 14% remaining. No fallback interruption is active.
```

### Unknown

Return `unknown` when a safe result cannot be established:

- No primary source is configured.
- All primary observations are unavailable/stale without another fresh verified path.
- Primary monitoring is unauthorized.
- Connector/version does not expose enough data.
- Conflicting normalized inputs cannot be reconciled.

Unknown is not green.

User-facing form:

```text
Title: Readiness unknown
Explanation: CLIProxyAPI is reachable, but current account availability could not be verified.
```

### Ready

Return `ready` only when:

- At least one primary path is freshly and positively verified usable.
- No higher-precedence rule applies.
- All known enforced primary quota windows are above the caution threshold.
- Required primary proxy route health is healthy.

User-facing form:

```text
Title: AI stack ready
Explanation: Claude and the configured proxy route are available.
```

## Source usability

A source is positively usable when:

```text
health is healthy or degraded
AND observation is fresh or defensibly partial
AND no enforced quota window is exhausted
```

`degraded` contributes to caution, not ready, unless another healthy primary path makes the aggregate safe.

A fallback is verified when:

- A fallback provider is positively usable; or
- A proxy route has `fallbackAvailable == true`; or
- A proxy reports an active usable fallback tier.

`fallbackAvailable == nil` is not verified.

## Freshness behavior

- `stale` primary data cannot produce `ready` by itself.
- A stale source may provide context in the explanation.
- A fresh healthy alternate path can prevent `unknown` if it satisfies the configured primary route.
- `partial` may produce caution when current usability is verified but quota/fallback detail is incomplete.
- `unavailable` produces unknown unless another verified path or a known hard failure produces a higher-precedence state.

## Multiple sources

### Multiple primary providers

If the user marks providers as independently usable primary paths, one healthy primary can keep the stack usable. A failed primary still produces caution unless the failure blocks the configured route.

### Primary proxy plus upstream providers

When a primary proxy is configured as the user's route, its reachability is authoritative. Healthy upstream provider data does not hide an unreachable primary proxy unless a direct bypass is explicitly configured as primary.

### Informational sources

Informational cost balances and sources never turn a stack ready, blocked or fallback.

## Stable selection of explanation

When multiple conditions match:

1. Select the state by precedence.
2. Prefer a primary source over a fallback source.
3. Prefer a hard operational failure over quota pressure.
4. Prefer the lowest enforced remaining fraction.
5. Break remaining ties by stable source ID.

This makes tests and widget output deterministic.

## Pseudocode

```text
relevant = primary + fallback sources
if no primary: unknown

if required primary proxy path is unreachable and no direct primary bypass:
  proxyDown

primaryUsable = verified usable primary paths
fallbackUsable = verified usable fallback paths/routes
primaryFailed = known exhausted/unreachable primary paths

if primaryUsable is empty and fallbackUsable is empty:
  if failure is known: blocked
  else: unknown

if active fallback tier OR (primaryFailed and fallbackUsable):
  fallback

if primary quota <= caution OR primary degraded/partial OR expected fallback unavailable:
  caution

if no fresh positively usable primary path:
  unknown

ready
```

## Test matrix

Required unit cases:

| Case | Expected |
|---|---|
| Healthy fresh primary, quota 80% | `ready` |
| Healthy primary, quota 20% | `caution` |
| Primary quota 0%, healthy fallback | `fallback` |
| Primary quota 0%, no fallback | `blocked` |
| Required primary proxy unreachable | `proxyDown` |
| Primary proxy unauthorized, no other proof | `unknown` |
| Stale previously healthy provider only | `unknown` |
| Fresh partial primary with verified operation | `caution` |
| No configured primary | `unknown` |
| Active economical proxy tier | `fallback` |
| Informational exhausted balance only | `ready` if primary is healthy |
| Healthy provider behind unreachable required proxy | `proxyDown` |

## Notification mapping

Readiness state and notifications are related but separate:

```text
ready       no alert
caution     threshold/degradation alert with cooldown
fallback    fallback-activated alert
blocked     interruption alert
proxyDown   local proxy outage alert
unknown     stale/monitoring alert, lower urgency by default
```

The notification engine must notify on meaningful transitions, not every refresh.

## Honesty constraints

The engine must never:

- Convert unknown remaining quota into 100%.
- Treat unauthorized monitoring as verified service outage.
- Treat stale data as ready.
- Claim fallback exists when availability is nil/unknown.
- Hide an unreachable required proxy behind healthy upstream data.
- Promise real-time accuracy for WidgetKit snapshots.
