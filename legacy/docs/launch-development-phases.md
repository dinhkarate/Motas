# Motas Launch Conditions & Development Phases

_Last updated: 2026-07-22_

## Goal

Define the conditions required to launch **Motas** and the phased development roadmap from idea to paid public release.

Motas positioning:

> **Motas = Mac + Quota**
> **Motas — Mac quota, made clear.**

The intended launch style is similar to indie Mac utilities like Downie or One Switch:

- Small but polished Mac utility.
- Direct download first.
- Homebrew Cask support.
- 15-day trial.
- One-time Pro license.
- Setapp later.
- Mac App Store optional.

Related docs:

- [Brand notes](../BRAND.md)
- [Release & pricing strategy](./release-pricing-strategy.md)

---

## Launch philosophy

Motas should launch when it is **small, reliable, and useful**, not when it has every possible integration.

Do not wait for a perfect product. But do not launch if the core promise is unclear or unstable.

The core promise:

> A Mac user can open Motas and clearly understand their quota/usage status before limits become a problem.

---

## Definition of launch-ready

Motas is ready for public launch when all of the following are true.

### 1. Core value works

Required:

- [ ] User can add at least one quota/usage source.
- [ ] User can see current usage clearly.
- [ ] User can see remaining quota or limit status.
- [ ] User can refresh/update usage data.
- [ ] User can understand whether they are safe, near limit, or over limit.
- [ ] App gives value within the first 2 minutes after opening.

Success criteria:

```text
A new user can install Motas, connect/configure one source, and understand their quota status without reading long documentation.
```

### 2. Native Mac experience feels polished

Required:

- [ ] App has a proper icon.
- [ ] App name is consistently `Motas`.
- [ ] Menu bar behavior is clean if Motas uses a menu bar UI.
- [ ] Window layout is readable on common Mac screen sizes.
- [ ] App supports light/dark appearance or at least does not break in either mode.
- [ ] App starts quickly.
- [ ] App does not feel like a web page randomly wrapped in a Mac shell.

Success criteria:

```text
The app feels like a focused Mac utility, not an unfinished developer prototype.
```

### 3. Reliability is acceptable

Required:

- [ ] App does not crash during normal setup.
- [ ] App handles failed API/network requests gracefully.
- [ ] App preserves user settings after restart.
- [ ] App handles offline mode gracefully.
- [ ] App avoids corrupting local data.
- [ ] App can run for a full workday without memory/CPU issues.

Success criteria:

```text
Motas can run in the background/menu bar for 8 hours without obvious instability.
```

### 4. Privacy and security are acceptable

Required:

- [ ] API keys/tokens are not stored in plaintext if avoidable.
- [ ] Sensitive data uses Keychain or another secure storage mechanism.
- [ ] App explains what data is stored locally.
- [ ] App explains whether any data leaves the device.
- [ ] Privacy policy exists before paid/public release.
- [ ] Logs do not leak secrets.

Success criteria:

```text
A user can trust Motas with quota/API credentials because storage and data behavior are clear.
```

### 5. Trial and license flow works

Required for paid launch:

- [ ] 15-day trial starts correctly.
- [ ] Trial expiration is clear and non-hostile.
- [ ] License activation works.
- [ ] License validation works after app restart.
- [ ] Offline grace period exists or behavior is documented.
- [ ] User can find where to enter a license key.
- [ ] User can recover/restore license instructions.

Success criteria:

```text
A user can try Motas for 15 days, buy a license, activate it, and keep using the app without contacting support.
```

### 6. Distribution works

Required for direct launch:

- [ ] `Motas.app` is code signed.
- [ ] App is notarized.
- [ ] `.dmg` or `.zip` release artifact works on a clean Mac.
- [ ] Gatekeeper does not block launch.
- [ ] Download link is stable.
- [ ] Version number is visible.
- [ ] Changelog exists.

Required for Homebrew launch:

- [ ] Homebrew tap exists.
- [ ] Cask installs Motas successfully.
- [ ] Cask checksum is correct.
- [ ] `brew uninstall --cask motas` works.
- [ ] `zap` paths are defined for cleanup.

Success criteria:

```text
A user can install Motas from the website or with Homebrew and launch it without security warnings or manual hacks.
```

