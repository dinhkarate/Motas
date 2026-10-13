# GOAL.md — Motas

Read this first. It is the `/goal` artifact: the mission, the constraints, and what is deliberately out of scope.

## Mission

Motas is a native macOS menu bar app that answers one question: **can I start a long coding session right now?** It answers by reading quota from *your own proxy stack* — CLIProxyAPI, 9Router, Claude Code — and rendering it as a quota ring, per-window bars, and one conservative readiness state.

## Why proxies

CLIProxyAPI and 9Router already hold the OAuth credentials and already query provider quota endpoints. Motas reuses that work (`POST /v0/management/quota/fetch`, `GET /api/usage/{connectionId}`) instead of asking the user for provider credentials.

## Non-negotiables

- **macOS only.** Windows/Linux are not targets.
- **Read-only against every proxy.** No reset, switch, start or stop endpoints, ever.
- **Credentials only in Keychain.** Never in settings JSON, snapshots, logs or diagnostics.
- **Never invent a percentage, a reset time, or a green state.** See `docs/architecture/status-presentation.md` and `docs/architecture/readiness-rules.md`.
- **MIT.** Distributed through Homebrew (`dinhkarate/motas/motas`).

## Shipped surface

Menu bar ring + panel + settings. Connectors: Claude Code, CLIProxyAPI, 9Router.

## Deliberately not now

- WidgetKit widget — needs full Xcode.
- Notarization — needs a Developer ID (ad-hoc signed + `--no-quarantine` cask instead).
- Notification delivery — `ReadinessNotificationEngine` exists but has no `UNUserNotificationCenter` adapter.
- Windows/Linux.
- Any paid tier.
