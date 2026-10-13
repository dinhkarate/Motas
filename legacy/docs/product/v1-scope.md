# Motas v1 Scope

- Status: Revised for MIT open source
- Date: 2026-09-14
- Roadmap task: `P0.9`

## Product statement

Motas v1 is a native macOS 14+ menu bar app that reads AI quota from your own proxy stack (CLIProxyAPI, 9Router) and Claude Code, and shows it as one conservative readiness state.

## v1 must ship

### Native surfaces

- SwiftUI macOS app.
- `MenuBarExtra` with `.window` style: quota ring hero, per-source tiles, Refresh/Settings/Quit footer.
- Settings window (General / Sources / Advanced tabs).
- Versioned normalized snapshot in `~/Library/Application Support/Motas/`.

### Readiness

- Deterministic states: Ready, Caution, Fallback, Blocked, Proxy Down and Unknown.
- Honest stale/partial/unavailable handling.
- Last-updated/freshness display.
- Explanation and next action for non-ready states.

### Connectors

Required for MVP:

- Claude Code direct-provider quota integration.
- 9Router health/account connector with `GET /api/usage/{connectionId}` quota probing.
- CLIProxyAPI health/account connector with `POST /v0/management/quota/fetch` quota probing.
- Proxy-sourced quota: per-account windows, route-level pool-best aggregation, pool health.

Optional if schedule permits without delaying beta:

- OpenRouter credit connector.
- Generic OpenAI-compatible endpoint reachability connector.

Deferred:

- ProxyPal connector.
- LiteLLM connector.
- Other direct providers beyond those needed to validate the architecture.

### Security and local data

- Keychain-backed secret storage.
- Read-only connector access everywhere: no reset, switch, start or stop endpoints, ever.
- Redacted errors and diagnostics.
- Versioned normalized snapshot with no credentials.
- Local status history with bounded retention.

### Product behavior

- Guided first connection.
- Manual and scheduled refresh, plus cached quota probing with cooldown.
- Threshold/fallback/proxy-down notifications with cooldown.
- Diagnostics export.
- Light/dark appearance and basic accessibility.

### Distribution

- MIT open source.
- GitHub Releases with ad-hoc signed Apple Silicon `.app` zip.
- Homebrew Cask in `dinhkarate/homebrew-motas`, installed with
  `brew install --cask --no-quarantine dinhkarate/motas/motas`
  (ad-hoc signed, not notarized).

## Explicitly not v1

- WidgetKit desktop widget (needs full Xcode; removed from the repo).
- Notarized DMG or Sparkle update channel (needs a Developer ID).
- Paid tier, trial or license key.
- Notification delivery (`ReadinessNotificationEngine` has no `UNUserNotificationCenter` adapter yet).
- Windows/Linux ports.
- Cloud account or mandatory sign-in.
- Team dashboard or shared quota pools.
- Multi-device synchronization.
- Mobile/iOS companion.
- Public connector marketplace/plugin SDK.
- Automatic proxy configuration changes.
- Account pooling or request routing performed by Motas.
- Destructive start/stop/reset proxy controls.
- Floating always-on-top desktop panel.
- Mac App Store release unless a later feasibility review approves it.
- Twenty shallow providers for marketing count.
- Usage-based Motas billing.

## Phase 1 mapping

| Phase 1 task | v1 scope capability |
|---|---|
| P1.1–P1.2 | Native app shell, bundle identity and macOS 14 target |
| P1.3 | Live menu bar surface |
| P1.5 | Normalized model implementation |
| P1.6 | Connector protocol and mock connectors |
| P1.7 | Readiness engine implementation/tests |
| P1.8 | Settings shell |
| P1.9–P1.10 | 9Router research/prototype |
| P1.11–P1.12 | CLIProxyAPI research/prototype |
| P1.13–P1.14 | Claude Code research/prototype |
| P1.15 | End-to-end prototype acceptance |

P1.4 (WidgetKit surface) is dropped with the widget. Every other Phase 1 task directly supports the scope.

## Scope-change rule

Before public beta, a new feature enters v1 only if:

1. It resolves a P0/P1 blocker for the product promise.
2. It cannot be satisfied by documentation or a post-beta task.
3. It does not delay required connector correctness, credential safety or distribution.
4. The change is recorded in this file with rationale.

New providers are not automatically accepted merely because an endpoint exists.

## v1 exit statement

Motas v1 is successful when a new user can install it, connect at least one proxy/router, see truthful quota percentages in the menu bar and panel, receive useful alerts, and trust that credentials remain local.