### 7. Support surface exists

Required:

- [ ] Landing page exists.
- [ ] Download page exists.
- [ ] Pricing page or pricing section exists.
- [ ] Support email exists.
- [ ] Privacy policy exists.
- [ ] Basic FAQ exists.
- [ ] Known limitations are documented.

Success criteria:

```text
A confused user has somewhere to go before messaging directly.
```

---

## Development phases

## Estimated timeline

Assumption: one small team or solo developer working consistently, prioritizing a narrow MVP with 1–2 quota sources.

| Phase | Duration | Cumulative time | Goal |
|---|---:|---:|---|
| Phase 0 — Brand and product definition | 2–4 days | Week 0 | Decide exact MVP scope and first quota source. |
| Phase 1 — Technical prototype | 1–2 weeks | Week 1–2 | Prove one real quota source works end-to-end. |
| Phase 2 — MVP product | 2–4 weeks | Week 3–6 | Build usable app UX, menu bar, storage, alerts, secure credentials. |
| Phase 3 — Private alpha | 1–2 weeks | Week 7–8 | Test with 5–10 trusted users and fix blockers. |
| Phase 4 — Public beta | 2–3 weeks | Week 9–11 | Release beta via website/GitHub/Homebrew and validate strangers can use it. |
| Phase 5 — Paid v1 launch | 2–4 weeks | Week 12–15 | Launch paid version at $19 early price and monitor conversion/support. |
| Phase 6 — Post-launch stabilization | 2–6 weeks | Week 16–21 | Fix real user issues before expanding. |
| Phase 7 — Growth channels | 4–8 weeks | After stability | Apply to Setapp, publish content, evaluate Mac App Store. |
| Phase 8 — Expansion | Ongoing | After traction | Cloud/team/more integrations only after demand is proven. |

Practical target:

```text
Prototype: ~2 weeks
Private alpha: ~6–8 weeks from start
Public beta: ~9–11 weeks from start
Paid v1 launch: ~12–15 weeks from start
Stable v1: ~4–5 months from start
```

If scope stays very narrow, Motas can launch faster. If the first quota integration is complex, the timeline should be extended before adding extra features.

## Phase 0 — Brand and product definition

Status: **Started**

Estimated duration:

```text
2–4 days
```

Purpose:

Clarify what Motas is before building too much.

Deliverables:

- [x] Brand name: Motas.
- [x] Meaning: Mac + Quota.
- [x] Tagline direction.
- [x] Pricing strategy draft.
- [x] Release strategy draft.
- [ ] Product scope for MVP.
- [ ] Initial feature list.
- [ ] Decide first quota source/integration.

Exit criteria:

```text
We can explain Motas in one sentence and list exactly what v1 will and will not do.
```

Recommended v1 sentence:

> Motas is a Mac-native widget and menu bar utility that shows AI quota and proxy health across direct providers and local router systems.

Differentiation reference:

- [Product differentiation](./product-differentiation.md)

---

## Phase 1 — Technical prototype

Estimated duration:

```text
1–2 weeks
```

Purpose:

Prove that Motas can fetch, store, and display quota data.

Scope:

- Local-only prototype.
- No payment.
- No public release.
- Minimal UI allowed.

Deliverables:

- [ ] Basic macOS app shell.
- [ ] Basic menu bar or main window UI.
- [ ] Local settings storage.
- [ ] Add/edit/remove one quota source.
- [ ] Fetch usage/quota data.
- [ ] Display usage, limit, remaining amount.
- [ ] Manual refresh.
- [ ] Error state display.

Exit criteria:

```text
Motas can track one real quota source end-to-end on the developer machine.
```

Do not add yet:

- Payment.
- Team features.
- Cloud sync.
- Complex analytics.
- Many integrations.

---

## Phase 2 — MVP product

Estimated duration:

```text
2–4 weeks
```

Purpose:

Turn the prototype into a useful app that someone else can try.

Scope:

- Still private/internal.
- Product shape should be clear.
- Core UX should be stable.

Deliverables:

- [ ] Proper Motas app icon placeholder or final icon.
- [ ] Clean onboarding flow.
- [ ] Add first quota source without manual config hacks.
- [ ] Usage dashboard.
- [ ] Menu bar status.
- [ ] Basic status levels:
  - Safe
  - Warning
  - Critical
  - Over limit
