# Motas Phase Task Breakdown

_Last updated: 2026-07-22_

## Confirmed strategy

Motas will differentiate as:

> **A Mac-native quota and proxy health widget for the whole AI coding stack.**

Motas is not just another Claude/Codex/Gemini quota tracker. It should focus on:

- Desktop widget.
- Menu bar companion.
- Direct provider quota visibility.
- Proxy/router health visibility.
- 9Router, CLIProxyAPI, ProxyPal-style integrations.
- AI stack readiness score.
- Local-first credential handling.
- Direct download + Homebrew-first release.

Reference docs:

- [Brand notes](../BRAND.md)
- [Product differentiation](./product-differentiation.md)
- [macOS surface architecture](./adr/001-macos-surface-architecture.md)
- [MVP user stories and first-run success](./product/mvp-user-stories.md)
- [Launch and development phases](./launch-development-phases.md)
- [Release and pricing strategy](./release-pricing-strategy.md)

---

## Phase 0 — Brand and product definition

Estimated duration:

```text
2–4 days
```

Goal:

Define exactly what Motas v1 is and is not.

### 0.1 Confirm product positioning

Tasks:

- [ ] Lock final one-liner.
- [ ] Lock short tagline.
- [ ] Lock product category.
- [ ] Decide whether to describe Motas as widget-first or menu-bar-first.
- [ ] Document anti-positioning: what Motas is not.

Suggested output:

```text
Motas — AI quota and proxy health, always visible on your Mac.
```

Acceptance criteria:

- One-liner is clear enough for landing page hero.
- Product is visibly different from ClaudeBar/CodexBar/SessionWatcher.

### 0.2 Define MVP scope

Tasks:

- [ ] Choose first direct provider connector.
- [ ] Choose first proxy/router connector.
- [ ] Choose second proxy/router connector if time allows.
- [ ] Decide whether OpenRouter is included in MVP.
- [ ] Decide whether ProxyPal support is MVP or post-MVP.
- [ ] Define unsupported providers for v1.

Recommended MVP connector set:

```text
Direct provider: Claude Code
Proxy/router: 9Router
Proxy/router: CLIProxyAPI
Optional: OpenRouter credit connector
Optional later: ProxyPal
```

Acceptance criteria:

- MVP can be described in one paragraph.
- MVP does not become a generic 20-provider tracker.

### 0.3 Define core user stories

Status: **Completed** — see [MVP user stories and first-run success](./product/mvp-user-stories.md).

Tasks:

- [x] Write top 5+ user stories.
- [x] Define the main pain Motas solves.
- [x] Define what user sees in first 60 seconds.
- [x] Define what counts as a successful first run.

Suggested user stories:

```text
As a Mac user, I want to see if my AI coding stack is ready before I start a long session.
As a Claude Code user, I want to know when my quota is close to exhaustion.
As a 9Router user, I want to know whether my fallback stack is healthy.
As a CLIProxyAPI user, I want to see if the local proxy is running and accounts are available.
As a proxy power user, I want one visible widget instead of multiple dashboards.
```

Acceptance criteria:

- Every MVP feature maps to at least one user story.

### 0.4 Define data model draft

Tasks:

- [ ] Define `ProviderStatus` schema.
- [ ] Define `ProxyStatus` schema.
- [ ] Define `QuotaWindow` schema.
- [ ] Define `ReadinessState` enum.
- [ ] Define refresh interval defaults.

Core readiness states:

```text
ready
caution
fallback
blocked
proxyDown
unknown
```

Acceptance criteria:

- Direct provider and proxy/router connectors can normalize into one shared model.

---

## Phase 1 — Technical prototype

Estimated duration:

```text
1–2 weeks
```

Goal:

Prove Motas can read real quota/proxy data and display a unified readiness state.

### 1.1 Create macOS app shell

Tasks:

- [ ] Create native macOS app project.
- [ ] Choose framework: SwiftUI recommended.
- [ ] Set app name to `Motas`.
- [ ] Set initial bundle identifier.
- [ ] Add basic app icon placeholder.
- [ ] Add minimum macOS target.
- [ ] Create basic settings window.

Acceptance criteria:

- App builds locally.
- App launches as `Motas`.
- App can show a simple window.

### 1.2 Create menu bar prototype

Tasks:

