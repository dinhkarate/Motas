# CLIProxyAPI Connector Research

- Roadmap tasks: `P1.11`, `P1.12`
- Upstream inspected: https://github.com/router-for-me/CLIProxyAPI
- Official docs: https://help.router-for.me/management/api
- Research date: 2026-07-23

## Supported basic connector behavior

Motas uses:

```text
GET /v1/models
```

for basic proxy reachability and model availability.

If the proxy requires a client API key, Motas sends:

```text
Authorization: Bearer <PROXY_API_KEY>
```

## Management API

The management base path is:

```text
/v0/management
```

Management routes require a separate management credential:

```text
Authorization: Bearer <MANAGEMENT_KEY>
```

Important routes inspected:

```text
GET /v0/management/config
GET /v0/management/latest-version
GET /v0/management/auth-files
GET /v0/management/auth-files/models
GET /v0/management/quota-exceeded/switch-project
GET /v0/management/quota-exceeded/switch-preview-model
GET /v0/management/usage-statistics-enabled
GET /v0/management/usage-queue
```

## Current implementation

`CLIProxyAPIConnector`:

1. Calls `/v1/models`.
2. Reports unreachable, unauthorized, degraded or healthy accurately.
3. Without management access, reports `healthy + partial` and model count.
4. With a management key, calls `/v0/management/auth-files`.
5. Maps `active`, `error`, `disabled`, `unavailable` and disabled flags into account health.
6. Uses stable `auth_index` when available.
7. Masks account emails.
8. Uses healthy account presence only as a basic pool/fallback signal.
9. Does not claim precise quota windows from auth-file status.

Source:

```text
Sources/MotasCore/Connectors/CLIProxyAPIConnector.swift
```

## Usage queue policy

Legacy aggregated endpoints are removed. Current CLIProxyAPI exposes:

```text
GET /v0/management/usage-queue?count=N
```

The endpoint pops records from the queue. Motas v1 must **not poll it by default**, because monitoring would consume telemetry intended for other clients.

Possible future options:

- Redis usage queue subscriber with explicit opt-in.
- A companion persistence service.
- A non-destructive upstream API if CLIProxyAPI adds one.

## Quota limitations

`auth-files` exposes runtime account availability, status messages, request counters and retry metadata. It does not provide a uniform 5-hour/weekly percentage for every provider.

Precise quota requires:

- Provider-specific upstream inspection through controlled management API calls; or
- A dedicated companion such as a quota inspector; or
- A future stable CLIProxyAPI quota endpoint.

Motas therefore reports account health and partial data instead of inventing percentages.

## Security notes

- Proxy API key and management key are distinct.
- Both must eventually be stored in Keychain.
- Management API can mutate configuration; Motas v1 uses GET-only endpoints.
- Remote management should remain disabled unless explicitly required.
- Prefer localhost (`127.0.0.1:8317`).
- Motas does not call `/reset-quota` or other mutation routes.

## Compatibility behavior

- HTTP 404 on management routes means disabled/unavailable management API, not proxy outage.
- HTTP 401/403 on `/v1/models` means the proxy is reachable but client authorization failed.
- HTTP 401/403 on `/auth-files` means basic proxy health can remain healthy while monitoring detail is partial.
- Unknown account status maps to `unknown`, not healthy.