- [ ] Notification or alert when near limit.
- [ ] Local history storage.
- [ ] Settings screen.
- [ ] Secure credential storage.
- [ ] Basic logs/export for debugging.

Exit criteria:

```text
A non-developer tester can install Motas, configure one source, and understand the value without the creator explaining every step.
```

---

## Phase 3 — Private alpha

Estimated duration:

```text
1–2 weeks
```

Purpose:

Test Motas with a small group before public release.

Target users:

```text
5–10 trusted Mac users
```

Prefer testers who:

- Use API quotas, AI tools, or usage-limited services.
- Are comfortable giving detailed feedback.
- Use their Mac daily.

Deliverables:

- [ ] Signed development build or simple notarized build.
- [ ] Installation instructions.
- [ ] Feedback form or GitHub issue template.
- [ ] Crash/log collection method.
- [ ] Known issues list.
- [ ] Basic privacy explanation.

Alpha success criteria:

```text
At least 5 testers install Motas successfully.
At least 3 testers use it for several days.
No critical data/security issue is found.
Core value is understood by testers.
```

Questions to answer in alpha:

- Do users understand what Motas does?
- Is the first quota source useful enough?
- Is menu bar display valuable?
- Are alerts helpful or annoying?
- What part of setup is confusing?
- Would users pay $19 for this?

Exit criteria:

```text
The product has a clear core use case and no obvious blocker in setup, reliability, or trust.
```

---

## Phase 4 — Public beta

Estimated duration:

```text
2–3 weeks
```

Purpose:

Release Motas publicly but still label it as beta.

Distribution:

- Website download.
- GitHub Releases.
- Homebrew tap.

Pricing:

```text
15-day trial
Optional early license at $19
```

Public beta can be free if license flow is not ready, but the pricing page should already communicate future pricing.

Deliverables:

- [ ] Landing page.
- [ ] Download link.
- [ ] Changelog.
- [ ] Privacy policy.
- [ ] Support email.
- [ ] Notarized `.dmg`.
- [ ] Homebrew Cask in own tap.
- [ ] Update mechanism or clear manual update process.
- [ ] Basic onboarding docs.
- [ ] Trial/license screen if paid beta.

Public beta success criteria:

```text
20+ installs
5+ active users after 7 days
No severe install/signing issues
At least 3 users say the app solves a real problem
```

Exit criteria:

```text
Motas can be installed and used by strangers without hand-holding.
```

---

## Phase 5 — Paid v1 launch

Estimated duration:

```text
2–4 weeks launch window
```

Purpose:

Officially launch Motas as a paid indie Mac utility.

Pricing:

```text
15-day trial
$19 early/launch one-time license
$29 regular one-time license after launch period
```

Recommended launch period:

```text
2–4 weeks
```

Deliverables:

- [ ] Payment provider configured.
- [ ] License key generation works.
- [ ] License activation in app works.
- [ ] Refund policy exists.
- [ ] Support process exists.
- [ ] Website pricing section is live.
- [ ] Update mechanism works.
- [ ] Homebrew Cask updated to stable v1.
- [ ] Announcement copy ready.
- [ ] Screenshots/GIFs ready.
- [ ] Basic analytics or download tracking.

Paid launch readiness gate:

```text
No known critical bug.
No known credential leak risk.
Install works on clean Mac.
Trial works.
License works.
Update works.
Support/privacy pages exist.
```

Launch success criteria:

```text
First 10 paid customers
Refund rate below 15%
At least 30% of trial users complete setup
At least 10 users run Motas for more than 3 days
```

---

## Phase 6 — Post-launch stabilization

Purpose:

Fix real user issues and improve the product before expanding scope.

Duration:

```text
2–6 weeks after v1 launch
```

Priorities:

1. Fix install/update/license bugs.
2. Fix onboarding confusion.
3. Improve quota source reliability.
4. Improve alert defaults.
5. Add docs for common setup problems.
6. Collect testimonials and use cases.

Deliverables:

- [ ] v1.0.1 bugfix release.
- [ ] v1.0.2 bugfix release if needed.
- [ ] FAQ update.
- [ ] Better onboarding copy.
- [ ] Support issue categorization.
- [ ] Roadmap update based on feedback.

