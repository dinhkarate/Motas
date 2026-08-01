# Motas MVP User Stories & First-Run Success

- Status: Accepted
- Date: 2026-07-23
- Roadmap task: `P0.6`

## Product promise

> Motas tells a Mac user whether their AI coding stack is ready before they start a serious session.

Motas combines direct provider quota with local proxy/router health so the user does not discover a failure only after an agent stops responding.

## Primary users

### AI coding power user

Uses two or more of Claude Code, Codex, Gemini CLI, Antigravity, OpenRouter or similar services and wants one glanceable status.

### Local proxy/router user

Runs 9Router, CLIProxyAPI, ProxyPal, LiteLLM or another OpenAI-compatible local gateway and needs to know whether the route and fallback pool are healthy.

### Cautious developer

Does not want credentials uploaded to another service and needs clear local-first behavior.

## MVP user stories

### US-01 — Know whether it is safe to start

As a Mac AI coding user, I want one `Ready`, `Caution`, `Fallback`, `Blocked` or `Proxy Down` state so I can decide whether to start a long coding session.

Acceptance:

- Status is visible in the menu bar.
- Status is visible in the desktop widget.
- A non-ready state includes a concise reason and next action.

### US-02 — See direct provider quota

As a Claude Code user, I want to see my available session/weekly quota and reset time without opening the provider dashboard.

Acceptance:

- The selected direct provider shows available windows when upstream data exposes them.
- Reset time is shown in the user's local timezone.
- Missing or stale data is labeled instead of guessed.

### US-03 — See local proxy health

As a 9Router or CLIProxyAPI user, I want to know whether my local endpoint is reachable and whether useful accounts/providers are available.

Acceptance:

- User can configure an endpoint.
- Motas reports running, unreachable, unauthorized, partial or unknown states.
- The endpoint's last successful check is visible.

### US-04 — Understand fallback readiness

As a proxy power user, I want to know whether a fallback tier is ready when my primary subscription quota is low.

Acceptance:

- Motas shows the active/available tier when the connector exposes it.
- The global state can become `Fallback` rather than incorrectly reporting `Ready`.
- If fallback cannot be verified, Motas says so.

### US-05 — Get warned before interruption

As a developer in a long session, I want an alert when quota enters a configured warning state or a proxy goes down.

Acceptance:

- Notifications are opt-in/permission-aware.
- Thresholds are configurable or have documented defaults.
- State-change cooldown prevents repeated alerts.

### US-06 — Keep credentials local

As a security-conscious developer, I want API keys and management credentials to stay on my Mac.

Acceptance:

- Secrets are stored in Keychain.
- Widget snapshots contain no secrets.
- Logs and diagnostics redact credentials.
- Privacy documentation explains network calls.

### US-07 — Recover from stale/offline data

As a user whose network or provider is unavailable, I want Motas to distinguish stale data from a verified quota state.

Acceptance:

- The UI shows last updated time.
- Stale, offline, unauthorized and unsupported are distinct where possible.
- Motas never turns missing data into a reassuring green state.

## First-run flow

### Step 1 — Install and open

User launches Motas from the downloaded app or Homebrew.

Expected result:

- Menu bar item appears.
- Welcome screen explains the promise in one sentence.
- No account is required for the local-first MVP.

### Step 2 — Choose a first connection

Offer three clear paths:

```text
Connect Claude Code
Connect 9Router
Connect CLIProxyAPI
```

Optional connectors can be added later. Do not present a wall of 20 providers.

### Step 3 — Test connection

User follows a short guided setup or enters a local endpoint.

Expected result:

- Motas tests the connection.
- Any permission/key/config problem explains the fix.
- Credentials are saved only after explicit user action.

### Step 4 — Show first useful state

Motas renders:

```text
AI Stack: Ready / Caution / Fallback / Blocked / Proxy Down

Source status
Last updated
Next reset, where available
```

### Step 5 — Add another source

After the first successful connection, suggest adding a complementary source:

```text
You connected Claude Code. Add 9Router to see fallback readiness.
```

This demonstrates Motas' differentiated value without forcing setup complexity before the first win.

## Two-minute success test

A new tester passes first-run success when they can, within two minutes:

1. Open Motas.
2. Understand what the app does.
3. Connect one supported source or load a safe demo state.
4. See a clear global readiness state.
5. Identify the reason for that state.
6. Find where to add a second provider/proxy.
7. Understand whether data and credentials stay local.

## MVP success metrics

Private alpha targets:

```text
5 testers install successfully.
4 of 5 complete first connection without live hand-holding.
4 of 5 understand the global readiness state.
3 of 5 use Motas for at least three days.
0 critical credential leaks.
```

Public beta targets:

```text
30% or more of installers complete first connection.
At least 5 active users after 7 days.
Fewer than 15% of support requests are caused by unclear onboarding.
No repeated false-Ready reports.
```

## Non-goals for first run

Do not require the user to:

- Create a Motas cloud account.
- Configure every provider.
- Enter credentials for a provider they do not use.
- Understand routing internals before seeing a basic status.
- Read long documentation before the first connection.

## Copy guidelines

Prefer:

```text
Your AI stack is ready.
Claude quota is low; 9Router fallback is healthy.
CLIProxyAPI is reachable, but account data is unavailable.
Last checked 3 minutes ago.
```

Avoid:

```text
100% healthy
Everything is fine
Real-time guarantee
Unlimited fallback
```

when the connector only provides partial or stale information.

## Deferred stories

Not required for MVP first-run:

- Team dashboards.
- Cloud synchronization.
- Automatic account pooling.
- Proxy configuration editing.
- Billing inside the app.
- Full provider marketplace.
- Mobile companion.
