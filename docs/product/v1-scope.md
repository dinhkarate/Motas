# Motas v1 Scope

- Status: Frozen for prototype/MVP
- Date: 2026-07-23
- Roadmap task: `P0.9`

## Product statement

Motas v1 is a native macOS 14+ menu bar app with a desktop WidgetKit companion that shows direct AI quota and local proxy/router health as one conservative readiness state.

## v1 must ship

### Native surfaces

- SwiftUI macOS containing app.
- `MenuBarExtra` with `.window` style.
- Settings window.
- Medium and large WidgetKit desktop widgets.
- Shared non-secret snapshot through an App Group.

### Readiness

- Deterministic states: Ready, Caution, Fallback, Blocked, Proxy Down and Unknown.
- Honest stale/partial/unavailable handling.
- Last-updated/freshness display.
- Explanation and next action for non-ready states.

### Connectors

Required for MVP:

- Claude Code direct-provider quota prototype/integration.
- 9Router health/fallback connector.
- CLIProxyAPI health/account connector.

Optional if schedule permits without delaying beta:

- OpenRouter credit connector.
- Generic OpenAI-compatible endpoint reachability connector.

Deferred:

- ProxyPal connector.
- LiteLLM connector.
- Other direct providers beyond those needed to validate the architecture.

### Security and local data

- Keychain-backed secret storage.
- Read-only connector access where possible.
- Redacted errors and diagnostics.
- Versioned normalized snapshot with no credentials.
- Local status history with bounded retention.

### Product behavior

- Guided first connection.
- Manual and scheduled refresh.
- Threshold/fallback/proxy-down notifications with cooldown.
- Diagnostics export.
- Light/dark appearance and basic accessibility.

### Distribution

- Direct signed/notarized DMG.
- GitHub Releases.
- Homebrew Cask in a project tap.
- Sparkle update channel.
- 15-day trial and one-time license for paid v1.

## Explicitly not v1

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
- Guaranteed real-time WidgetKit updates.

## Phase 1 mapping

| Phase 1 task | v1 scope capability |
|---|---|
| P1.1–P1.2 | Native app shell, bundle identity and macOS 14 target |
| P1.3 | Live menu bar surface |
| P1.4 | WidgetKit desktop surface and shared snapshot proof |
| P1.5 | Normalized model implementation |
| P1.6 | Connector protocol and mock connectors |
| P1.7 | Readiness engine implementation/tests |
| P1.8 | Settings shell |
| P1.9–P1.10 | 9Router research/prototype |
| P1.11–P1.12 | CLIProxyAPI research/prototype |
| P1.13–P1.14 | Claude Code research/prototype |
| P1.15 | End-to-end prototype acceptance |

Every Phase 1 task directly supports the frozen scope.

## Scope-change rule

Before public beta, a new feature enters v1 only if:

1. It resolves a P0/P1 blocker for the product promise.
2. It cannot be satisfied by documentation or a post-beta task.
3. It does not delay required connector correctness, credential safety or distribution.
4. The change is recorded in this file with rationale.

New providers are not automatically accepted merely because an endpoint exists.

## v1 exit statement

Motas v1 is successful when a new user can install it, connect at least one direct provider and one proxy/router, see a truthful global readiness state in the menu bar and desktop widget, receive useful alerts, and trust that credentials remain local.
