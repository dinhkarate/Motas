# Motas v0.3 — refactor design (rev. 2)

Status: this document is the contract for the v0.3 refactor (branch
`refactor/v0.3`).
- **Rev. 1 (2026-11-02):** came from the code review and from a capture of the
  production 9Router.
- **Rev. 2 (2026-11-03):** adds the results of a three-critic design review:
  - a data-truth simulation over all 29 production connections;
  - an architecture review;
  - a product review.

  §14 records what the review changed and which proposals were declined.

Sources of truth:
- Captured production bodies (sanitized, 2026-11-02):
  `Tests/MotasCoreTests/Fixtures/live/9r_prod_*.json`.
- Bodies 9Router v0.5.104 can return but that were not observed:
  `Tests/MotasCoreTests/Fixtures/synthetic/`. Every string is copied from the
  9Router source; see that folder's README.

Non-negotiables from `GOAL.md` still hold:
- Never show a number Motas did not read; unknown stays unknown.
- Secrets live only in Keychain.
- Only read-only proxy calls.

## 0. Review findings this fixes

| # | Finding | Fix |
|---|---|---|
| 1 | One failed refresh wipes a proxy's accounts; "Updated just now" even when every proxy failed | Carried state with staleness (§3) |
| 2 | Spurious or spammy notifications: a pool jumps when a proxy is down; one 429 reads as 0 %; no hysteresis; one timeout means "proxy down" | Failure classes (§2.6) and a stateful `AlertEngine` (§5) |
| 3 | The Keychain lock is held during the system prompt, blocking the main thread and refreshes; one item per proxy means N prompts per update | Single-item store, off-main and non-blocking (§6) |
| 4 | The pool number mixes windows and plans; Antigravity reads 0 % when one model family is out; the menu bar always shows the lowest pool | Pools per (provider, tier, group) with lanes and a pin (§4) |
| 5 | The widget is never reloaded; no refresh on wake or when the panel opens | App lifecycle (§7) |
| 6 | Every account's usage URL is read every cycle with no backoff; User-Agent strings are scattered | Per-account scheduling and backoff (§3), `UpstreamClients` (§2.8) |
| 7 | Minor issues: the deadline timer task is never cancelled; a kind change keeps the old secret; the secret is saved before the settings; Settings pickers break on off-list values | §3, §7, §9 |

New product work:
- 9Router CLI-token auth (§2.4);
- the native desktop widget "Model Pulse" (§9.4);
- CLI provisioning (§8);
- real-proxy fixtures.

## 1. Facts (production 9Router v0.5.104, 2026-11-02)

### 1.1 Listing
- `GET /api/providers` returns `{connections:[…]}`.
- Fields Motas uses: `id, provider, authType, name, email, displayName,
  isActive, testStatus, errorCode, lastError, lastErrorAt, rateLimitedUntil,
  expiresAt, providerSpecificData{chatgptPlanType, chatgptAccountId, nodeName},
  modelLock_<model>`.
- `modelLock_<model>` is an ISO date or null; `modelLock___all` locks the whole
  account.
- 9Router routes by `isActive`, `rateLimitedUntil` and `modelLock_*`.
  `testStatus`, `errorCode` and `lastError` are dashboard labels of the *last*
  request and are often weeks old, so they never mark an account broken.

### 1.2 Usage route `GET /api/usage/{id}`

Source: the compiled route plus `middleware.js`. `?force=1` bypasses
9Router's own usage cache.

| HTTP | Body | Meaning for Motas |
|---|---|---|
| 401 | exactly `{"error":"Unauthorized"}` | The middleware rejected Motas's cookie or token. This is a **session failure**, never a verdict on the account |
| 401 | `{"error":"Credential refresh failed: …"}` | The account's OAuth refresh failed, usually "Refresh token invalid or reused. Please re-authorize the connection." Treat it as a candidate credential rejection |
| 404 | `{"error":"Connection not found"}` | The id vanished between list and read |
| 500 | `{"error":"…"}` | The handler threw, e.g. "Failed to fetch Codex usage: fetch failed". Transient |
| 200 | `{"message":"Usage not available for this connection"}` | An API-key connection without usage support |
| 200 | handler body | See §1.3 |

Before answering, the route retries once with a forced credential refresh when
the handler's message mentions expired, authentication, unauthorized, 401 or
re-authorize. A message that still contains 401 has therefore already survived
one refresh attempt.

### 1.3 Handler bodies (HTTP 200)

Shapes:
- `{plan, quotas, …}`
- `{message}`
- `{message, quotas:{}}`
- `{plan, quotas:{}}` with no message: an optional sub-call failed.

Messages, verbatim:
- **No figures by design:**
  - "Usage API not implemented for xai"
  - "Usage not available for this connection"
  - "iFlow connected. Usage tracked per request."
  - "Ollama Cloud connected. No usage limits reported."
  - "Vercel AI Gateway connected. No credit allocation found (BYOK or unfunded account)."
  - "Claude connected. Usage API requires admin permissions."
  - "Claude connected. Usage details require admin access."
- **Upstream HTTP status inside the text:**
  - Codex: "Codex connected. Usage API temporarily unavailable (<status>)." for
    *every* non-OK status (5xx, Cloudflare 403, 401).
  - Qoder: "Qoder connected. Usage fetch returned <status>."
  - Gemini CLI: "Gemini CLI quota error (<status>)." for every status.
  - Ollama and Vercel: "… API error (<status>)".
- **Antigravity quota API 401/403:**
  - "Antigravity quota API authentication expired. Chat may still work."
  - "Antigravity quota API access forbidden. Chat may still work."

  Both come with `quotas:{}`. The chat credential still works; only the quota
  API refused.
- **Network or parse errors:**
  - "Antigravity error: …"
  - "Claude connected. Unable to fetch usage: …"
  - "Qoder connected. Unable to fetch usage: …"
  - "Gemini CLI error: …"
  - "… response was not JSON."
  - "Unable to fetch iFlow usage."
- **Credential problems:**
  - "… API key invalid or expired."
  - "… API key not available."
  - "Gemini CLI access token not available."
  - "Qoder usage unavailable: no access token"
  - "Gemini CLI project ID not available. Reconnect Gemini CLI, …"

### 1.4 Codex
- **Quota keys:** `session` (primary window), `weekly` (secondary),
  `review_session` / `review_weekly`, and `spark_session` / `spark_weekly`.
- **Window length:** 9Router drops it.
- **Plan:** `plan` is the literal "unknown" when upstream omits it.
- **Reset credits:** `resetCredits.availableCount` is the number of credits
  9Router can spend to restore an exhausted window. Motas never spends them.
- **Usage `plan` is more current than the listing:**
  - connection #4 lists `plus` but reads `free` (lapsed);
  - connection #8 lists `free` but reads `go`.
- **Free and Go:**
  - Both have a single primary window. CPA reports `limit_window_seconds:
    2592000` for free, and the 9Router resets observed were 15–30 days out.
  - They share one limit regime: CPA's
    `rate_limit_upsell.banner_type` is `free_or_go_rate_limit_reached`.

### 1.5 Antigravity
- **Per-model ids** come with a `displayName` and only on the paid tier.
  9Router reads a missing `remainingFraction` as 0.