Exit criteria:

```text
Most support issues are not install/license blockers; they are feature requests or integration requests.
```

---

## Phase 7 — Growth channels

Estimated duration:

```text
4–8 weeks after post-launch stabilization
```

Purpose:

Expand distribution after the core app is stable.

Channels:

- Setapp.
- Product Hunt.
- Hacker News / indie Mac communities.
- Reddit Mac apps communities.
- Blog posts around Mac quota/API usage.
- Mac App Store if technically suitable.

Deliverables:

- [ ] Apply to Setapp.
- [ ] Prepare Setapp build if accepted.
- [ ] Evaluate Mac App Store sandbox compatibility.
- [ ] Prepare App Store metadata if viable.
- [ ] Add more integrations based on demand.
- [ ] Add comparison/use-case pages.

Exit criteria:

```text
Motas has a stable direct channel and can afford the maintenance cost of extra channels.
```

---

## Phase 8 — Expansion

Estimated duration:

```text
Ongoing; do not start until v1 traction is proven
```

Purpose:

Add larger features only after individual Mac utility value is proven.

Possible expansions:

- Motas Cloud.
- Team quotas.
- Multi-device sync.
- Slack/Discord/email alerts.
- Shared workspace dashboard.
- Advanced historical analytics.
- Export/reporting.
- More quota providers.

Do not start Phase 8 until:

- Individual app has active users.
- Users request team/cloud features repeatedly.
- There is willingness to pay for recurring value.

Potential future pricing:

```text
Motas Pro: one-time individual license
Motas Cloud: optional subscription
Motas Team: per-seat subscription
```

---

## Launch blockers

Do not launch publicly if any of these are true:

- App cannot be installed on a clean Mac.
- Gatekeeper blocks the app.
- App stores API keys insecurely.
- Trial/license state can easily break normal usage.
- App crashes during onboarding.
- User cannot understand what to do after opening the app.
- Quota data is misleading or dangerously wrong.
- No privacy/support page exists.
- No way to update users after a bugfix.

---

## MVP scope recommendation

For v1, keep Motas narrow.

Recommended v1:

- Mac app.
- Desktop widget.
- Menu bar status.
- At least one direct provider connector.
- At least one proxy/router connector such as 9Router, CLIProxyAPI, or ProxyPal.
- Custom OpenAI-compatible proxy connector if feasible.
- Manual + automatic refresh.
- Safe/warning/critical/proxy-down state.
- AI stack readiness score.
- Local history.
- Notifications.
- Secure local credentials.
- 15-day trial.
- One-time license.
- Direct download.
- Homebrew Cask.

Not v1:

- Team dashboard.
- Cloud sync.
- Mobile app.
- Mac App Store unless very easy.
- Too many shallow provider integrations.
- Complex public plugin marketplace.
- Usage-based billing.
- Claude-only or provider-only positioning.

---

## Decision gates

### Gate A — Build MVP?

Proceed if:

```text
We have chosen the first quota source and can fetch real usage data.
```

### Gate B — Start alpha?

Proceed if:

```text
A developer can use Motas daily for one real quota source without manually editing config files.
```

### Gate C — Start public beta?

Proceed if:

```text
At least 5 private testers installed it, and no critical onboarding/security issue remains.
```

### Gate D — Start paid launch?

Proceed if:

```text
Trial, license, notarized install, update path, privacy page, support page, and Homebrew Cask all work.
```

### Gate E — Raise price from $19 to $29?

Proceed if at least two are true:

```text
- Motas has 20+ paying users.
- Refund/support burden is low.
- App has at least 2 strong integrations.
- Onboarding conversion is acceptable.
- Users report that Motas is part of their daily workflow.
```

---

## Recommended immediate next steps

1. Define the first quota source Motas will support.
2. Decide UI shape: menu bar-first, window-first, or hybrid.
3. Build technical prototype for one source.
4. Document security/storage plan for credentials.
5. Create minimal landing page copy.
6. Prepare alpha tester list.

## Current strategic default

```text
Direct-first indie Mac utility
15-day trial
$19 early/launch one-time license
$29 regular one-time license
Homebrew Cask from day one
Setapp later
Mac App Store optional
```