- [ ] Add menu bar item.
- [ ] Show simple text/status icon.
- [ ] Add popover on click.
- [ ] Add quit/settings actions.
- [ ] Add mock provider rows.
- [ ] Add color-coded readiness indicator.

Acceptance criteria:

- Menu bar can display `Ready`, `Caution`, `Fallback`, or `Down` using mock data.

### 1.3 Create desktop widget prototype

Architecture decision: **native hybrid** — live `MenuBarExtra` plus WidgetKit desktop extension. See [ADR-001](./adr/001-macos-surface-architecture.md).

Tasks:

- [x] Decide WidgetKit vs floating always-on-top window for v1.
- [ ] Prototype medium widget layout.
- [ ] Prototype large widget layout.
- [ ] Display mock provider/proxy states.
- [ ] Test dark/light mode.
- [ ] Test desktop readability.

Selected approach:

```text
Use MenuBarExtra as the live interactive surface.
Use WidgetKit as the native desktop glance surface.
The app polls connectors and writes a non-secret snapshot through App Group.
Defer a custom floating panel until post-beta demand is proven.
```

Acceptance criteria:

- User can see Motas status outside the main app window.
- Widget communicates stack readiness at a glance.

### 1.4 Implement connector interface

Tasks:

- [ ] Define connector protocol/interface.
- [ ] Define common output model.
- [ ] Add mock connector.
- [ ] Add refresh lifecycle.
- [ ] Add error handling state.
- [ ] Add timestamp of last successful refresh.

Acceptance criteria:

- App can switch between mock connector and real connector without changing UI.

### 1.5 Prototype 9Router connector

Tasks:

- [ ] Detect common 9Router local endpoint.
- [ ] Research available local API/status endpoint.
- [ ] Add manual endpoint setting.
- [ ] Query health endpoint or fallback to HTTP reachability.
- [ ] Parse available quota/fallback data if exposed.
- [ ] Map result to `ProxyStatus`.
- [ ] Show 9Router in menu bar popover.

Acceptance criteria:

- Motas can show whether 9Router is reachable/running.
- If quota/fallback info is available, Motas displays it.
- If not available, Motas displays partial health instead of failing.

### 1.6 Prototype CLIProxyAPI connector

Tasks:

- [ ] Detect default CLIProxyAPI config path.
- [ ] Support manual endpoint URL.
- [ ] Support management key if needed.
- [ ] Query management/status endpoint if available.
- [ ] Show running/down state.
- [ ] Show configured providers/accounts if available.
- [ ] Map result to `ProxyStatus`.

Known CLIProxyAPI macOS config paths to check:

```text
/opt/homebrew/etc/cliproxyapi.conf
/usr/local/etc/cliproxyapi.conf
~/.cli-proxy-api/config.yaml
```

Acceptance criteria:

- Motas can show whether CLIProxyAPI is running.
- Motas can show at least endpoint and basic health.

### 1.7 Prototype direct provider connector

Tasks:

- [ ] Choose first direct provider: Claude Code recommended.
- [ ] Identify safe read-only data source.
- [ ] Avoid storing passwords.
- [ ] Use Keychain for sensitive values.
- [ ] Fetch usage/quota where possible.
- [ ] Map to `ProviderStatus`.

Acceptance criteria:

- Motas can display one direct provider quota or usage state.

---

## Phase 2 — MVP product

Estimated duration:

```text
2–4 weeks
```

Goal:

Turn prototype into a usable app for private testers.

### 2.1 Build onboarding flow

Tasks:

- [ ] Create welcome screen.
- [ ] Explain what Motas does in one sentence.
- [ ] Let user choose connector type.
- [ ] Add guided setup for 9Router.
- [ ] Add guided setup for CLIProxyAPI.
- [ ] Add guided setup for Claude Code or selected direct provider.
- [ ] Add skip/manual configuration path.
- [ ] Add local-first privacy note.

Acceptance criteria:

- A tester can set up at least one connector without editing config files manually.

### 2.2 Build connector settings UI

Tasks:

- [ ] Add connectors list.
- [ ] Add enable/disable connector toggle.
- [ ] Add endpoint URL field.
- [ ] Add management API key field if needed.
- [ ] Store secrets in Keychain.
- [ ] Add test connection button.
- [ ] Add last refresh status.
- [ ] Add delete connector action.

Acceptance criteria:

- User can configure and test proxy/router connectors from UI.

### 2.3 Implement readiness scoring

Tasks:

