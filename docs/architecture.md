# Motas architecture

```
ProxyConfig ──► Monitor (actor) ──► adapter ──► ProxyRead.run ──► Snapshot
 (settings.json)   per proxy       9Router /     state merge          │
 (Keychain)                        CLIProxyAPI                        │
                                                                      ├─► Pool.summarize ─► AppModel ─► menu bar / panel / Model Pulse
                                                                      ├─► AlertEngine                  notifications
                                                                      ├─► HistoryStore                 history
                                                                      └─► SharedSnapshot ─► WidgetKit
```

One `AppModel` owns the reading loop and everything the UI shows. The v0.3
contract, including the rules below, is `docs/design-v0.3.md`.

## Reading a proxy

| Proxy | List accounts | Per-account quota |
|---|---|---|
| CLIProxyAPI | `GET /v0/management/auth-files` (`Authorization: Bearer <management key>`) | `POST /v0/management/api-call` `{auth_index, method, url, header{"Authorization":"Bearer $TOKEN$"}, data}` — the proxy injects the account token and calls the provider |
| 9Router | `GET /api/providers` (`x-9r-cli-token`, or the `auth_token` cookie from `POST /api/auth/login`) | `GET /api/usage/{id}` |

Provider URLs used through CLIProxyAPI (`UpstreamClients` is the only file that
holds them):

| Provider | URL | Parser |
|---|---|---|
| Codex | `GET chatgpt.com/backend-api/wham/usage` (+ `Chatgpt-Account-Id` from `id_token.chatgpt_account_id`) | `ProviderUsage.codex` |
| Antigravity | `POST {daily-,}cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary {project}` | `ProviderUsage.antigravity` |
| Claude | `GET api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`) | `ProviderUsage.claude` (not yet verified against a live CPA account) |

Never used: `POST /quota/fetch` (501 for built-in providers), `/usage-queue`
(pops records), any reset/switch/delete/config route.

### 9Router auth

- **CLI token (recommended):** `x-9r-cli-token` on the providers and usage
  requests only; no login, no cookie. A session 401 is `.unauthorized` and
  tells the user to derive the token again.
- **Dashboard password:** logs in when there is no cookie or it is 23 h old.
  Login is single-flight. A 401 is "Wrong password"; a 429 is a lockout until
  `retryAfter`; the two 403 messages (password login disabled, default password
  must change) are reported as such. The guards live in the adapter, so a wrong
  password never feeds 9Router's per-IP lockout. A session 401 drops the cookie,
  logs in once and retries the request.
- The token is the first 16 hex characters of
  `sha256(machineId + "9r-cli-auth" + cliSecret)`; it is admin-equivalent and
  never expires.

### Reading cycle

- `ProxyRead.run` lists the accounts, then reads the due ones with concurrency
  4. A read starts only while less than 40 s of budget has elapsed; each
  request is capped by the 20 s resource timeout. Reads that never start keep
  their state and are not failures. There is no outer deadline or timer task.
- `ProxyState` is plain values with a pure `apply`:
  - a good read stores its windows and `observedAt`, clears the streaks;
  - a transient failure or 429 keeps the windows (now stale) and backs off
    5 min × 2^(streak−1), capped at 60 min;
  - a credential rejection is re-read once, then becomes `.rejected` with a
    15 min recheck;
  - an unmetered message keeps the windows for 24 h or two more reads, then
    becomes `.unavailable` with a 6 h recheck;
  - a failed list carries the last accounts and increments
    `consecutiveFailures`;
  - accounts missing from a successful list are dropped.
- `due` reads accounts with windows oldest-first, then never-read, failed or
  rejected, then unmetered rechecks. `force` skips backoff but never a rate
  limit or an unmetered recheck.
- `Monitor` is an actor. It keeps one adapter per proxy and rebuilds it when
  kind, URL, auth or the secret changes; state resets only when kind or base
  URL changes. A Keychain approval need, another Keychain error or a missing
  secret produces a carried snapshot and never an alert.
- `Monitor` logs one line per proxy: listed / read / ok / failed / rejected /
  unmetered / reused / not started / milliseconds
  (`subsystem == "dev.motas.app"`, category `refresh`). Labels are private;
  secrets are never logged.

## Pools

A pool is one `(provider, tier, group)`.

- **Membership:** accounts of every enabled proxy, whatever its health.
  Disabled and unmetered accounts are excluded; rejected accounts are counted
  with no value. Accounts with the same non-nil identity count once, newest
  `quotaObservedAt` wins. Rows stay per proxy.
- **Tiers:** Codex only. Free and Go merge into `free`; Plus, Pro, Team,
  Business, Enterprise and Edu stay separate; no plan is `""`. Every other
  provider uses tier `""`.
- **Which pools exist:** if any member has a group-nil `.limit` window, one
  pool with group `""`; otherwise every group in a member's `.limit` or
  `.model` windows (Antigravity → Gemini, Claude & GPT). `image` and `other`
  never form pools. A provider that never had windows gets no pool.
