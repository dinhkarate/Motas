# 9Router Connector Research

- Roadmap tasks: `P1.9`, `P1.10`
- Upstream inspected: https://github.com/decolua/9router
- Research date: 2026-07-23

## Supported basic connector behavior

Motas uses:

```text
GET /api/health
```

This route is public and returns:

```json
{ "ok": true }
```

It is the reliable v1 signal for process reachability.

## Protected detail routes

Useful routes include:

```text
GET /api/providers
GET /api/usage/{connectionId}
GET /api/usage/providers
GET /api/usage/stats
GET /api/combos
GET /api/version
```

Except for public allow-listed routes such as `/api/health` and `/api/version`, `/api/*` is protected by the dashboard guard.

Supported authentication methods observed in source:

```text
Cookie: auth_token=<JWT>
x-9r-cli-token: <machine-derived CLI token>
```

If dashboard login is disabled, local requests may access protected endpoints without a JWT. Motas must not assume that configuration.

## Current implementation

`NineRouterConnector`:

1. Calls `/api/health`.
2. Reports `unreachable` when the service cannot be reached.
3. Reports `healthy + partial` when health succeeds but no monitoring credential is available.
4. Optionally calls `/api/providers` using a dashboard cookie or CLI token.
5. Maps safe provider connection fields to normalized account health.
6. Masks email addresses.
7. Does not persist access/refresh/API keys.
8. Leaves quota and fallback availability unknown unless a future decoder receives explicit upstream data.

Source:

```text
Sources/MotasCore/Connectors/NineRouterConnector.swift
```

## Why quota remains partial

`GET /api/usage/{connectionId}` calls provider-specific quota implementations and response shapes vary by provider. It may also refresh OAuth credentials as a side effect.

## Quota

Motas probes `GET /api/usage/{connectionId}` per active OAuth/API-key connection:

```json
{
  "plan": "Claude Code",
  "quotas": {
    "session (5h)": {"remainingPercentage": 13, "resetAt": "1789000000"},
    "weekly (7d)": {"remaining": 40, "total": 100, "unlimited": false}
  }
}
```

Rules:

- `remainingPercentage / 100` wins when present, else `remaining / total`
  (when `total > 0`); entries with neither are skipped.
- `unlimited: true` entries produce no window.
- `resetAt` accepts ISO8601 (with/without fractional seconds) and epoch
  seconds or milliseconds as a string (`< 1e12` is seconds).
- The legacy admin path returns arbitrary JSON under `quotas`, so a
  `quotas`-decode failure degrades to no windows with quality partial —
  never an error state.
- **Never append `?force=1`**: it bypasses 9Router's own 5-minute upstream
  cache and triggers provider 429s.
- HTTP 404 marks the connection permanently unsupported for the process
  lifetime; message-only 200s (`{"message": ...}`) keep the connection
  healthy at quality partial.
- Route aggregation follows the same pool-best rule as CLIProxyAPI.

## Security notes

- Prefer localhost endpoints.
- Dashboard and CLI tokens are stored in the app's Keychain.
- Environment tokens remain development-only process overrides and are never imported into Keychain.
- The normalized snapshot contains only masked account labels and status.
- Motas does not call mutation routes.
- Motas does not start/stop/shutdown 9Router in v1.

## Compatibility risk

9Router is a fast-moving Next.js project and route/response contracts are not presented as a stable external monitoring API. Motas should:

- Version fixture payloads.
- Treat decoding failure as partial data.
- Keep `/api/health` as the minimum compatibility path.
- Add capability detection before depending on protected detail routes.