- [ ] Define scoring rules for direct providers.
- [ ] Define scoring rules for proxy routers.
- [ ] Define how proxy fallback changes status.
- [ ] Define unknown/partial data behavior.
- [ ] Add global stack readiness state.
- [ ] Add explanation text for status.

Example rules:

```text
Ready: primary provider healthy and fallback available.
Caution: quota under threshold but fallback available.
Fallback: primary exhausted, fallback route active.
Blocked: no usable provider/fallback.
Proxy Down: configured proxy endpoint unreachable.
Unknown: data source cannot be verified.
```

Acceptance criteria:

- Motas gives one understandable top-level answer.

### 2.4 Build desktop widget UI

Tasks:

- [ ] Design compact widget.
- [ ] Design medium widget.
- [ ] Design large widget.
- [ ] Show global readiness.
- [ ] Show top 3–5 sources.
- [ ] Show reset timers.
- [ ] Show proxy health rows.
- [ ] Add color states.
- [ ] Add click action to open details.

Acceptance criteria:

- Widget can answer “can I code with AI right now?” in under 3 seconds visually.

### 2.5 Build menu bar popover UI

Tasks:

- [ ] Show global readiness.
- [ ] Show direct provider rows.
- [ ] Show proxy/router rows.
- [ ] Show refresh button.
- [ ] Show settings shortcut.
- [ ] Show last updated time.
- [ ] Show error details on click.

Acceptance criteria:

- User can inspect quota/proxy details quickly from menu bar.

### 2.6 Implement notifications

Tasks:

- [ ] Add notification permission request.
- [ ] Notify when quota enters caution state.
- [ ] Notify when primary provider enters critical state.
- [ ] Notify when proxy goes down.
- [ ] Notify when router falls back to expensive tier.
- [ ] Add notification preferences.
- [ ] Prevent notification spam.

Acceptance criteria:

- Notifications are useful and not annoying.

### 2.7 Implement local storage

Tasks:

- [ ] Store connector configs.
- [ ] Store non-secret settings locally.
- [ ] Store secrets in Keychain.
- [ ] Store recent status history.
- [ ] Add migration path for future versions.
- [ ] Add reset app data option.

Acceptance criteria:

- App remembers setup after restart.
- Secrets are not stored in plaintext config files.

### 2.8 Add basic diagnostics

Tasks:

- [ ] Add diagnostics screen.
- [ ] Show app version.
- [ ] Show connector statuses.
- [ ] Show sanitized logs.
- [ ] Add copy diagnostics button.
- [ ] Redact secrets from logs.

Acceptance criteria:

- User can provide useful support info without leaking credentials.

---

## Phase 3 — Private alpha

Estimated duration:

```text
1–2 weeks
```

Goal:

Validate Motas with trusted users before public beta.

### 3.1 Prepare alpha build

Tasks:

- [ ] Create alpha version number.
- [ ] Code sign build if possible.
- [ ] Notarize if possible.
- [ ] Package as `.dmg` or `.zip`.
- [ ] Write install instructions.
- [ ] Write uninstall instructions.

Acceptance criteria:

- Alpha tester can install Motas on a clean Mac.

### 3.2 Recruit alpha testers

Tasks:

- [ ] Identify 5–10 trusted Mac users.
- [ ] Prefer users of Claude Code, Codex, Gemini, 9Router, CLIProxyAPI, or ProxyPal.
- [ ] Send short product explanation.
- [ ] Ask which connectors they can test.
- [ ] Confirm consent for feedback.

Acceptance criteria:

- At least 5 testers agree to install.

### 3.3 Create feedback loop

Tasks:

- [ ] Create feedback form.
- [ ] Create issue template.
- [ ] Create private feedback channel.
- [ ] Define bug severity labels.
- [ ] Define what logs testers can share.

Acceptance criteria:

- Testers know exactly where to report issues.

### 3.4 Run alpha test

Tasks:

- [ ] Track install success.
- [ ] Track connector setup success.
- [ ] Track widget usefulness.
- [ ] Track false readiness states.
- [ ] Track crashes/hangs.
- [ ] Track security/privacy concerns.

Acceptance criteria:

```text
5 testers install successfully.
3 testers use Motas for several days.
No critical data/security issue remains.
```

### 3.5 Fix alpha blockers

Tasks:

