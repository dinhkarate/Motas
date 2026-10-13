# Motas Product Differentiation

_Last updated: 2026-07-22_

## Decision

Motas should **not** be positioned as just another Claude/Codex/Gemini menu bar quota tracker.

That market already has many tools:

- ClaudeBar
- CodexBar
- SessionWatcher
- TokenBar
- ClaudeUsageBar
- ClaudeMeter
- Claude usage desktop widgets

Instead, Motas should differentiate as:

> **A Mac-native quota and proxy health widget for the whole AI coding stack.**

Short positioning:

> **Motas — AI quota and proxy health, always visible on your Mac.**

Long positioning:

> Motas tells you whether your AI coding stack is ready before you start — across Claude, Codex, Gemini, Antigravity, and local proxy/router systems such as 9Router, CLIProxyAPI, and ProxyPal.

---

## Core differentiation

Most existing apps answer:

```text
How much Claude/Codex/Gemini quota do I have left?
```

Motas should answer:

```text
Can I start a serious AI coding session right now?
If my primary provider runs out, what fallback path will handle it?
Are my proxy/router pools healthy?
Which subscription/account/provider is about to become the bottleneck?
```

This moves Motas from **quota tracker** to **AI stack readiness widget**.

---

## Target systems

Motas should support both direct AI services and local proxy/router systems.

### Direct providers

Initial direct providers can include:

- Claude / Claude Code
- OpenAI Codex / ChatGPT Codex
- Gemini CLI / Gemini Code Assist
- Antigravity
- GitHub Copilot
- OpenRouter

### Proxy/router systems

The differentiating integrations should include:

- 9Router
- CLIProxyAPI
- ProxyPal
- LiteLLM
- OmniRoute, if useful
- Custom OpenAI-compatible proxy endpoints

These systems are important because power users increasingly do not call a single provider directly. They route AI coding tools through local gateways, subscription proxies, account pools, fallback chains, and cost-saving routers.

---

## Why this matters

The current pain is not only:

```text
Claude is almost out of quota.
```

The deeper pain is:

```text
My coding workflow depends on a stack of subscriptions, CLIs, proxy routes, account pools, fallback providers, and local services. I do not know if that stack is healthy until something breaks.
```

Motas should make that stack visible at a glance.

---

## Product concept

Motas should provide:

1. **Desktop widget**
   - Always-visible quota/health card on macOS desktop.
   - Useful when menu bar is crowded.
   - Shows readiness, remaining quota, reset timers, and proxy status.

2. **Menu bar / toolbar item**
   - Compact status indicator.
   - One-click popover.
   - Quick provider/proxy breakdown.

3. **Proxy health panel**
   - Shows local proxy running/not running.
   - Shows endpoint URL.
   - Shows active route/fallback tier.
   - Shows accounts/providers inside the pool.
   - Shows quota pressure per account/provider where available.

4. **Readiness score**
   - A single simple answer:

```text
Ready
Caution
Fallback mode
Blocked
Proxy down
```

5. **Alerts**
   - Notify before quota exhaustion.
   - Notify when proxy/router falls back to expensive tier.
   - Notify when local proxy is down.
   - Notify when all fallback paths are weak.

---

## Suggested UI language

### Compact menu bar

Examples:

```text
Motas: Ready
Motas: 72%
Motas: Caution
Motas: Fallback
Motas: Down
```

### Desktop widget

Example content:

```text
Motas
AI Stack: Ready

Claude      72% left · resets 3h20m
Codex       41% left · weekly cap 2d
Gemini      913/1000 req · resets midnight
9Router     Healthy · Tier 1 active
CLIProxyAPI Running · 3/4 accounts healthy
OpenRouter  $12.42 left
```

### Proxy-focused widget

```text
Motas Proxy Health

9Router       Healthy
Primary tier  Subscription
Fallback      Cheap models ready
Free tier     2 providers ready
Risk          Low
```

---

## Integration model

Motas should use an adapter/connector model.

Each connector should normalize provider/proxy data into one schema.

Example conceptual schema:

```json
{
  "id": "9router-local",
  "name": "9Router",
  "type": "proxy",
  "status": "healthy",
  "readiness": "ready",
  "remainingPercent": 72,
  "resetAt": "2026-07-22T18:30:00Z",
  "costToday": 1.24,
  "activeTier": "subscription",
  "fallbackReady": true,
  "accountsHealthy": 3,
  "accountsTotal": 4,
  "endpoint": "http://localhost:20128/v1"
}
```

Direct provider connector example:

```json
{
  "id": "claude-code",
  "name": "Claude Code",
  "type": "provider",
  "status": "warning",
  "readiness": "caution",
  "remainingPercent": 31,
  "resetAt": "2026-07-22T16:00:00Z",
  "windows": [
    {
      "name": "5-hour session",
      "remainingPercent": 31
    },
    {
      "name": "weekly",
      "remainingPercent": 66
    }
  ]
}
```

---

## MVP recommendation after competitor research

Do not start with only Claude/Codex/Gemini tracking. That would look too similar to existing tools.

A stronger MVP should include:

```text
1 direct provider + 1 proxy/router + desktop widget + menu bar
```

Recommended MVP options:

### Option A — Proxy-first MVP

- Desktop widget
- Menu bar status
- 9Router connector
- CLIProxyAPI connector
- Custom OpenAI-compatible proxy connector
- Basic readiness score

### Option B — Hybrid MVP

- Desktop widget
- Menu bar status
- Claude Code connector
- 9Router connector
- CLIProxyAPI connector
- OpenRouter credit connector

Recommended choice:

```text
Option B — Hybrid MVP
```

Why:

- Claude Code gives a familiar direct-provider use case.
- 9Router and CLIProxyAPI create differentiation.
- OpenRouter gives simple API-key/credit tracking and proxy-adjacent value.
- Desktop widget makes Motas visibly different from menu-bar-only apps.

---

## What Motas should avoid

Avoid being described as:

```text
Claude usage tracker
AI token tracker
Another menu bar quota app
CodexBar alternative
ClaudeBar alternative
```

Avoid building v1 around:

- Claude-only usage.
- Provider-only dashboards.
- Too many providers with shallow support.
- Cloud account/team features before local utility is proven.
- Usage-based billing.

---

## What Motas should emphasize

Emphasize:

- Mac-native desktop widget.
- Menu bar companion.
- Local proxy/router awareness.
- 9Router, CLIProxyAPI, ProxyPal support.
- Fallback readiness.
- Local-first credentials.
- Read-only monitoring.
- No server required for v1.
- Simple answer: can I code with AI right now?

---

## Updated product one-liners

Preferred:

> **Motas shows AI quota and proxy health on your Mac, so you know if your coding stack is ready before you start.**

Short:

> **AI quota and proxy health, always visible on your Mac.**

Developer-facing:

> **A Mac widget for Claude, Codex, Gemini, Antigravity, 9Router, CLIProxyAPI, ProxyPal, and your local AI proxy stack.**

Problem-focused:

> **Stop discovering quota failures only after your AI coding session breaks.**

---

## Strategic implication

The $19 launch / $29 regular pricing can be defended only if Motas is meaningfully more than a simple provider quota tracker.

The pricing is stronger if Motas includes:

- Desktop widget.
- Proxy/router health.
- Fallback readiness.
- Multiple connector types.
- Local-first trust.
- Polished Mac utility experience.

If Motas only tracks Claude/Codex/Gemini usage, the pricing will be harder because many alternatives are free or cheaper.
