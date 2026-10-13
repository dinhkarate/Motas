# Readiness notifications

`MotasCore` now contains a pure `ReadinessNotificationEngine` that turns two normalized `StatusSnapshot` values into an optional, deduplicated event.

## Boundary

The engine does **not** request notification permission or call `UserNotifications`. It returns safe normalized data for a future macOS adapter. This keeps transition, cooldown and privacy behavior testable under Swift Package Manager while full Xcode/signing validation is unavailable.

## Mapping

```text
ready      no event
caution    normal severity
fallback   normal severity
blocked    critical severity
proxyDown  critical severity
unknown    low severity (configurable)
```

The initial snapshot is always silent. Returning to `ready` is silent. Repeated refreshes with the same state/source/reason are silent.

## Deduplication and cooldown

`ReadinessNotificationHistory` stores only:

- the last deterministic event key;
- the last notification timestamp.

The default cooldown is 30 minutes. The event key uses only normalized readiness state, source ID and readiness title. It never includes raw connector response bodies, endpoints, cookies, tokens or quota payloads.

A source or readiness reason change can create a new event even if the broad readiness state remains the same. Unknown events can be disabled through `ReadinessNotificationPolicy`.

## Future delivery adapter

A macOS `UserNotifications` adapter should be added only after full Xcode app-target verification. It must:

1. request permission once from the containing app;
2. map event severity to notification interruption behavior;
3. use `event.id` as a stable request identifier where appropriate;
4. never place secrets or raw connector details in title, subtitle or body;
5. persist history only if notification behavior needs to survive app restart.