- [ ] Fix install blockers.
- [ ] Fix setup blockers.
- [ ] Fix credential storage concerns.
- [ ] Fix misleading readiness states.
- [ ] Fix notification spam.
- [ ] Fix top crashes.

Acceptance criteria:

- No known blocker prevents public beta.

---

## Phase 4 — Public beta

Estimated duration:

```text
2–3 weeks
```

Goal:

Release Motas publicly as beta and validate usage by strangers.

### 4.1 Prepare public beta distribution

Tasks:

- [ ] Join Apple Developer Program if not done.
- [ ] Set Developer ID signing.
- [ ] Set notarization flow.
- [ ] Build `.dmg`.
- [ ] Test on clean Mac.
- [ ] Create GitHub Release.
- [ ] Add changelog.

Acceptance criteria:

- Downloaded app opens without Gatekeeper workaround.

### 4.2 Create Homebrew tap/cask

Tasks:

- [ ] Create or prepare `homebrew-tap` repo.
- [ ] Write `motas` cask.
- [ ] Add version and SHA256.
- [ ] Add `zap` cleanup paths.
- [ ] Test `brew install --cask motas`.
- [ ] Test uninstall.
- [ ] Document install command.

Acceptance criteria:

```bash
brew tap motas-app/tap
brew install --cask motas
```

works on a clean Mac.

### 4.3 Create landing page

Tasks:

- [ ] Write hero copy.
- [ ] Explain differentiation.
- [ ] Add screenshots/GIFs.
- [ ] Add download button.
- [ ] Add Homebrew install snippet.
- [ ] Add connector list.
- [ ] Add privacy statement.
- [ ] Add support email.

Acceptance criteria:

- User can understand Motas within 10 seconds.

### 4.4 Create docs

Tasks:

- [ ] Quick start guide.
- [ ] 9Router setup guide.
- [ ] CLIProxyAPI setup guide.
- [ ] ProxyPal setup guide if supported.
- [ ] Claude Code setup guide.
- [ ] OpenRouter setup guide if supported.
- [ ] Troubleshooting guide.
- [ ] Privacy/security page.

Acceptance criteria:

- Common setup problems are documented before support requests arrive.

### 4.5 Public beta feedback tracking

Tasks:

- [ ] Add lightweight analytics or download count.
- [ ] Track activation/setup completion manually or locally.
- [ ] Track connector success rate.
- [ ] Track top errors.
- [ ] Track requested connectors.
- [ ] Track pricing feedback.

Acceptance criteria:

```text
20+ installs.
5+ active users after 7 days.
At least 3 users say Motas solves a real problem.
```

---

## Phase 5 — Paid v1 launch

Estimated duration:

```text
2–4 week launch window
```

Goal:

Turn Motas into a paid indie Mac utility.

Pricing:

```text
15-day trial
$19 early/launch one-time license
$29 regular one-time license after launch period
```

### 5.1 Implement trial system

Tasks:

- [ ] Start 15-day trial on first launch or first meaningful setup.
- [ ] Show trial days remaining.
- [ ] Explain what happens after trial.
- [ ] Keep app non-hostile after trial expiry.
- [ ] Add trial reset policy for development/testing.

Acceptance criteria:

- Trial is clear, fair, and difficult enough to abuse casually.

### 5.2 Implement license system

Tasks:

- [ ] Choose payment/licensing provider.
- [ ] Generate license keys.
- [ ] Add license activation UI.
- [ ] Validate license online.
- [ ] Cache license locally.
- [ ] Add offline grace period.
- [ ] Add deactivate/reassign behavior if needed.
- [ ] Add restore license instructions.

Acceptance criteria:

- User can buy, receive, activate, and keep using Motas without support.

### 5.3 Configure payment flow

Tasks:

- [ ] Choose Lemon Squeezy, Paddle, or equivalent.
- [ ] Create Motas Pro product.
- [ ] Set $19 launch price.
- [ ] Prepare $29 regular price.
- [ ] Configure receipt/license email.
- [ ] Configure refund policy.
- [ ] Test checkout.
- [ ] Test webhook/license creation if used.

Acceptance criteria:

- A real purchase can unlock Motas Pro.

### 5.4 Prepare launch assets

Tasks:

- [ ] Final app icon.
- [ ] Final screenshots.
- [ ] Demo GIF/video.
- [ ] Landing page final copy.
- [ ] Announcement post.
- [ ] README or public docs.
- [ ] Press/launch kit if needed.

