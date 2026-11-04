# GOAL.md — Motas (v0.3, 2026-11)

Motas is a native macOS menu bar app that monitors AI subscription quota held by
**remote AI proxies** — CLIProxyAPI and 9Router first — across many servers and
many accounts per server. It never shows a number it did not read.

The 0.2 implementation lives in `legacy/` for reference. It was unusable:
Settings had been replaced by a debug placeholder, the app was stuck in demo
mode, demo numbers were persisted as real, and CLIProxyAPI
`POST /quota/fetch` returns 501 for every built-in provider.

## Positioning

Proxy-first. Local accounts (Claude Code, Codex on this Mac) come later and
follow CodexBar's rule: read existing tokens read-only, never refresh them.

## v1 scope (the 0.2 attempt)

- Proxies: CLIProxyAPI and 9Router, each behind a `ProxyAdapter`.
- Menu bar, panel, Settings, notifications, WidgetKit widget, 7-day history.
- Secrets only in Keychain; read-only proxy calls only.
- Real fixtures, no demo mode.

## v0.3 scope (2026-11)

The refactor contract is `docs/design-v0.3.md`. It fixes the review findings:

- one `AppModel` / one `Monitor`, coalesced refreshes, wake, network and
  panel-open triggers;
- pool math per `(provider, tier, group)` with lanes, dedupe, reset-since-read,
  reset credits and a pinned headline;
- a stateful `AlertEngine` with time-based confirmation and deterministic ids;
- one Keychain item, non-blocking reads, approval, 0.2 migration;
- 9Router CLI token, password login guards, two-step reads and backoff;
- CLI provisioning (`motas proxy …`) with the same settings path as the app;
- the native desktop widget "Model Pulse";
- a 7-day pool history and a WidgetKit widget fed by precomputed pools.

## Non-negotiables

- macOS only. MIT.
- Secrets (management keys, tokens, passwords) only in Keychain, never in
  settings, logs, fixtures or argv.
- Allowed proxy calls: list accounts, ask the proxy to call a provider usage
  URL for an account (CPA `/v0/management/api-call`, 9Router
  `/api/usage/{id}`). These may make the proxy refresh its own tokens —
  acceptable, the proxy owns them. Never call `/usage-queue` (it pops records),
  reset, switch, delete or config-changing endpoints.
- No fabricated data: no demo mode in the shipping app, unknown stays unknown,
  a transient failed read carries its last windows and is marked stale.
- Every parser is tested against fixtures captured from real proxies
  (`Tests/MotasCoreTests/Fixtures/live/`, sanitized).

## Done when (v0.3)

1. `nice -n 10 swift test -j 4` passes offline, and
   `MOTAS_LIVE=1 … swift test --filter LiveTests` passes against the testbed.
2. The production 9Router fixture gives the headline "Codex 51 %", Gemini
   ≈ 99 %, Claude & GPT 100 %; nine Qoder connections become rejected after two
   reads and the tenth is unmetered; no pool invents a value, and an account
   with no current figures stays unknown.
3. CPA and 9Router can be added through Settings and the CLI; every account
   shows the same numbers as the proxy's own dashboard; secrets live only in
   Keychain.
4. Menu bar, panel, Model Pulse and history render from one `Snapshot`;
   WidgetKit reads the precomputed `SharedSnapshot`; an unconfigured app shows
   the empty state; no demo mode.
5. Alerts fire on pool low / exhausted / available, proxy down / back and
   accounts that need re-login, with debounce; Keychain, offline and missing
   credentials never alert.
6. `motas proxy list/add/set-secret/remove/enable/disable/test` work with exit
   codes 64/65/69/75, and changes reach a running app immediately.
7. Release packaging (`scripts/build-app.sh 0.3.0`, no Xcode) produces
   `dist/Motas.app`; the built app runs for 24 h against the live testbed
   without crashing. Packaging is a release step, not part of the refactor
   loop.
8. `scripts/dev/capture-live.py` captures with the 9Router CLI token and
   records timings; `sanitize-fixtures.py` leaves no email, token or real id in
   the committed fixtures.