- **Account value:** `L` = limit windows of the group (plus group-nil limits
  for a named group); `M` = model windows of the group. Drop windows that
  reset since they were read. A rejected account counts as rejected with no
  value; stale or empty `L ∪ M` → unknown. Otherwise value =
  `min(min(L), max(M))` — a family is out only when every text model is out.
- **Flags:** exhausted at ≤ 0.5 %; usable above 0.5 % with no cooldown.
  Recovery is the latest reset among the binding exhausted windows, not before
  `cooldownUntil`; unknown when those windows carry no reset.
- **`PoolSummary`:** reserve = mean over measured members; members, measured,
  usable, exhausted, unknown, rejected, stale, coolingDown; lanes keyed by
  canonical period (`primary`, `secondary`, `5h`, `weekly`, `daily`, `models`);
  next recovery/reset; reset credits.
- **Order:** providers codex, claude, antigravity, gemini-cli, then
  alphabetical; tiers free, plus, pro, team, business, enterprise, edu, others,
  then `""`; groups in `QuotaGroups` order. Never sorted by value.
- **Headline:** the pinned pool when present; a missing pinned pool falls back
  to the same provider's pool with the most members; otherwise the lowest
  reserve among pools with `measured ≥ 2`, else the pool with the most measured
  accounts. The menu-bar gauge shows the headline and the next pool.

## Alerts

`AlertEngine` is a stateful struct in MotasCore. The first evaluation records
what is already true as a baseline and sends nothing. A condition is confirmed
on two evaluations whose snapshots are at least `refreshInterval / 2` apart.

- **Pool low:** `measured ≥ 2` and reserve below the threshold; re-arms
  silently at threshold + 5 %.
- **Pool exhausted:** `members ≥ 1`, `usable == 0`, `unknown == 0`; "available
  again" only after an exhausted alert.
- **Proxy down:** health failed with two consecutive failures, while online;
  `.needsKeychainAccess`, `.missingCredential` and `.offline` never notify.
- **Accounts rejected:** aggregated per proxy, for accounts that became
  rejected since the previous evaluation.
- Identifiers are deterministic (`kind:key`), so a newer alert replaces the
  older one. Clicks open the proxy dashboard or the menu-bar panel.

## Secrets

One generic-password item: service `dev.motas`, account `credentials`, value
`{"v":1,"secrets":{"<proxy uuid>":"<secret>"}}`. Background reads are
non-interactive and time out after 0.2 s, returning `.needsApproval` instead of
blocking the main thread. `approve()` is the user-driven read; writes re-read
the item (interactive if needed), merge and update it in place. The 0.2
per-proxy items (`dev.motas.proxy`) migrate once inside `approve()`.
`InMemorySecretStore` serves tests and the render tool.

## App lifecycle

`AppDelegate` owns `AppModel` and `DesktopWidgetController`; there is no second
model.

| Trigger | When | Forced |
|---|---|---|
| Timer | every `refreshInterval` (default 300 s, clamped 60…3600) | no |
| Launch | at start | no |
| Manual | panel or Model Pulse refresh button | yes |
| Wake | 10 s after `NSWorkspace.didWakeNotification` | no |
| Panel open | only when the snapshot is older than max(120 s, interval / 2) | no |
| Settings change | only when `proxies` changed | no |

One refresh is in flight and one is queued; a queued forced refresh stays
forced. After every refresh the app saves `SharedSnapshot`, records history,
computes `WidgetDigest` and reloads WidgetKit only when the digest changed and
15 min have passed (health or headline changes skip the wait; app bundle only).

`NWPathMonitor` sets `isOnline`; offline suppresses proxy-down alerts. The CLI
posts `dev.motas.settings-changed` through `DistributedNotificationCenter` with
`deliverImmediately`; the app reloads settings, invalidates the secret cache,
recomputes presence and refreshes.

## Persistence

- **`settings.json`** (`~/Library/Application Support/Motas/`): proxies with
  auth, refresh interval, low-reserve threshold, notifications toggle. A
  corrupt file is reported and never overwritten with defaults.
- **`UserDefaults`:** `menuBarPool`, `desktopWidget.enabled`,
  `desktopWidget.locked`, `desktopWidget.cards`, `onboardingDone`,
  `legacyKeychainMigrated`.
- **`SharedSnapshot`** in the `group.dev.motas` container (`snapshot.json`; the
  app falls back to Application Support when unbundled): snapshot, threshold,
  precomputed pools, headline id, stale/unhealthy proxy counts, savedAt.
  WidgetKit reads it and never recomputes.
- **`history.json`** (`~/Library/Application Support/Motas/`):
  `PoolSample{at, pool, reserve}`, seven days, at most one sample per pool per
  refresh interval. Bad elements are skipped; 0.2 provider-keyed samples are
  dropped because their means are not comparable with tiered pools.

## CLI

`motas` is the same binary. `main.swift` stays synchronous and enters CLI mode
only for `proxy`, `help`, `--help`, `-h`, `version` or `--version`; anything
else launches the app when run from `Motas.app`, while the Homebrew `motas`
symlink prints help instead of starting a second copy.

