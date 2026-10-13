# Motas architecture

```
ProxyConfig ──► ProxyAdapter.fetch() ──► ProxySnapshot ─┐
 (JSON)  secret   CLIProxyAPIAdapter                    ├─► Snapshot ─► Pool.summarize ─► menu bar / panel / widget
 (Keychain)       NineRouterAdapter                     ┘                                  history, notifications
```

## Reading a proxy

| Proxy | List accounts | Per-account quota |
|---|---|---|
| CLIProxyAPI | `GET /v0/management/auth-files` (`Authorization: Bearer <management key>`) | `POST /v0/management/api-call` `{auth_index, method, url, header{"Authorization":"Bearer $TOKEN$"}, data}` — the proxy injects the account token and calls the provider |
| 9Router | `GET /api/providers` (cookie `auth_token` from `POST /api/auth/login {password}`) | `GET /api/usage/{connectionId}` |

Provider URLs used through CLIProxyAPI:

| Provider | URL | Parser |
|---|---|---|
| Codex | `GET chatgpt.com/backend-api/wham/usage` (+ `Chatgpt-Account-Id` from `id_token.chatgpt_account_id`) | `ProviderUsage.codex` |
| Antigravity | `POST {daily-,}cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary {project}` | `ProviderUsage.antigravity` |
| Claude | `GET api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`) | `ProviderUsage.claude` (not yet verified live) |

Never used: `POST /quota/fetch` (501 for built-in providers), `/usage-queue`
(pops records), any reset/switch/delete/config route.

## Facts learned from real responses (2026-10-13)

- Codex free plan: one 30-day window, `secondary_window: null`. Window labels
  come from `limit_window_seconds`.
- 9Router reports `limitReached:false` while `used == total`; Motas computes
  from numbers, not flags.
- 9Router returns `{plan, message}` without figures for some providers
  (gemini-cli 429/403) → `.unavailable`, never 0 or 100.
- `fetchAvailableModels` omits `resetTime` for some models → `resetsAt` nil.

## Pool reserve

Per provider across all healthy proxies: mean of each account's tightest
window. Failed reads count 0, `.unavailable` is unknown (excluded, counted),
disabled accounts are ignored. Menu bar shows the lowest pool.

## Testing

- `Tests/MotasCoreTests/Fixtures/live/` — sanitized real captures
  (`scripts/dev/capture-live.py` → `scripts/dev/sanitize-fixtures.py`).
- `LiveTests` hit real proxies when `MOTAS_LIVE=1`.

## Keychain without a Developer ID

Motas is ad-hoc signed, so every item's partition is `cdhash:<build>`
(securityd only issues `teamid:` partitions to Apple-issued certificates; a
self-signed certificate does not help, and the data-protection keychain needs
a provisioned Team ID). Consequences and handling:

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