Acceptance criteria:

- Motas can be announced publicly without looking unfinished.

### 5.5 Launch checklist

Tasks:

- [ ] Test direct download.
- [ ] Test Homebrew install.
- [ ] Test trial flow.
- [ ] Test license flow.
- [ ] Test update flow.
- [ ] Test 9Router connector.
- [ ] Test CLIProxyAPI connector.
- [ ] Test ProxyPal connector if included.
- [ ] Test clean uninstall.
- [ ] Verify privacy page.
- [ ] Verify support email.

Acceptance criteria:

- No critical launch blocker remains.

### 5.6 Launch monitoring

Tasks:

- [ ] Monitor support email daily.
- [ ] Monitor checkout/license failures.
- [ ] Monitor crash reports.
- [ ] Monitor Homebrew install issues.
- [ ] Track first 10 paid customers.
- [ ] Track refund requests.
- [ ] Track most requested connectors.

Acceptance criteria:

```text
First 10 paid customers.
Refund rate below 15%.
At least 30% of trial users complete setup.
```

---

## Phase 6 — Post-launch stabilization

Estimated duration:

```text
2–6 weeks after v1 launch
```

Goal:

Fix real user issues before expanding scope.

### 6.1 Fix installation/update issues

Tasks:

- [ ] Fix notarization/Gatekeeper problems.
- [ ] Fix Homebrew cask issues.
- [ ] Fix Sparkle/update issues.
- [ ] Fix app launch issues.
- [ ] Release v1.0.1.

Acceptance criteria:

- Install/update issues are no longer the main support category.

### 6.2 Improve connector reliability

Tasks:

- [ ] Improve 9Router connector.
- [ ] Improve CLIProxyAPI connector.
- [ ] Improve direct provider connector.
- [ ] Add endpoint autodetection where reliable.
- [ ] Improve partial-data behavior.
- [ ] Add clearer error messages.

Acceptance criteria:

- Connector failures are understandable and recoverable.

### 6.3 Improve readiness scoring

Tasks:

- [ ] Review false positives.
- [ ] Review false negatives.
- [ ] Tune thresholds.
- [ ] Add user-configurable thresholds.
- [ ] Improve explanation copy.

Acceptance criteria:

- Users trust the global Motas readiness state.

### 6.4 Improve docs and onboarding

Tasks:

- [ ] Add missing FAQ entries.
- [ ] Add troubleshooting screenshots.
- [ ] Add connector-specific docs.
- [ ] Improve first-run copy.
- [ ] Add sample setups.

Acceptance criteria:

- Common support questions are answered by docs.

### 6.5 Decide price transition

Tasks:

- [ ] Review paid customer count.
- [ ] Review refund/support burden.
- [ ] Review product maturity.
- [ ] Decide whether to move from $19 to $29.
- [ ] Announce price change if applicable.

Acceptance criteria:

- Price increase happens only when value is defendable.

---

## Phase 7 — Growth channels

Estimated duration:

```text
4–8 weeks after stabilization
```

Goal:

Grow distribution after direct channel works.

### 7.1 Setapp preparation

Tasks:

- [ ] Review Setapp requirements.
- [ ] Prepare Setapp pitch.
- [ ] Prepare app build for review.
- [ ] Prepare screenshots/video.
- [ ] Explain why Motas is not just another quota tracker.
- [ ] Submit to Setapp.

Acceptance criteria:

- Motas is submitted to Setapp with a clear differentiation story.

### 7.2 Community launch

Tasks:

- [ ] Prepare Product Hunt launch.
- [ ] Prepare Hacker News post.
- [ ] Prepare Reddit posts.
- [ ] Prepare dev.to/Indie Hackers story.
- [ ] Prepare comparison article.
- [ ] Prepare demo video.

Acceptance criteria:

- Public launch message emphasizes proxy/router health, not only Claude quota.

### 7.3 SEO/content

Tasks:

- [ ] Page: 9Router desktop widget.
- [ ] Page: CLIProxyAPI monitor for Mac.
- [ ] Page: AI proxy health widget.
- [ ] Page: Claude Code quota + proxy fallback.
- [ ] Page: Motas vs CodexBar.
- [ ] Page: Motas vs ClaudeBar.
- [ ] Page: Motas vs SessionWatcher.

Acceptance criteria:

- Motas can be discovered by users searching for proxy/router quota visibility.