| Command | Effect |
|---|---|
| `motas proxy list [--json]` | id, name, kind, auth, enabled, URL, secret set/missing/locked |
| `motas proxy add --kind 9router\|cliproxyapi --name N --url U [--auth cli-token\|password\|management-key] [--secret-stdin] [--disabled]` | Adds a proxy and prints its id |
| `motas proxy set-secret <id\|name> [--secret-stdin]` | Stores a new secret |
| `motas proxy remove\|enable\|disable <id\|name>` | As named |
| `motas proxy test <id\|name>` | Lists only and prints the account counts |

Secrets come from stdin or a no-echo prompt, never argv. Keychain access is
non-interactive by default; `--allow-keychain-prompt` opts in. Exit codes: 0
OK, 64 usage, 65 bad input, 69 proxy unreachable, 75 Keychain approval needed,
1 anything else. Every change posts the distributed notification.

## Testing and tooling

- `Tests/MotasCoreTests/Fixtures/live/` — sanitized real captures. The
  production set is `9r_prod_providers.json` + `9r_prod_usage_by_connection.json`
  (29 connections, all bodies) served through the real `NineRouterAdapter`.
- `Fixtures/synthetic/` — bodies 9Router can return that the production capture
  did not; every string comes from the 9Router source, not invented.
- `swift test` is offline. `LiveTests` hit real proxies only with
  `MOTAS_LIVE=1` and the `MOTAS_CPA_*` / `MOTAS_9R_*` variables.
- `motas-render` renders the menu bar, panel, settings, editor, history and
  widgets from the offline fixture (`--live` for a real 9Router).
- `scripts/dev/capture-live.py` records raw responses (CLI token or password)
  and `raw/timings.jsonl`; `sanitize-fixtures.py` scrubs emails, ids, auth
  indexes and refuses token-like output.

## Keychain without a Developer ID

Motas is ad-hoc signed, so every item's partition is `cdhash:<build>`
(securityd only issues `teamid:` partitions to Apple-issued certificates; a
self-signed certificate does not help, and the data-protection keychain needs a
provisioned Team ID). Consequences and handling:

- After each update macOS asks once to let Motas read its credentials.
  Background refreshes read with `SecKeychainSetUserInteractionAllowed(false)`
  (the flag the file-based login keychain actually honors), get
  `errSecAuthFailed` in milliseconds, and report `needsKeychainAccess`; the
  panel's **Allow…** button performs the interactive read off the main thread.
  "Always Allow" adds the new cdhash, so reads stay silent until the next update.
- Successful reads are cached for the launch.
- A newer build can `SecItemUpdate` an older build's item but not delete it
  (`errSecInvalidOwnerEdit`), so writes update in place and removal scrubs the
  value before deleting.
- Items must be created by Motas itself: items made with `security
  add-generic-password` carry an `apple-tool:` partition and always prompt.

## Refresh cadence

Every refresh is logged (`/usr/bin/log show --predicate 'subsystem == "dev.motas.app"'`):
duration and per-proxy health. Each proxy read has a 40 s budget and each
request a 20 s cap, so one slow server cannot hold a cycle; Motas opts out of
App Nap while monitoring.

Observed on the 0.2 live run (2026-10-14): ~5 min 20 s between refreshes while
the display is on; after the display has been off for a while macOS coalesces
timers and the gap grows to ~16–18 min; the first refresh fires the moment the
display wakes. Motas accepts this (battery-friendly, data is fresh when the
user looks); v0.3 adds the wake trigger and the panel-open refresh, and
notifications can still lag while the Mac is idle with the display off.

## Facts learned from real responses

- The 2026-11-02 production capture has 29 9Router connections, 26 active:
  Codex 11 (9 active), Qoder 10, OpenRouter 2, Antigravity 2, xAI 2 (1
  active), one openai-compatible, one Chutes.
- 9Router reports `limitReached:false` while `used == total`; Motas computes
  from numbers, not flags.
- Codex free and go accounts are one tier; the production headline is
  "Codex 51 %" (5/9 usable, 4 exhausted, 3 reset credits, next back 17 Nov),
  not a single account at 0 %.
- Qoder: nine connections return "Qoder connected. Usage fetch returned 401."
  and become rejected after two reads; the tenth is active but reports
  `isQuotaExceeded` with zero totals, so it is unmetered with
  "quota exceeded".
- Antigravity groups are "Gemini Models" and "Claude and GPT models"; the
  Claude & GPT lane is its own pool and wears the Claude family colour.
- 9Router's `testStatus`, `errorCode` and `lastError` are dashboard labels of
  the last request and are often weeks old; they never mark an account broken.
- 9Router returns `{plan, message}` without figures for some providers
  (gemini-cli 429/403) → `.unavailable`, never 0 or 100.
- `fetchAvailableModels` omits `resetTime` for some models → `resetsAt` nil.
- CPA Codex reports `primary_window` / `secondary_window` and
  `rate_limit_reset_credits`; CPA Antigravity reports weekly groups; Claude
  through CPA is implemented but not yet captured live.
