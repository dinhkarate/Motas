# GOAL.md — Motas (rebuild, 2026-10)

Motas is a native macOS menu bar app that monitors AI subscription quota held by
**remote AI proxies** — CLIProxyAPI and 9Router first — across many servers and
many accounts per server. It never shows a number it did not read.

The previous implementation lives in `legacy/` for reference only. It was
unusable: Settings had been replaced by a debug placeholder, the app was stuck in
demo mode, demo numbers were persisted as real, and CLIProxyAPI
`POST /quota/fetch` returns 501 for every built-in provider.

## Positioning

Proxy-first. Local accounts (Claude Code, Codex on this Mac) come later and
follow CodexBar's rule: read existing tokens read-only, never refresh them.

## v1 scope

- Proxies: CLIProxyAPI, 9Router, each behind a `ProxyAdapter`. OmniRoute and
  new-api come after v1.
- Menu bar: pool reserve % (see `docs/architecture.md`).
- Panel: proxy → provider → account.
- Settings that actually open, save to JSON + Keychain, and test a connection.
- Notifications: pool below threshold, proxy unreachable / unauthorized.
- WidgetKit widget showing pool reserve.
- 7-day history chart.

## Non-negotiables

- macOS only. MIT.
- Secrets (management keys, passwords) only in Keychain.
- Allowed proxy calls: list accounts, ask the proxy to call a provider usage URL
  for an account (CPA `/v0/management/api-call`, 9Router `/api/usage/{id}`).
  These may make the proxy refresh its own tokens — acceptable, the proxy owns
  them. Never call `/usage-queue` (it pops records), reset, switch, delete or
  config-changing endpoints.
- No fabricated data: no demo mode in the shipping app, unknown stays unknown.
- Every parser is tested against fixtures captured from real proxies
  (`Tests/MotasCoreTests/Fixtures/live/`, sanitized).

## Done when

1. CPA and 9Router at the obsession testbed can be added through Settings and
   every account shows the same numbers as the proxy's own dashboard.
2. All fixtures come from real responses; app-level behavior (open Settings,
   save, refresh) is covered by tests.
3. Menu bar shows pool %, panel groups proxy → provider → account, and an
   unconfigured app shows an empty state.
4. Notifications fire on threshold / connectivity changes; widget shows pool %;
   7-day history chart works.
5. `.app` built with Xcode runs 24 h on this Mac without crashing; all tests pass.