### 7.4 Mac App Store evaluation

Tasks:

- [ ] Evaluate sandbox constraints.
- [ ] Check whether connector access works in sandbox.
- [ ] Check Keychain/access permissions.
- [ ] Check local network entitlement needs.
- [ ] Decide App Store viability.
- [ ] If viable, create App Store metadata.

Acceptance criteria:

- Clear go/no-go decision for Mac App Store.

---

## Phase 8 — Expansion

Estimated duration:

```text
Ongoing; only after v1 traction
```

Goal:

Expand after core utility is proven.

### 8.1 Add more connectors

Tasks:

- [ ] Add ProxyPal if not in v1.
- [ ] Add LiteLLM connector.
- [ ] Add OmniRoute connector if demand exists.
- [ ] Add Cursor connector if useful.
- [ ] Add GitHub Copilot connector if useful.
- [ ] Add Gemini/Antigravity deeper support.
- [ ] Add OpenRouter deeper analytics.

Acceptance criteria:

- New connectors improve readiness visibility, not just provider count.

### 8.2 Connector SDK / plugin system

Tasks:

- [ ] Stabilize connector schema.
- [ ] Document connector API.
- [ ] Decide whether third-party connectors are allowed.
- [ ] Add signed connector policy if needed.
- [ ] Add connector test harness.

Acceptance criteria:

- Connector ecosystem can grow without making Motas unstable.

### 8.3 Cloud/team features

Tasks:

- [ ] Validate demand for team quota visibility.
- [ ] Define team dashboard scope.
- [ ] Define cloud sync scope.
- [ ] Define privacy model.
- [ ] Define subscription pricing.
- [ ] Build only after repeated user requests.

Acceptance criteria:

- Cloud/team work is based on real demand, not speculation.

### 8.4 Advanced analytics

Tasks:

- [ ] Add historical quota trends.
- [ ] Add provider cost comparison.
- [ ] Add fallback frequency chart.
- [ ] Add subscription ROI estimate.
- [ ] Add export/reporting.

Acceptance criteria:

- Analytics help users make decisions about subscriptions/proxies.

---

## Cross-phase technical tasks

These tasks may span multiple phases.

### Security

- [ ] Use Keychain for secrets.
- [ ] Redact logs.
- [ ] Avoid collecting credentials centrally.
- [ ] Prefer read-only APIs.
- [ ] Document local-first behavior.
- [ ] Add threat model for connector data.

### Packaging

- [ ] Code signing.
- [ ] Notarization.
- [ ] `.dmg` packaging.
- [ ] Homebrew cask.
- [ ] Sparkle updates.
- [ ] Changelog.

### Quality

- [ ] Unit tests for readiness scoring.
- [ ] Unit tests for connector parsing.
- [ ] Mock connector test fixtures.
- [ ] Clean Mac install test.
- [ ] Long-running background test.
- [ ] Offline mode test.

### Design

- [ ] App icon.
- [ ] Widget visual system.
- [ ] Menu bar icon states.
- [ ] Color semantics.
- [ ] Light/dark mode.
- [ ] Accessibility contrast.

---

## First actionable sprint

Recommended first sprint length:

```text
1 week
```

Sprint goal:

> Build a mock Motas Mac app that shows AI stack readiness in menu bar and desktop widget using mock direct provider + proxy data.

Tasks:

- [ ] Create SwiftUI macOS project.
- [ ] Add menu bar item.
- [ ] Add floating desktop widget prototype.
- [ ] Add mock connector model.
- [ ] Add mock data for Claude Code, 9Router, CLIProxyAPI, OpenRouter.
- [ ] Add readiness scoring.
- [ ] Show `Ready/Caution/Fallback/Down` states.
- [ ] Add basic settings placeholder.
- [ ] Capture screenshot for design review.

Sprint exit criteria:

```text
A screenshot can explain Motas' differentiated value without real integrations yet.
```

---

## Priority order

If time is limited, build in this order:

1. Menu bar + widget shell.
2. Shared status/readiness data model.
3. Mock connectors.
4. 9Router basic health connector.
5. CLIProxyAPI basic health connector.
6. Claude Code direct provider connector.
7. OpenRouter credit connector.
8. Notifications.
9. Trial/license.
10. Homebrew/direct release.

Reason:

```text
The UI and data model prove Motas' differentiation first. Real connectors can then be added one by one without changing the product shape.
```