- **Family buckets** come from a best-effort weekly summary: `gemini_weekly`,
  `gemini_session`, `claude_gpt_weekly`, `claude_gpt_session` ("Gemini
  (Weekly)", "Claude & GPT (5h)").
  - When that call fails the buckets are simply missing.
  - A free-tier account then returns `{plan, quotas:{}}`.
- **9Router's own reconciliation:** it marks a session bucket exhausted only
  when every text model of the family is out. The Gemini text family is
  `gemini-*` without "image"; the Claude family is `claude-*`.
- **Plan:** `plan` is `currentTier.name`, which is "Antigravity" for every
  account. The real tier is `subscriptionInfo.paidTier.name`: "Google AI Plus"
  or "Antigravity Starter Quota".

### 1.6 Claude (via 9Router)
Keys: `session (5h)`, `weekly (7d)` and `weekly <model> (7d)`. The last comes
from `seven_day_<model>` and from `limits[].weekly_scoped`.

### 1.7 Qoder and the rest of production
- **Qoder:**
  - 9 of 10 connections return "Qoder connected. Usage fetch returned 401."
    Their tokens expired 2026-10-18…21 but they are still `isActive`.
  - The 10th returns all-zero credits with `isQuotaExceeded: true`.
- **"Usage not available for this connection":** OpenRouter ×2, Chutes, and
  one OpenAI-compatible node (provider id `openai-compatible-chat-<uuid>`,
  `nodeName` "quotax-oss").
- **xAI:** "not implemented".

### 1.8 Authentication
- **How `/api/*` accepts a request:** either header `x-9r-cli-token: <token>`
  or cookie `auth_token`. The cookie comes from `POST /api/auth/login
  {password}` and is a JWT valid for 24 h.
- **How the token is derived:**
  - token = the first 16 hex characters of
    `sha256(machineId + "9r-cli-auth" + cliSecret)`.
  - `machineId` and `cliSecret` are the trimmed contents of
    `<data-dir>/machine-id` and `<data-dir>/auth/cli-secret`.
  - The data dir is `$DATA_DIR`, by default `~/.9router`.
  - `cli-secret` itself is 64 hex characters and is *not* the token.
- **The token is admin-equivalent:**
  - It passes every `/api` guard. That includes the local-only routes
    (`/api/auth/reset-password`, `/api/tunnel/*`, `/api/mcp/`) and the admin
    routes (`/api/shutdown`, `/api/settings/database`, `/api/version/update`).
  - It is also accepted as a `/v1` key.
  - It never expires. It changes only if `auth/cli-secret` or `machine-id`
    changes on the server.
- **Login responses:**
  - 401: wrong password.
  - 429 `{error, retryAfter}`: lockout. 5 failures lock for 30 s, then 2 min,
    10 min and 30 min.
  - 403 with one of these exact bodies:
    - "Password login is disabled. Use OIDC sign in."
    - "Password login is disabled. Use SAML SSO sign in."
    - "Default password must be changed before remote access. …"
- **Why the lockout breaks everyone:** it is keyed by client IP. Behind Docker
  + nginx every client shares one key, and a scanner keeps it locked (5 548
  attempts on 2026-11-02).

### 1.9 Timing
- Sequential usage calls took about 1–1.5 s each.
- 9Router's Codex and Qoder upstream fetches have no timeout.
- Antigravity makes up to three sequential calls with 10 s timeouts each.

### 1.10 CLIProxyAPI (captured 2026-10)
- **`auth-files` entries:** `auth_index, provider|type, email|label|name,
  disabled, status, status_message, unavailable, cooldowns, quota{signals},
  id_token{chatgpt_account_id, plan_type}, project_id`.
  - `status_message` is "" when there is none.
  - `cooldowns` is `[]` in the captures.
  - There is no `next_retry_after` and no error timestamp.
- **Codex via `/api-call`:**
  - `rate_limit.primary_window` / `secondary_window` carry `used_percent`,
    `limit_window_seconds`, and `reset_at` or `reset_after_seconds`.
  - `rate_limit_reset_credits{available_count, applicable_available_count}`.
- **Antigravity via `/api-call`:**
  - `retrieveUserQuotaSummary` returns `groups[{displayName, buckets[{bucketId,
    window, remainingFraction, resetTime}]}]`. Group names are "Gemini
    Models" and "Claude and GPT models"; `window` is "weekly".
  - The `fetchAvailableModels` shape is `models{id:{displayName,
    quotaInfo{remainingFraction, resetTime}, isInternal?}}`.

## 2. Proxy access layer (MotasCore)

### 2.1 Adapter protocol

```swift
public protocol ProxyAdapter: Sendable {
    /// One cheap call that lists the proxy's accounts. Throws `ProxyAccessError`;
    /// the caller maps any other error (offline URLErrors → `.offline`, else `.unreachable`).
    func listAccounts() async throws -> [AccountDescriptor]
    /// One account's quota. Account-level outcomes are *returned*. Throws only
    /// proxy-level `ProxyAccessError`s (session/token rejected, login locked,
    /// redirect, offline) — the cycle then stops starting reads.
    func readUsage(_ account: AccountDescriptor, force: Bool) async throws -> UsageReading
}

public struct AccountDescriptor: Sendable, Hashable, Codable {
    public var id: String               // 9Router connection id / CPA auth_index
    public var provider: Provider
    public var label: String            // email ?? displayName ?? name ?? id
    public var email: String?
    public var identity: String?        // dedupe key (§4.1): Codex account id, else lowercased email
    public var metadataPlan: String?    // normalised (§2.6); nil for "" / "unknown"
    public var isDisabled: Bool
    public var cooldownUntil: Date?     // 9R max(rateLimitedUntil, modelLock___all) if future; CPA next_retry_after / cooldowns[] instant if future
    public var coolingDown: Bool        // CPA `unavailable == true` (with or without an instant)
    public var lockedModels: [String: Date]   // 9R future modelLock_<model> (not __all); details only
    public var proxyNote: ProxyNote?    // {message, at?}: 9R lastError/lastErrorAt; CPA status_message (non-empty, only when status=="error" || unavailable)
    public var displayHint: String?     // 9R providerSpecificData.nodeName for openai-/anthropic-compatible-* providers
    public var locator: Locator
}
public enum Locator: Sendable, Hashable, Codable {
    case nineRouter
    case cpa(authIndex: String, codexAccountID: String?, projectID: String?)
}

public enum UsageReading: Sendable, Hashable {
    case windows([QuotaWindow], plan: String?, extras: UsageExtras)
    case unavailable(String, recheckAfter: TimeInterval, extras: UsageExtras)   // no figures by design
    case failed(UsageFailure)
}
public struct UsageFailure: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case transient, rateLimited(until: Date?), credentialRejected }
    public var kind: Kind
    public var message: String          // short, human, never contains a secret
}
public struct UsageExtras: Codable, Sendable, Hashable {   // every field optional, decodeIfPresent
    public var resetCredits: Int?       // Codex reset credits available
    public var quotaExceeded: Bool?     // Qoder isQuotaExceeded with no figures
}

public enum ProxyAccessError: Error, Sendable, Hashable, Codable {
    case missingCredential
    case unauthorized(String)
    case loginLocked(until: Date)
    case offline(String)                // URLError notConnectedToInternet / networkConnectionLost / dataNotAllowed / internationalRoamingOff
    case unreachable(String)
    case failed(String)
}
```

### 2.2 HTTP rules (`URLSessionHTTPClient`)
- **Session:** an ephemeral configuration with
  `timeoutIntervalForRequest = 15` and `timeoutIntervalForResource = 20`, a
  hard cap per request. No cookie storage (adapters manage the cookie header)
  and no URL cache.
- **Redirects are refused:** a session delegate answers
  `willPerformHTTPRedirection` with `nil`, so a 3xx comes back as the
  response. Adapters map a 3xx to `ProxyAccessError.failed("Redirected to
  <host> — use the final URL in Settings")`. This keeps a secret header from
  following a redirect to another origin.
- **Plain HTTP is allowed only for local and private hosts:** loopback,
  `*.local`, RFC 1918, 100.64.0.0/10, link-local and IPv6 ULA. For any other
  host the adapter throws `.failed("Refusing to send the secret over plain
  HTTP to <host>")` before sending.
- **Allowed requests:** every request is built by one private function per
  adapter from a closed enum, and a test asserts that nothing else can be sent.
  - 9Router: `GET /api/providers`, `GET /api/usage/{id}` with optional
    `?force=1`, and `POST /api/auth/login` (password mode only). The id must
    match `^[A-Za-z0-9_-]{1,128}$` and is percent-encoded. Any other id is not
    read; it yields `.failed(.transient("Unexpected connection id"))`.
  - CPA: `GET /v0/management/auth-files`, and `POST /v0/management/api-call`
    only to `UpstreamClients` URLs.
- Never log a header, a cookie or a request body.

### 2.3 Proxy configuration

```swift
public enum ProxyAuth: String, Codable, Sendable { case managementKey, password, cliToken }
ProxyConfig += auth: ProxyAuth
```
- When `auth` is missing, decoding defaults it by kind: 9Router → `.password`,
  CPA → `.managementKey`. Old settings therefore load unchanged.
- New 9Router proxies, in the editor and in the CLI, default to `.cliToken`.

### 2.4 9Router adapter
- **`.cliToken`:**
  - Sends `x-9r-cli-token` on the providers and usage requests only; there is
    no login and no cookie.
  - A session 401 throws `.unauthorized("CLI token rejected — machine-id or
    auth/cli-secret changed on the server; derive the token again")`.
- **`.password`:**
  - **Login:** logs in when there is no cookie or the cookie is at least 23 h
    old. Login is single-flight: one in-flight `Task` shared by
    `listAccounts` and every `readUsage`.
  - **Login results:**

    | Result | Effect | Guard |
    |---|---|---|
    | 200 + `Set-Cookie auth_token` | Keep `{cookie, obtainedAt}` | — |
    | 401 | `.unauthorized("Wrong password")` | No login until the secret changes or 30 min pass |
    | 429 | `.loginLocked(until: now + retryAfter)`. `retryAfter` comes from the body, else the `Retry-After` header, else 60 s | No login before that instant |
    | 403 "Password login is disabled…" | `.unauthorized("Password login is disabled on this 9Router — use a CLI token")` | 30 min |
    | 403 "Default password must be changed…" | `.unauthorized("Change the default 9Router password first, or use a CLI token")` | 30 min |
    | Anything else | `.failed("Login HTTP <n>")` | — |

  - **Guards survive refreshes:** the guards live in the adapter, and Monitor
    keeps the adapter until kind, URL, auth or secret changes. A wrong
    password must never feed the lockout.
  - **Session 401** (on providers or usage): drop the cookie, re-login
    (single-flight) and retry the same request once. If that fails, throw
    `.unauthorized("9Router rejected the session")` or the login error.
- **Empty secret:** no credential header is sent. A 401 then means
  `.missingCredential`.
- **Usage status mapping:**

  | Response | Result |
  |---|---|
  | 200 | parse (§2.6) |
  | session 401 | per auth mode, above |
  | any other 401/403 (e.g. "Credential refresh failed…") | `.failed(.credentialRejected(<error text>))` |
  | 404 | `.failed(.transient("Connection no longer on the proxy"))` |
  | 429 | `.failed(.rateLimited(until: Retry-After))` |
  | 5xx | `.failed(.transient(<error text> ?? "HTTP n"))` |
  | 3xx | throw `.failed("Redirected…")` |
  | offline URLError | throw `.offline` |
  | other URLError | `.failed(.transient(describe(error)))` |
- **Listing mapping:**

  | Response | Result |
  |---|---|
  | 200 with `connections` | descriptors |
  | session 401 | as above |
  | 404 | `.failed("9Router API not found at this URL")` |
  | other non-200 | `.failed("HTTP n")` |
  | unreadable JSON | `.failed("Unreadable /api/providers response")` |
  | network errors | `.offline` / `.unreachable` |
- **Descriptor rules:**
  - `isDisabled = isActive == false`.
  - `identity`: Codex `providerSpecificData.chatgptAccountId`, else the
    lowercased email.

### 2.5 CLIProxyAPI adapter
- **`listAccounts`** calls `GET auth-files`:
  - 401/403 → `.unauthorized("Management key rejected")`;
  - 404 → `.failed("Management API not found — enable remote management")`.
- **`readUsage`** goes through `/api-call`, as in 0.2, with `UpstreamClients`
  constants.
  - Upstream status in the envelope:

    | Upstream | Result |
    |---|---|
    | 2xx | parse |
    | 401 | `.credentialRejected("Upstream rejected the account token (401)")` |
    | 403 | transient (same rule as 9Router: Cloudflare and forbidden quota APIs are not credential verdicts) |
    | 429 | rateLimited, with `Retry-After` from the envelope header when present |
    | anything else | transient |

  - Status of `/api-call` itself: 401/403 → throw `.unauthorized("Management
    key rejected")`; anything else non-200 → transient.
- **Unsupported provider:** `.unavailable("Motas cannot read <Provider> quota
  through CLIProxyAPI yet", recheckAfter: 6 h)`.
- **Antigravity without a project id:** `.unavailable("Account has no project
  id", 6 h)`.
- **Descriptor rules:**
  - `identity`: `id_token.chatgpt_account_id`, else the lowercased email.
  - `metadataPlan`: `id_token.plan_type`.
  - Cooldown: parse `next_retry_after`, or a date-like field (`until`,
    `next_retry_after`, `reset_at`) in `cooldowns[]` entries, when present
    and in the future. `coolingDown = unavailable == true`.

### 2.6 Parsing usage bodies (pure functions in `ProviderUsage`)

`ProviderUsage.nineRouter(_ data: Data, provider: Provider) -> UsageReading`
applies these steps; the first that applies wins:
1. The body is not a JSON object → `.failed(.transient("Unreadable usage response"))`.
2. A non-empty `message` → classify it with the table below, **even when
   `quotas` is present**.
3. `quotas` with at least one usable window → `.windows(…)`.
4. `quotas` present, but every entry skipped because `total == 0`:
   - with `isQuotaExceeded == true` → `.unavailable("No figures (Qoder reports
     quota exceeded)", 6 h, extras.quotaExceeded = true)`;
   - otherwise → `.unavailable("No figures reported", 6 h)`.
5. Anything else (no message; `quotas` missing, empty or unparseable) →
   `.failed(.transient("No quota figures in this read"))`.

Message classification. Matching is case-insensitive; the first matching row
wins.

| # | Match | Result |
|---|---|---|
| 1 | contains "chat may still work" | transient |
| 2 | a status code from `\((\d{3})\)`, `returned (\d{3})` or `error: (\d{3})` | 429 → rateLimited(nil); 401 → credentialRejected; 403, 408, 5xx and anything else → transient |
| 3 | "not implemented", "usage not available for this connection", "tracked per request", "no usage limits reported", "no credit allocation", "requires admin" | unavailable(6 h) |
| 4 | "invalid or expired", "re-authorize", "reconnect", "token not available", "no access token", "api key not available" | credentialRejected |
| 5 | "rate limit", "too many requests" | rateLimited(nil) |
| 6 | anything else | transient |

Windows from `quotas` entries:
- **Remaining fraction:**
  - `remainingPercentage / 100` when present;
  - else `(total − used) / total` when `total > 0` and `used` is present;
  - else `remaining / total` when `total > 0`.
- `unlimited: true` → 1.0, with " (unlimited)" added to the label.
- `total == 0` with no percentage → skip the key.
- Clamp to 0…1. `resetsAt` comes from the ISO `resetAt`.
- Group, period, role and label come from the canonical table in §2.7.

Plan normalisation, applied to every plan string, usage and metadata alike:
- trim it;
- `""` or "unknown" (any case) → nil.
- **Antigravity:** prefer `subscriptionInfo.paidTier.name`, else `plan` unless
  it equals "Antigravity". Then strip a leading "Google " or "Antigravity "
  and a trailing " Quota", giving "AI Plus" and "Starter".

Extras:
- Codex `resetCredits.availableCount` (9Router) or
  `rate_limit_reset_credits.applicable_available_count ?? available_count`
  (CPA) → `resetCredits`.
- Qoder `isQuotaExceeded` → `quotaExceeded`.

The CPA parsers (`codex`, `antigravity`, `claude`) return the same
`UsageReading`:
- When an upstream 2xx body carries no figures, they return
  `.failed(.transient("No quota figures in this read"))`. They never return
  `.unavailable`.
- They skip `isInternal` models.

### 2.7 Windows

```swift
public enum WindowRole: String, Codable, Sendable { case limit, model, detail }
public struct QuotaWindow: Codable, Sendable, Hashable, Identifiable {
    public var id: String               // raw key from the proxy
    public var label: String            // full label for account details ("Gemini · Weekly", "Primary", "Claude Sonnet 4.6")
    public var duration: TimeInterval?  // only when the proxy reported it (CPA limit_window_seconds)
    public var remainingFraction: Double
    public var resetsAt: Date?
    public var group: String?           // nil = applies to the whole account
    public var period: String?          // canonical lane id: "primary", "secondary", "5h", "weekly", "daily"; nil for per-model windows
    public var role: WindowRole         // .limit binds the account; .model counts only when its group has no .limit window; .detail never counts
}
```
New fields decode with defaults: `group` nil, `period` nil, `role` `.limit`.

Canonical mapping. `QuotaGroups` owns the group ids, labels and order.

| Provider | Raw key / bucket | Group | Period | Role |
|---|---|---|---|---|
| codex (9R) | `session` / `weekly` | nil | primary / secondary | limit |
| codex (CPA) | `primary_window` / `secondary_window` | nil | primary / secondary | limit |
| codex | `review_session` / `review_weekly` (CPA `code_review_rate_limit`) | review | primary / secondary | limit |
| codex | `spark_session` / `spark_weekly` (CPA `additional_rate_limits` spark) | spark | primary / secondary | limit |
| antigravity (9R) | `gemini_session` / `gemini_weekly` | gemini | 5h / weekly | limit |
| antigravity (9R) | `claude_gpt_session` / `claude_gpt_weekly` | claude-gpt | 5h / weekly | limit |
| antigravity (CPA summary) | group whose displayName contains "Gemini" → gemini; contains "Claude" or "GPT" → claude-gpt; bucket `window` | gemini / claude-gpt | weekly → weekly; 5h, session or hourly → 5h; daily → daily; else raw | limit |
| antigravity | model id containing "image" | image | nil | detail |
| antigravity | model ids `gemini-*` / `claude-*` or `gpt-*` | gemini / claude-gpt | nil | **detail** if the same reading has a `.limit` window for that group, else **model** |
| antigravity | any other key | other | nil | detail |
| gemini-cli | model id containing "flash-lite" or "lite" / "flash" / "pro" / anything else | flash-lite / flash / pro / the model id | nil | limit |
| claude (9R) | `session (5h)` / `weekly (7d)` | nil | 5h / weekly | limit |
| claude (9R) | `weekly <m> (7d)` | `<m>`, lowercased, spaces → "-" | weekly | limit |
| claude (CPA) | `five_hour` / `seven_day` | nil | 5h / weekly | limit |
| claude (CPA) | `seven_day_<m>` | `<m>` | weekly | limit |
| any other | any key | nil | the key | limit |

Labels:
- `QuotaGroups.label(provider:group:)`:

  | Provider | Group labels |
  |---|---|
  | codex | review → "Code review", spark → "Spark" |
  | antigravity | gemini → "Gemini", claude-gpt → "Claude & GPT", image → "Image", other → "Other" |
  | gemini-cli | pro → "Pro", flash → "Flash", flash-lite → "Flash-Lite" |
  | anything else | capitalised id |

- `QuotaGroups.periodLabel(period, duration)`:
  - when `duration` is known: "5-hour", "Daily", "Weekly", "30-day", "N-day"
    or "N-hour";
  - otherwise: primary → "Primary", secondary → "Secondary", 5h → "5-hour",
    weekly → "Weekly", daily → "Daily", anything else capitalised.
- **Never infer a length from the distance to the reset.** A 9Router Codex
  window is "Primary" unless CPA reported its duration.
- `QuotaWindow.label`:
  - limit windows in a group: "<GroupLabel> · <PeriodLabel>";
  - limit windows without a group: "<PeriodLabel>";
  - model windows: the proxy's `displayName`, or the key.

### 2.8 Upstream constants
`UpstreamClients` is one file that holds every provider URL, header and
User-Agent used through CPA `/api-call`. Nothing else hard-codes them.

## 3. Reading cycle

### 3.1 State: plain values with a pure merge

```swift
public struct AccountRecord: Codable, Sendable, Hashable {
    public var windows: [QuotaWindow]?   // last good windows
    public var observedAt: Date?         // when `windows` were read
    public var plan: String?             // last resolved plan
    public var extras: UsageExtras
    public var unavailable: String?      // set ⇔ the account is unmetered (by-design message)
    public var unavailableStreak: Int
    public var lastError: String?        // last failed read's message; nil after a success
    public var failureStreak: Int        // consecutive transient / rate-limited reads
    public var rejectStreak: Int         // consecutive credentialRejected reads
    public var rateLimitedUntil: Date?
    public var nextReadAt: Date?         // nil = due now
}
public struct ProxyState: Codable, Sendable, Hashable {
    public var accounts: [AccountSnapshot]        // last built accounts (for carrying)
    public var records: [String: AccountRecord]
    public var lastSuccessAt: Date?
    public var consecutiveFailures: Int
    public init(seed: ProxySnapshot?)             // rebuilds records from a restored snapshot
    public func due(_ list: [AccountDescriptor], now: Date, force: Bool) -> [AccountDescriptor]
    public mutating func apply(_ outcome: ReadOutcome, config: ProxyConfig, now: Date) -> ProxySnapshot
    public func carried(_ health: ProxyHealth, config: ProxyConfig, now: Date) -> ProxySnapshot
}
public struct ReadOutcome: Sendable {
    public var list: Result<[AccountDescriptor], ProxyAccessError>
    public var reads: [String: UsageReading]      // completed reads only
    public var abort: ProxyAccessError?           // thrown by readUsage; no later read started
    public var notStarted: Int                    // due reads skipped because the budget ran out
}
```

**`due` (order and force).**
- Disabled accounts are never read.
- An account is due when `nextReadAt` is nil or ≤ now.
- `force` also makes due the accounts waiting on backoff or on a rejection
  recheck. It never forces unmetered rechecks, and never reads before
  `rateLimitedUntil`.
- Order:
  1. accounts with windows, oldest `observedAt` first;
  2. never-read accounts;
  3. failed or rejected accounts;
  4. unmetered rechecks.

**`apply` (per completed read).**
- **`.windows(w, plan, extras)`:**
  - store `w` and set `observedAt = now`;
  - plan = usage plan ?? `record.plan` ?? `metadataPlan`;
  - store the extras;
  - clear `unavailable` and `lastError`, set all streaks to 0, and set
    `nextReadAt = nil`.
- **`.unavailable(msg, recheck, extras)`:**
  - `unavailableStreak += 1`.
  - If the record has windows observed less than 24 h ago and
    `unavailableStreak < 3`, handle it exactly like a transient failure with
    message `msg`, so the windows are carried.
  - Otherwise the account becomes unmetered: `windows = nil`,
    `unavailable = msg`, store the extras, `nextReadAt = now + recheck`, and
    reset the other streaks.
- **`.failed(.transient)` and `.failed(.rateLimited(until))`:**
  - keep the windows (they are now stale); set `lastError`;
    `failureStreak += 1`; `rejectStreak = 0`;
  - `nextReadAt = now + min(5 min · 2^(failureStreak − 1), 60 min)`, or the
    rate-limit instant if that is later;
  - store `rateLimitedUntil`.
- **`.failed(.credentialRejected(msg))`:**
  - `rejectStreak += 1`; set `lastError`.
  - Streak 1: keep the windows and set `nextReadAt = nil`, so the account is
    re-read next cycle.
  - Streak ≥ 2: the account is **rejected**, with a recheck every 15 min.
- Accounts without a completed read this cycle keep their record unchanged.
- Accounts missing from a *successful* list are dropped.

**Health comes from the list outcome and is written only in `apply`.**
- **List succeeded and nothing aborted:** `.ok`; `lastSuccessAt = now`;
  `consecutiveFailures = 0`.
- **List succeeded but a read threw:** the completed reads are merged; health
  = `.failed(abort)`; `consecutiveFailures += 1`.
- **List failed:** health `.failed(error)`; `consecutiveFailures += 1`; the
  accounts are the carried `accounts`.

**`carried(health)`** is used for Keychain approval, a missing credential and
other local problems:
- it returns the carried accounts;
- it never changes `consecutiveFailures` or `lastSuccessAt`;
- it never alerts (§5).

**Snapshot quota for an account:**

| State | `quota` | Other fields |
|---|---|---|
| Rejected (streak ≥ 2) | `.rejected(msg)` | — |
| Has windows | `.windows(w)` | `quotaObservedAt = observedAt`, `lastReadError = lastError` |
| Unmetered | `.unavailable(msg)` | — |
| Read failed, no windows | `.failed(lastError)` | — |
| Never read | `.failed("Not read yet")` | — |

### 3.2 `ProxyRead.run` — time is bounded at the source
`static func run(_ adapter:, state:, now:, force:, budget: Duration = .seconds(40)) async -> ReadOutcome`
1. `listAccounts()`. Any non-`ProxyAccessError` error is mapped: offline
   URLErrors → `.offline`, anything else → `.unreachable(describe(error))`.
2. Read `state.due(…)` with `boundedMap` at concurrency 4.
   - A task starts its read only if less than `budget` has elapsed
     (`ContinuousClock`) and no read has aborted.
   - Each request is capped by the 20 s resource timeout.
   - Reads that never start keep their state and are not failures.
3. There is no outer deadline, no cancellation and no timer task. The worst
   case is budget + 20 s.

### 3.3 `Monitor` (actor)
- **Construction:** `init(http:secrets:seed: Snapshot?, now:)`. Seeding
  happens here, so there is no separate async seed call.
- **Refresh:** `refresh(_ configs: [ProxyConfig], force: Bool, reason:
  StaticString) async -> Snapshot`. Enabled proxies are read concurrently.
- **Adapter and state lifetime:**
  - Keep one adapter per proxy, rebuilt when kind, URL, auth or secret
    changes.
  - `states[id]` resets only when kind or baseURL changes.
  - Disabled or removed proxies drop out of the snapshot; their state is
    discarded.
- **Before reading:** the secret is read non-interactively.

  | Secret read result | Snapshot |
  |---|---|
  | `needsApproval` | `carried(.needsKeychainAccess)` |
  | Other Keychain error | `carried(.failed(.failed("Keychain: …")))` |
  | Nil or empty, for an auth that needs one | `carried(.failed(.missingCredential))` |

- **Logging** (`dev.motas.app`, category `refresh`, `.notice`), one line per
  proxy: listed / read / ok / failed / rejected / unmetered / reused / not
  started / milliseconds. Labels are logged `privacy: .private`; secrets are
  never logged.

### 3.4 Snapshot model

```swift
public enum QuotaReading: Codable, Sendable, Hashable {
    case windows([QuotaWindow]); case unavailable(String); case failed(String); case rejected(String)
}
public enum AccountState: String, Codable, Sendable { case active, disabled }   // unknown raw value (legacy "error") → .active
public struct AccountSnapshot: Codable, Sendable, Hashable, Identifiable {
    id, provider, label, email?, identity?, plan?, metadataPlan?, state, quota,
    quotaObservedAt?, lastReadError?, nextReadAt?, cooldownUntil?, coolingDown,
    lockedModels, proxyNote?, extras, displayHint?
}
public enum ProxyHealth: Sendable, Hashable { case ok, needsKeychainAccess, failed(ProxyAccessError) }
ProxySnapshot += lastSuccessAt: Date?, consecutiveFailures: Int
```
- `stateMessage` is replaced by `proxyNote`.
- Every new stored property decodes with `decodeIfPresent` and a default, in a
  hand-written `init(from:)`.
- `ProxyHealth` has a hand-written `Codable`:
  - It writes `{"kind": …, "message"?: …, "until"?: …}`.
  - It also reads the 0.2 synthesized shapes: `{"ok":{}}`,
    `{"unauthorized":{}}` → `.failed(.unauthorized(""))`,
    `{"needsKeychainAccess":{}}`, `{"unreachable":{"_0":…}}` and
    `{"failed":{"_0":…}}`.
  - An unknown kind → `.failed(.failed("Unknown"))`.
- A 0.2 `snapshot.json` must load and seed. The test fixture is
  `Fixtures/legacy/snapshot_v0.2.json`. It is written by encoding a
  representative snapshot with the **0.2 code before the model changes**, and
  covers state "error" with a stateMessage, health unauthorized / unreachable
  / needsKeychainAccess, and windows / unavailable / failed readings.

## 4. Pools

### 4.1 Membership
- Pools include accounts of **every enabled proxy, whatever its health**.
  Carried accounts count while fresh enough; age is handled only by
  `quotaObservedAt` and `staleLimit = max(30 min, 3 × refresh interval)`.
- **Excluded:** disabled accounts, and `.unavailable` (unmetered) accounts.
- **Rejected accounts** are members: they are counted, but they have no value.
- **Dedupe:** within a pool, accounts with the same non-nil `identity` count
  once; the one with the newest `quotaObservedAt` wins. Account rows stay per
  proxy.

### 4.2 Keys and tiers
- `PoolKey(provider, tier, group)`, with `id = "provider|tier|group"` (empty
  strings for nil).
- **Tier, Codex only:** the normalised plan class.
  - free and go → "free";
  - plus, pro, team, business, enterprise and edu stay separate;
  - any other non-empty plan stays as itself;
  - no plan → "".
- Every other provider uses tier "", because plans are not comparable across
  proxies there.

### 4.3 Which pools exist
Per (provider, tier):
- If any member has a `.limit` window with group nil, there is **one pool**
  with group "". Named groups then appear only in account details (Codex
  review/spark, Claude opus/sonnet/…).
- Otherwise every group that appears in a member's `.limit` or `.model`
  windows gets a pool (Antigravity → Gemini, Claude & GPT). `image` and
  `other` never form pools.
- Groups come from current ∪ carried windows. A provider whose reads all fail
  therefore keeps its pools, with unknown counts.
- A provider none of whose accounts ever had windows gets no pool. Its
  accounts are listed with their notes.

### 4.4 Account value in pool (provider, tier, g)
1. **Gather the windows:**
   - `L` = `.limit` windows of group `g`. For a named group, also add the
     `.limit` windows with group nil.
   - `M` = `.model` windows of group `g` (named groups only).
2. **Drop reset windows:** drop any window with `observedAt < resetsAt ≤ now`.
   It has reset since it was read, so its value is unknown.
3. **Classify the account:**
   - Rejected → counted `rejected`, with no value.
   - `quotaObservedAt` is nil or older than `staleLimit` → unknown.
   - Nothing left in L ∪ M → unknown. If the account never had windows for
     `g`, it is not a member of this pool at all.
   - Otherwise value = min(min(L), max(M)), over whichever parts are
     non-empty. A family counts as out only when every text model is out,
     matching 9Router.
4. **Flags:**
   - stale: `quotaObservedAt <` the proxy's `fetchedAt`;
   - exhausted: value ≤ 0.5 %;
   - usable: value > 0.5 %, no future `cooldownUntil`, and not `coolingDown`.
5. **Recovery instant:**
   - Exhausted account: the latest `resetsAt` among the L windows that are
     ≤ 0.5 %. If max(M) is the binding part, the earliest `resetsAt` in M.
   - Cooling account: `cooldownUntil`.

### 4.5 `PoolSummary`

```swift
public struct PoolSummary: Codable, Sendable, Hashable, Identifiable {
    public var key: PoolKey; public var id: String
    public var title: String        // short (§4.6)
    public var displayName: String  // long: "Codex · Free", "Antigravity · Gemini"
    public var reserve: Double?     // mean value over measured; nil if none
    public var members: Int         // measured + unknown + rejected
    public var measured, usable, exhausted, unknown, rejected, stale, coolingDown: Int
    public var lanes: [Lane]        // Lane {id (period or "models"), label, mean, count}
    public var nextRecoveryAt: Date?   // earliest recovery among exhausted/cooling members
    public var nextResetAt: Date?      // earliest reset of any applicable window < 100 %
    public var resetCredits: Int       // sum over exhausted members
}
```
- **Lanes:**
  - Lanes are keyed by `period` over members' `L` windows, and each lane's
    value is the mean over members reporting that period.
  - A member that has only `M` windows for `g` adds to a lane "models", with
    label "Models" and value max(M).
  - The lane label is `periodLabel(period, duration)`. `duration` is the one
    reported by any member for that period.
  - Lanes never come from proxy label text, so CPA and 9Router accounts
    merge.
- **Pure function:** `Pool.summarize(_ snapshot:, now:, staleLimit:) ->
  [PoolSummary]`, in the fixed order of §4.6.
- **Unmetered and disabled accounts:**
  - `Pool.unmetered(_ proxy:)` returns the per-provider unmetered groups: the
    count, the messages with their counts, and quotaExceeded.
  - `Pool.disabled(_ proxy:)` returns the disabled accounts.

### 4.6 Names, order, headline
- **Title:**
  - An Antigravity pool is titled by its group label ("Gemini", "Claude &
    GPT").
  - Otherwise the title is the provider name. Add the tier label ("Free",
    "Plus"…) only when the provider has more than one tier among the current
    pools ("Codex", or "Codex Free" / "Codex Plus"). Add the group label when
    the group is non-empty ("Gemini CLI Pro").
- **Provider names (`Provider.displayName`):**
  - fixed names: codex "Codex", claude "Claude", antigravity "Antigravity",
    gemini-cli "Gemini CLI", xai "xAI", openrouter "OpenRouter", qoder
    "Qoder", chutes "Chutes";
  - `openai-compatible-*` → the descriptor's `displayHint`, else
    "OpenAI-compatible"; `anthropic-compatible-*` likewise;
  - anything else → capitalised.
- **Fixed order** (panel grid, desktop widget, WidgetKit):
  - providers: codex, claude, antigravity, gemini-cli, then alphabetical;
  - tiers: free, plus, pro, team, business, enterprise, edu, others
    alphabetical, then "";
  - groups: `QuotaGroups` order.
  - Never re-sorted by value.
- **Headline (menu bar):**
  1. The pinned pool id (UserDefaults `menuBarPool`) when it is present.
  2. A pinned pool that is missing → the same provider's pool with the most
     members.
  3. Otherwise automatic: the lowest reserve among pools with `measured ≥ 2`.
     If none qualifies, the pool with the most measured accounts; ties go to
     the lower reserve, then to the fixed order.
- **Gauge:** the headline, plus the next pool by the same automatic rule.

On the production capture, this gives the headline "Codex 51 %" (5/9 usable,
next back 17 Nov, 3 reset credits) instead of "Codex · Go 0 %".

## 5. Alerts — `AlertEngine`

A stateful struct in MotasCore; it is pure apart from its own state.

`mutating func evaluate(_ snapshot: Snapshot, pools: [PoolSummary], threshold: Double, refreshInterval: TimeInterval, online: Bool, now: Date) -> [QuotaAlert]`

- **Baseline:** the first evaluation records every condition that is already
  true as alerted, and sends nothing.
- **Confirmed** means the condition held on two evaluations whose
  `snapshot.fetchedAt` values are at least `refreshInterval / 2` apart. A
  manual refresh right after a timer refresh therefore cannot confirm it.
- **Pool low:** `measured ≥ 2` and `reserve < threshold`, confirmed.
  - Sends one alert, e.g. "Codex is low — 18 % · 3/9 usable · next back 17 Nov
    · 3 reset credits".
  - It re-arms silently once `reserve ≥ threshold + 0.05`. There is no
    "recovered" notification.
- **Pool exhausted:** `members ≥ 1`, `usable == 0` and `unknown == 0`,
  confirmed.
  - Sends e.g. "Codex: no usable account until 17 Nov · 3 reset credits".
  - **Pool available** ("Codex: 1 account usable again") is sent only after an
    exhausted alert was sent and `usable > 0`.
- **Proxy down:**
  - Fires when health is `.failed(e)`, with `e` neither `.offline` nor
    `.missingCredential`, and `consecutiveFailures ≥ 2` and `online`.
  - "Back" is sent only after a down alert was sent.
  - `.needsKeychainAccess` and `.missingCredential` never notify; they show
    as banners.
- **Accounts rejected:** fires for accounts whose quota *became* `.rejected`
  since the previous evaluation. The reader has already required two
  consecutive rejected reads.
  - There is one aggregated alert per proxy, e.g. "2 accounts on 9Router need
    re-login: a@x, b@y". After 3 names it continues "…and N more".
  - This applies to every provider, including unmetered ones.
- **Identity:** `QuotaAlert {kind, key, title, body, poolID?, proxyID?}`.
  - At most one alert per (kind, key) per evaluation.
  - The notification identifier is `"\(kind):\(key)"`, so a newer alert
    replaces the older one.

## 6. Secrets — one Keychain item, never on the main thread

**Item and protocol.**
- One generic-password item: service `dev.motas`, account `credentials`, data
  `{"v":1,"secrets":{"<proxy uuid>":"<secret>"}}`, accessible after first
  unlock. After an update macOS asks once, not once per proxy.
- The protocol:

  ```swift
  public enum SecretPresence: Sendable, Equatable { case known(Set<UUID>), locked }
  public protocol SecretStore: Sendable {
      func secret(for id: UUID) throws -> String?        // never prompts; throws .needsApproval
      func presence() -> SecretPresence                  // cache only, never touches Keychain
      func approve() async throws                        // interactive read (user action), fills the cache
      func setSecret(_ value: String?, for id: UUID) async throws
      func invalidate()                                  // drop the cache (external change)
  }
  ```

**`KeychainSecretStore(backend: KeychainBackend)`.**
- **Locks:**
  - `io`: an `NSLock`, taken once per public call. It guards `SecItem*` and
    the process-wide `SecKeychainSetUserInteractionAllowed`.
  - `cache`: an `OSAllocatedUnfairLock<Blob?>`.
  - Lock order is always io → cache.
  - Private `…Locked` helpers do the work; no public method calls another
    public method.
- **`secret(for:)`:**
  - A cache hit returns at once.
  - Otherwise `io.lock(before: now + 0.2)`; if the lock is not acquired, throw
    `.needsApproval`.
  - Then a non-interactive read:
    - `errSecInteractionNotAllowed` or an auth failure → `.needsApproval`;
    - not found → nil, and the empty blob is cached.
- **`approve()` and `setSecret`:** they run on one serial
  `DispatchQueue(label: "dev.motas.keychain")` through a checked continuation.
  - `setSecret` takes `io`, then reads the item **fresh**: non-interactive
    first, interactive if needed. It merges, then calls `SecItemUpdate`, or
    `SecItemAdd` when the item is missing, and finally sets the cache.
  - It never writes from the cache.
- **`KeychainBackend` protocol:** `read(interactive:)`, `write(_:)`
  (update-or-add), `readLegacy(interactive:) -> [UUID: String]` and
  `deleteLegacy(_:)`. The real backend wraps `SecItem*`. Tests use a fake
  whose interactive read can block on a semaphore.

**Legacy migration.** Legacy items have service `dev.motas.proxy` and
account = uuid.
- Migration runs only inside `approve()` (a user action) and only until one
  full pass succeeds; the UserDefaults flag `legacyKeychainMigrated` records
  that.
- Empty values are skipped, and an existing blob key is never overridden.
- Afterwards each legacy item is scrubbed to empty data and deleted, with
  `errSecInvalidOwnerEdit` tolerated.

**In-memory store.** `InMemorySecretStore` is used by tests and the render
tool. It has a `needingApproval` switch.

**Callers.**
- `AppModel.save` and `AppModel.remove` are `async`. Before an interactive
  operation they call `NSApp.activate(ignoringOtherApps: true)`, so the
  prompt comes to the front.
- Only one approval `Task` is in flight at a time.
- Views never call the store; they read `AppModel.secretPresence`.

## 7. App lifecycle (MotasUI)

### 7.1 Ownership
`@MainActor final class AppDelegate: NSObject, NSApplicationDelegate` owns
`let model = AppModel()` and the `DesktopWidgetController`.
- `MotasApp` uses `@NSApplicationDelegateAdaptor` and passes `delegate.model`
  to its scenes. There is no `@StateObject` AppModel, so there is never a
  second model, refresh loop or Monitor.
- `applicationDidFinishLaunching`:
  - sets the activation policy to `.accessory`;
  - starts the model;
  - creates the desktop widget controller.

### 7.2 Refresh triggers
`refresh(force: Bool, reason: StaticString)`; the reason is used only for
logging.

| Trigger | When | Forced |
|---|---|---|
| Timer | every `refreshInterval` | no |
| Launch | at start | no |
| Manual | user action | yes |
| Wake | 10 s after `NSWorkspace.didWakeNotification` | no |
| Panel open | only when the snapshot is older than max(120 s, interval / 2) | no |
| Settings change | only when `proxies` changed | no |

- A change of interval restarts the loop.
- Changes to the threshold or notifications only recompute pools and alerts.
- Coalescing: one refresh in flight plus one queued; a queued forced refresh
  stays forced.

### 7.3 Settings writes
- `SettingsStore.update(_ change: (inout MotasSettings) throws -> Void) throws
  -> MotasSettings` re-reads the file, applies the change and writes
  atomically.
  - A corrupt file throws and is never overwritten with defaults. The panel
    shows a banner "settings.json is unreadable: …".
  - `AppModel` always writes through `update` and adopts the returned value.
- **Saving a proxy:** settings first, then the secret. If the secret write
  fails, the editor reports it, and the proxy shows a missing credential or a
  Keychain-approval need.
- **New secret required:** changing kind, URL or auth method requires a new
  secret. The editor enforces it; the CLI uses `set-secret`.

### 7.4 External changes
- After any change, the CLI posts `dev.motas.settings-changed` through
  `DistributedNotificationCenter` with `deliverImmediately: true`.
- The app observes it with `suspensionBehavior: .deliverImmediately`. On
  receipt it:
  1. reloads settings from disk;
  2. calls `secrets.invalidate()`;
  3. recomputes the secret presence;
  4. refreshes (not forced).

### 7.5 UI-only preferences in `UserDefaults` (`UIPreferences`)
- `menuBarPool: String?`
- `desktopWidget.enabled` (default false)
- `desktopWidget.locked` (default false)
- `desktopWidget.cards: [String]?` (nil = default order)
- `onboardingDone`
- `legacyKeychainMigrated`

The desktop widget frame is saved with `setFrameAutosaveName`. None of these
trigger a refresh, and none are stored in settings.json.

### 7.6 Network
`NWPathMonitor` sets `model.isOnline`. When offline, the panel header says
"Offline" and alerts skip proxy-down.

### 7.7 After every refresh
1. Save the `SharedSnapshot` (§10).
2. Record history.
3. Recompute `WidgetDigest {headlineID, headlinePercent, pools: [id: Int %],
   usable: [id: Int], unhealthyProxies}`.
4. Call `WidgetCenter.shared.reloadTimelines(ofKind: "dev.motas.pool")` only
   when the digest changed and at least 15 min have passed since the last
   reload. A change of proxy health or headline id skips the wait. Only when
   running from an app bundle.

### 7.8 Notifications
`SystemNotifier`:
- **Identifiers and payload:** uses the deterministic identifiers from §5.
  `userInfo` holds `{kind, poolID?, proxyID?}`.
- **Clicks**, handled by a `UNUserNotificationCenterDelegate`:
  - accounts-rejected and proxy-down open the proxy dashboard (9Router
    `baseURL + /dashboard`, CPA `baseURL`);
  - pool alerts open the menu-bar panel, best effort: find the status item
    button and `performClick`, else just activate the app.

## 8. CLI (same binary)

**Entry and environment.**
- `main.swift` stays synchronous:
  `if let code = MotasCLI.run(CommandLine.arguments, env: .live) { exit(code) }`
  then `MotasApp.main()`.
- CLI mode is entered only when `argv[1]` ∈ {`proxy`, `help`, `--help`, `-h`,
  `version`, `--version`}. Anything else launches the app.
- `MotasCLI` lives in MotasCore. `CLIEnvironment` holds `settings`,
  `secrets`, `http`, `readSecret(prompt) -> String?`, `notify()`, `out`,
  `err` and `isTTY`, so tests inject everything. Async store calls are
  bridged with a semaphore; the CLI is not on the main actor.

**Commands.**

| Command | Effect |
|---|---|
| `motas proxy list [--json]` | Shows id, name, kind, auth, enabled, URL, and secret set / missing / locked |
| `motas proxy add --kind 9router\|cliproxyapi --name N --url U [--auth cli-token\|password\|management-key] [--secret-stdin] [--disabled]` | Adds a proxy and prints its id. `--auth` defaults to cli-token for 9router and management-key for cliproxyapi |
| `motas proxy set-secret <id\|name> [--secret-stdin]` | Stores a new secret |
| `motas proxy remove\|enable\|disable <id\|name>` | As named |
| `motas proxy test <id\|name>` | Lists only (9Router `GET /api/providers`, CPA `auth-files`) and prints e.g. "29 connections (26 active): Codex 11, Qoder 10, OpenRouter 2, …" |

**Secret input.**
- `--secret-stdin` reads one line from stdin. On a TTY it reads with
  `readpassphrase`, so nothing is echoed. A secret is never accepted in argv.
- A 9Router cli-token must match `^[0-9a-f]{16}$`. A 64-hex value gets "This
  looks like auth/cli-secret, not the token" plus the recipe (§9.3), and exit
  code 65.

**Keychain.**
- Access is non-interactive by default. On `needsApproval` the CLI prints
  "Keychain needs approval for this Motas build: open Motas → Allow…, or
  rerun with --allow-keychain-prompt" and exits 75.
- `--allow-keychain-prompt` opts in to prompting.

**After every change** the CLI posts the distributed notification (§7.4).

**Exit codes.**

| Code | Meaning |
|---|---|
| 0 | OK |
| 64 | Usage error |
| 65 | Bad input |
| 69 | Proxy unreachable (`test`) |
| 75 | Keychain approval needed |
| 1 | Anything else |

**Help and Homebrew.**
- `--help` includes the token recipe and the warning that the token is
  admin-equivalent.
- The Homebrew cask gains `binary "#{appdir}/Motas.app/Contents/MacOS/Motas",
  target: "motas"`.

## 9. UI

Shared tokens in `MotasDesign`:
- `Design.level(fraction, threshold) -> .good | .low | .critical`:
  - critical: ≤ 0.5 % or below threshold / 2;
  - low: below threshold;
  - good: otherwise.

  It is the one colour rule for the menu bar, panel, desktop widget and
  WidgetKit.
- `Design.percent(_:)`: one decimal, with ".0" dropped. Used everywhere
  except the menu bar.
- `Design.percentWhole(_:)`: used by the menu bar.
- Family marks and accents:

  | Family | Mark | Accent |
  |---|---|---|
  | codex | "O" | #d9dde5 |
  | antigravity gemini | ✦ | #7ba7ff |
  | claude-gpt and claude | "A" | #e58a68 |
  | xai | 𝕏 | #f2f4f8 |
  | others | first letter | #c7ccd6 |

### 9.1 Menu bar
- **Content:** the gauge (headline + second pool) and the text
  `"<title> <whole %>"`.
- **Dim:** when the headline's measured accounts are all stale, or its
  reserve is nil.
- **Glyphs:**
  - `key.fill` while any proxy needs Keychain access; this replaces dimming
    as the signal.
  - `⚠︎` for actionable problems:
    - a proxy failed, while online, with `consecutiveFailures ≥ 2` (not
      offline, not a missing credential);
    - unauthorized or login-locked, immediately;
    - rejected accounts in a metered pool.
- **No proxies:** "Motas" plus a setup prompt in the panel.

### 9.2 Panel (width 340, scroll height ≤ 560)

**Header.**
- Title.
- Status: "Updated 2 min ago" when every enabled proxy is fresh; "1 of 2
  proxies stale · data from 14 min ago"; or "Offline".
- Refresh button, which spins while refreshing.

**Banners.**
- Motas errors: settings unreadable, secret write failed.
- Keychain approval: "Motas needs Keychain access for this build" with
  `Allow…`.
- Per proxy problem: the message, the age of the data shown, and `Open
  dashboard`.

**First-run card.** Shown once, after the first successful refresh: toggles
for "Show Model Pulse on desktop" and "Launch at login", and Done.

**Pool grid.** Two columns of compact cards (about 64 pt), in the fixed order.
- Each card shows:
  - the title in small caps;
  - the big %;
  - a meter coloured with `Design.level`;
  - detail "5/9 usable · back 17 Nov · 3 reset credits";
  - a lanes line only when there is more than one lane ("Primary 40 % ·
    Secondary 80 %");
  - stale / unknown markers.
- Context menu: Pin to menu bar / Unpin; Show on desktop / Hide from desktop.
- Tapping a card filters the account list to that pool's provider and tier;
  tapping again clears the filter. There are no provider pills.

**Proxy sections.**
- **Header:** name, health dot, kind, `Open dashboard`, and the data age when
  stale.
- **Per provider:** metered providers first, in the fixed order.
  1. Usable accounts, tightest first, as rows.
  2. One collapsed line "Exhausted ×4 · next back 17 Nov · 3 reset credits";
     it expands to rows.
  3. One collapsed line "Needs re-login ×9"; it expands to rows with each
     message.
  4. Accounts with unknown values or failed reads, as rows.
- **Per proxy, after the providers:**
  - one line "Disabled: Codex ×2, xAI";
  - one collapsible "Not metered: OpenRouter ×2 · Chutes · xAI · quotax-oss ·
    Qoder (quota exceeded)", which lists each account's message.

**Row.**
- **Content:**
  - provider badge and label;
  - plan chip, e.g. "FREE". When the metadata plan differs from the usage
    plan, the chip reads "FREE · was PLUS" in amber, with the tooltip "Sign-in
    says Plus, usage says Free".
  - one mini bar per pool group (Antigravity bars carry tiny "G" / "C&G"
    tags);
  - the percent.
- **One note line**, the first that applies:
  1. needs re-login (with its message);
  2. "Cooling down until 14:05", or "Cooling down";
  3. read failed, e.g. "Read failed · showing data from 14 min ago";
  4. "Ran out · back 17 Nov", plus "· 1 reset credit" in amber when credits
     exist;
  5. the proxy note. For 9Router only when `lastErrorAt` is within 24 h; for
     CPA only when the status is error or the account is unavailable.
- **Context menu:** Copy email, Copy connection id, Open dashboard.
- **Expanded row** (on click):
  - windows grouped with limit first, then model and detail windows compact;
  - reset times;
  - observed age;
  - the next read time when backing off;
  - model locks;
  - extras.

**Footer.** History, Settings, desktop widget toggle, Quit.

### 9.3 Settings
**Proxies tab.** A list with status dots and an editor:
- **Fields:** kind, name, URL, auth, and a `SecureField` for the secret.
- **9Router auth:** "CLI token (recommended)" is the default for new proxies;
  "Dashboard password" sits under "Other sign-in".
- **Help for the CLI token:** "Permanent admin key for this 9Router. Motas
  only uses it for two read-only requests." It is followed by the recipe,
  with a copy button:

  ```
  docker exec <container> sh -c 'd=${DATA_DIR:-$HOME/.9router}; printf %s%s%s "$(cat $d/machine-id)" 9r-cli-auth "$(cat $d/auth/cli-secret)" | sha256sum | cut -c1-16'
  ```

  and then "To rotate it, delete auth/cli-secret on the server."
- **Validation:** the same as the CLI.
- **Test:** listing only. It shows "29 connections (26 active): Codex 11,
  Qoder 10, …" or the mapped error.

**General tab.**
- Refresh interval and warn-below pickers. Both include the current value
  even when it is not a preset.
- Notifications toggle and "Send test".
- Launch at login.
- Menu-bar pool picker: Automatic, the current pools, and the pinned id even
  when it is absent.
- Desktop widget: show, lock position, reset position.

**Behaviour.** Saving is async and shows progress or the error.

### 9.4 Native desktop widget "Model Pulse"
It replaces the user's Übersicht widgets
(`~/Library/Application Support/Übersicht/widgets/codex-quota.widget/index.jsx`
is the visual reference: read it). It is drawn from the live `AppModel`.

**Window.** `DesktopWidgetController` owns one `NSPanel`:
- style `[.borderless, .nonactivatingPanel]`;
- level `CGWindowLevelForKey(.desktopIconWindow) + 1`;
- collection behaviour `[.canJoinAllSpaces, .stationary, .ignoresCycle]`;
- `hidesOnDeactivate = false`;
- `isMovableByWindowBackground = !locked`.

**Placement.**
- It is shown and hidden with `orderFront` / `orderOut`, never closed.
- Default origin: 30 pt from the left and 300 pt from the top of the main
  screen's visible frame.
- The frame is clamped to a visible screen on
  `NSApplication.didChangeScreenParametersNotification`.
- Right-click menu: Lock position, Hide, Open Motas Settings.

**Look.** A dark rounded panel about 340 pt wide, with the eyebrow "AI
CAPACITY", the title "Model Pulse" and a refresh button.
- **Pool card:**
  - the family mark and accent;
  - the title in uppercase ("CODEX", "GEMINI", "CLAUDE & GPT");
  - the big number in the accent colour (`Design.percent`);
  - a meter in the `Design.level` colour; pools with ≤ 3 members show one
    thin meter per account;
  - detail, e.g. "Free · 5/9 usable" or "AI Plus + Starter · 2/2 usable".
- **Status card** for an unmetered provider added with "Show on desktop":
  - "LIVE": at least one active, non-rejected account on a healthy proxy;
  - "CHECK": connections exist but the proxy is unhealthy or all of them are
    rejected;
  - "OFF": none active;
  - the old dashed idle meter.
- **Footer:** "ALL PROXIES CONNECTED", "1 PROXY STALE" or "OFFLINE", and the
  age.

**Cards.** `desktopWidget.cards` gives the order; when it is unset, metered
pools appear in the fixed order. At most 6 cards; never re-sorted by value.

### 9.5 WidgetKit widget
- It reads the `SharedSnapshot`'s precomputed pools and headline and never
  recomputes them.
- It shows the age with `Text(date, style: .relative)` and colours with
  `Design.level` using the saved threshold.

### 9.6 History
- One line per pool id. The title comes from the saved pool titles, else the
  id.
- It covers 7 days.

## 10. Persistence
- **`settings.json`:** `proxies` (with `auth`), `refreshInterval`,
  `lowReserveThreshold`, `notificationsEnabled`. Unknown or missing keys
  decode to defaults.
- **UserDefaults:** see §7.5.
- **`SharedSnapshot`** (app-group container): `{snapshot, threshold, pools,
  headlineID, staleProxies, unhealthyProxies, savedAt}`. It is written by the
  app only.
- **`history.json`:** `PoolSample{at, pool, reserve}`.
  - It is decoded element by element, and bad elements are skipped.
  - Legacy provider-keyed samples are dropped; their old provider means are
    not comparable with tiered pools.
  - It keeps 7 days, with at most one sample per pool per refresh interval.
- **Not in v0.3:** per-account history and sparklines (deferred, §14).

## 11. Tests (swift-testing, offline)
- **Parsers:**
  - every `9r_prod_*` and `synthetic/*` fixture maps to its expected
    `UsageReading`, including the message table row by row;
  - the CPA fixtures; plan normalisation; Antigravity roles;
  - Claude 9Router keys;
  - Codex labels: Primary via 9Router, 30-day via CPA.
- **Adapters:**
  - the allowed-request whitelist, with id validation;
  - the CLI token sent only on providers and usage;
  - session 401 → re-login once (password) or `.unauthorized` (token), with
    zero rejected accounts;
  - "Credential refresh failed" → credentialRejected;
  - login 401 / 429 / 403 guards;
  - redirects refused; plain HTTP refused for public hosts.
- **`ProxyState`:**
  - `apply` as a pure function: windows, unavailable (with the 24 h / 3-read
    rule), transient backoff, rate-limit instant, reject debounce (1 read →
    stale and re-read; 2 → rejected), list failure → carried, abort →
    carried;
  - `due` order and force semantics;
  - seeding from the legacy 0.2 snapshot fixture.
- **`ProxyRead.run`:** the budget stops new reads, with a stub that throws
  `URLError(.timedOut)` and never sleeps; an abort stops later reads.
- **Monitor:**
  - `needsKeychainAccess` → carried accounts with no alert;
  - a URL change resets state; a secret change keeps it.
- **Pools:**
  - the full production set → headline "Codex 51 %", Codex free + go merged,
    Antigravity Gemini / Claude & GPT pools equal to the family buckets.
    Build it by serving `9r_prod_providers.json` and
    `9r_prod_usage_by_connection.json` (connection id → `{status, body}`, all
    29 connections, sanitized) through the real `NineRouterAdapter` with `now`
    = 2026-11-02T16:10:30Z. Expect: Codex 9 members, reserve ≈ 0.513, 5
    usable, 4 exhausted, 3 reset credits, next recovery 2026-11-17; Gemini ≈
    0.992; Claude & GPT 1.0; Qoder ×9 rejected after two refreshes;
  - an image model at 0 % with the bucket at 98 % → 98 %;
  - rejected excluded from reserve but counted in members;
  - reset since read; the stale limit; dedupe by identity; reset credits;
  - lanes merged across CPA and 9Router;
  - unhealthy-proxy accounts counted (this inverts the 0.2 test).
- **`AlertEngine`:**
  - baseline;
  - time-based confirmation;
  - pool low only when measured ≥ 2;
  - exhausted / available;
  - offline suppresses down;
  - Keychain never alerts;
  - aggregation; deterministic ids.
- **Keychain store** (fake backend):
  - blob round trip;
  - non-interactive read during a blocked interactive read →
    `needsApproval` in under 0.3 s;
  - a write during a pending approval does not deadlock;
  - migration rules; `invalidate`; presence.
- **`SettingsStore.update`:** a CLI-added proxy B survives an app-side update
  that only knew A; a corrupt file throws and is not overwritten.
- **CLI:** parsing; every command against temp paths and in-memory secrets;
  token validation; exit codes; the notification is posted.
- **Backward decoding:** 0.2 settings, snapshot and history fixtures.
- **AppModel:**
  - triggers: proxies changed → refresh, UI prefs → none;
  - external-change reload;
  - WidgetDigest throttling;
  - offline handling.

## 12. Tooling
- **`motas-render`:**
  - **Offline fixture mode (the default):** builds a snapshot from the
    `9r_prod_*` fixtures through the real `NineRouterAdapter` and a stub
    HTTP client. No network.
  - **Live mode:** `MOTAS_9R_URL` + `MOTAS_9R_TOKEN`, run via `keyshroud`.
  - **Renders:** menu bar, panel (plus expanded rows), settings proxies and
    general tabs, editor, history, WidgetKit small and medium, desktop
    widget, first-run card.
- **`scripts/dev/capture-live.py`:** supports the CLI token
  (`NINE_ROUTER_CLI_TOKEN`) and records per-call timings.

## 13. Build rules for this refactor
- Build only with `nice -n 10 swift build -j 4`. Test with
  `nice -n 10 swift test -j 4 [--filter …]`. Run one build at a time.
- Never run `scripts/build-app.sh`; release packaging is done separately.
- Swift 6 language mode; stay strict-concurrency clean; macOS 14 APIs only
  (`Synchronization.Mutex` needs macOS 15, so use `OSAllocatedUnfairLock`).
- Never print a secret. Live calls go only through `keyshroud run`.
- No network, Keychain, `~/Library/Application Support/Motas`, `/Applications`
  or running-app access from tests or implementation agents.

## 14. Design review log (rev. 2)

**Adopted.**
- **9Router classification:**
  - the session 401 is told apart from account 401s;
  - the ordered message table;
  - message wins over `quotas`;
  - empty `quotas` → transient;
  - the 24 h / 3-read guard before an account becomes unmetered.
- **Accounts and plans:**
  - Qoder 401 → credential rejection;
  - credential rejection requires two consecutive reads;
  - plan normalisation, including "unknown" and the Antigravity paid tier;
  - the lapsed-plan chip.
- **Pools:**
  - Codex free + go merged into one tier;
  - headline rules with measured ≥ 2;
  - canonical lanes keyed by period;
  - window roles (per-model detail, image and other never pooled);
  - Claude 9Router keys;
  - rejected accounts excluded from reserve;
  - pools count accounts regardless of proxy health;
  - the precise reset-since-read rule;
  - dedupe by identity;
  - reset credits on cards, notes and alerts.
- **Reading cycle:** the single-actor value-state architecture with a pure
  merge; time bounded at the source; Keychain approval carries data; seeding
  in `init`.
- **Keychain store shape:** the io/cache locks, the dedicated queue, presence
  from cache only, writes that re-read first.
- **CLI ↔ app sync:**
  - `SettingsStore.update`;
  - delivered-immediately notifications;
  - UI prefs moved to UserDefaults;
  - the CLI is non-interactive by default with exit 75;
  - `readpassphrase`.
- **CLI token handling:**
  - the token is the 9Router default, with the recipe and validation;
  - its admin scope is documented;
  - the request whitelist;
  - redirects refused; plain HTTP limited to private hosts.
- **Alerts:**
  - debounced by time, not by evaluation count;
  - "pool exhausted" and "available" alerts;
  - no "recovered" noise;
  - offline suppression;
  - deterministic ids and click actions.
- **WidgetKit:** reads precomputed pools; reloads gated by the digest.
- **Desktop widget:**
  - `AppDelegate` owns the model and the `NSPanel`;
  - fidelity to Model Pulse: title, fixed order, marks and accents, status
    cards, one-decimal values, a single colour rule, default origin and
    clamping.
- **Panel:**
  - compact pool grid as the filter;
  - exhausted / re-login / disabled / not-metered lines;
  - Open dashboard and copy actions;
  - the key glyph;
  - the first-run card;
  - provider display names.
- **Backward decoding:** hand-written `Codable` for legacy 0.2 files; history
  decoded element by element; legacy samples dropped.

**Modified.**
- **Codex window labels.** Product and architecture proposed "30-day" /
  "5-hour" inferred from the tier. Rev. 2 labels 9Router windows
  "Primary" / "Secondary" unless CPA reported the duration, because inferring
  a length breaks "never show a number Motas did not read". The lanes line is
  hidden for single-lane pools, so free-tier cards show no label at all.
- **Rejected accounts of unmetered providers (Qoder).** They notify, once,
  aggregated, after the baseline, and show "Needs re-login ×9". They do not
  raise the menu-bar `⚠︎`, which is reserved for metered pools and proxy
  problems.
- **Antigravity family value without buckets** = max over text models,
  following 9Router's own reconciliation.

**Declined or deferred.**
- **Per-account history and sparklines:** deferred. On 30-day windows they
  show a flat line.
- **A first-run line telling the user to turn off Übersicht:** declined.
  Übersicht is not installed on this Mac.
- **An "also on <proxy>" row note for duplicated accounts:** declined;
  dedupe happens in pool math only.
- **Richer CPA cooldown parsing:** deferred until a cooling-down account is
  captured.
- **"Redeem reset credit":** declined. Motas stays read-only and shows `Open
  dashboard` instead.

## 15. Implementation stages
Each stage leaves the package building and every test green. Later stages
own the remaining work; do not reach ahead.
- **S1 — read path:**
  1. Write the legacy 0.2 fixtures first.
  2. Then: Model, `ProxyConfig.auth`, the HTTP client rules, `UpstreamClients`,
     parsers, both adapters, `ProxyState` / `ProxyRead` / `Monitor`.
  3. Keep `Pool`, `Alerts` and the UI compiling with minimal adaptation.
- **S2 — derived data:** `Pool` redesign, `AlertEngine`, history,
  `SharedSnapshot` with precomputed pools, `SettingsStore.update`, the
  `UIPreferences` type.
- **S3 — secrets and CLI:** `KeychainSecretStore` rewrite and migration,
  `MotasCLI`, `main.swift`, the cask `binary` stanza.
- **S4 — app lifecycle:** `AppDelegate` ownership, `AppModel` (async saves,
  presence, triggers, external changes, network, alerts, WidgetDigest),
  `SystemNotifier`.
- **S5 — UI:** `Design` tokens, menu bar, panel, settings, history, the
  WidgetKit view, the `motas-render` modes and renders.
- **S6 — desktop widget:** `DesktopWidgetController` plus the Model Pulse
  view, settings and panel toggles, renders.
- **S7 — docs:** README, `docs/architecture.md`, `GOAL.md` v0.3 done-criteria,
  `capture-live.py`.

## 16. Implementation notes
- S1: Message-table row 3 also matches "require admin". §1.3 lists "Claude
  connected. Usage details require admin access.", which the "requires admin"
  needle misses.
- S1: The 9Router adapter applies the plain-HTTP guard only when it sends a
  secret (token or password). A 9Router without login and without a secret
  has nothing to leak. CPA always sends its key, so it always checks.
- S1: Only `.cliToken` and `.managementKey` need a secret before Monitor reads
  (`ProxyAuth.needsSecret`). `.password` may be empty because a 9Router can run
  without login; nothing is sent then, and a 401 is `.missingCredential`
  (§2.4).
- S1: `ProxyState(seed:)` gives 0.2 windows, which have no `quotaObservedAt`,
  the proxy's `fetchedAt`, so carried legacy figures age like any other.
  Snapshots store no URL, so a seeded state is adopted by the first config of
  the same kind; later URL changes reset it as usual.
- S1: `ProxyRead.run` also takes `clock: some Clock` (default
  `ContinuousClock()`), so the budget test runs on a test clock and never
  sleeps.
- S1: `Monitor.test(_:secret:)` lists only and returns
  `Result<[AccountDescriptor], ProxyAccessError>` for the editor's Test button
  (§9.3).
- S1: Gemini CLI windows have a group but no period, which the §2.7 label
  rules do not cover. They are labelled like model windows (display name, else
  the model id), so two models of one family stay distinguishable.
- S1: The login 429 body's `retryAfter` is read as seconds (the §1.8 lockout
  steps run from 30 s to 30 min). A `Retry-After` header may be seconds or an
  HTTP date.
- S2: A rejected account keeps no windows, so it joins every pool of its
  provider and tier but never creates one. When every account of a provider
  and tier is rejected (production Qoder), there is no pool; the accounts
  show in their proxy section and in the rejected alert.
- S2: `.limit` windows without a period (Gemini CLI models) add to no lane,
  so such a pool has a reserve and no lanes. §4.5 gives no lane order; lanes
  follow primary, secondary, 5h, daily, weekly, other periods alphabetically,
  then "models".
- S2: An exhausted account that is also cooling down comes back at the later
  of its window recovery (§4.4 step 5) and `cooldownUntil`.
- S2: `QuotaAlert` splits the §5 texts into a title and a body: "Codex is
  low" / "18% · 3/9 usable · next back 17 Nov · 3 reset credits", and "Codex:
  no usable account" / "Until 17 Nov · 3 reset credits". Days use the en_GB
  "17 Nov" form in the user's time zone.
- S2: Proxy down has no time confirmation: two failed refreshes in a row
  already confirm it, and §5 confirms only pool conditions. `evaluate` keeps
  its `now` parameter, but confirmation uses `snapshot.fetchedAt`, as §5
  says.
- S2: `SharedSnapshot.staleProxies` counts proxies whose health is not `.ok`
  (their accounts are carried). `unhealthyProxies` counts
  `ProxySnapshot.isUnhealthy`, the §9.1 ⚠︎ proxy rule without "while
  online", which a saved file cannot know.
- S3: Every Keychain read error gives `.needsKeychainAccess`, not only
  `.needsApproval`. Keychain trouble is Motas's own problem, never a proxy
  failure, so it never alerts and never counts as unhealthy. Allow… retries
  the read with a prompt and reports any other error; Monitor logs it.
- S3: While `legacyKeychainMigrated` is unset, `secret(for:)` also checks,
  without a prompt, for 0.2 items that still hold a secret. If there are any,
  or macOS wants approval to tell, it throws `.needsApproval` and caches
  nothing, so an upgraded 0.2 user is offered Allow… (which migrates) instead
  of seeing missing credentials. `setSecret` leaves the cache empty in that
  case for the same reason. Only `approve()` sets the flag.
- S3: `approve()` fills the cache even when the migration fails, then throws
  the migration error; the next approval tries the migration again.
- S3: `KeychainSecretStore(backend:preferences:)` also takes the
  `UIPreferences` that hold the flag, so tests inject a suite. The CLI passes
  the app's domain: through the Homebrew symlink `Bundle.main` is the
  symlink's directory and `.standard` a domain of its own, so the CLI finds
  Motas.app by resolving its executable's symlinks (also for `version`).
- S3: An item that is not a v1 blob throws `errSecDecode` and is never
  overwritten, so a newer build's format survives a downgrade.
- S3: `SystemKeychain.readLegacy` lists the 0.2 items' attributes, then reads
  each item: the file-based login keychain returns no data with
  `kSecMatchLimitAll`.
- S3: CLI details:
  - `set-secret` without `--secret-stdin` prompts only on a TTY; with piped
    stdin and no flag it exits 64.
  - 64 is a usage error: unknown command or option, a missing or extra
    argument, a bad `--kind` or `--auth`, a kind/auth mismatch, and an unknown
    or ambiguous `<id|name>`, which lists the candidates. 65 is a bad value:
    an empty name, a bad URL, a rejected or missing secret, plain HTTP to a
    public host with a secret.
  - Rejected arguments are never echoed, since one may be a mistyped secret.
  - Commands that touch a secret check Keychain access before changing
    anything, so a 75 leaves settings.json and the item as they were. `list`
    shows "locked" instead of failing; `enable` and `disable` never touch
    Keychain. `--allow-keychain-prompt` is accepted by every proxy command.
  - `add` writes settings first, then the secret (§7.3); `remove` deletes the
    secret after the settings change.
  - `test` exits 69 when offline or unreachable and 1 for any other failure
    (a rejected token, a missing credential), printing the proxy summary.
- S3: `ProxyAuth.problem(with:)`, `ProxyAuth.cliTokenRecipe`,
  `ProxyConfig.baseURL(from:)` and `AccountDescriptor.summary(_:)` live in
  MotasCore so the Settings editor can share them with the CLI (S5).
