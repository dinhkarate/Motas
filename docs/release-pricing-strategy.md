# Motas Release & Pricing Strategy

_Last updated: 2026-07-22_

## Context

**Motas = Mac + Quota**.

The intended business style is closer to indie Mac utilities such as **Downie** and **One Switch**:

- Mac-first native utility.
- Direct download from the developer website.
- Free trial before purchase.
- One-time license for most users.
- Optional Setapp-style subscription distribution later.
- Homebrew Cask for developer-friendly installation.
- Mac App Store only if sandbox/review constraints do not block the product.

Reference examples:

- Downie official page lists direct permanent license pricing and Setapp availability: https://software.charliemonroe.net/downie
- Downie Setapp page: https://setapp.com/apps/downie
- One Switch is commonly sold as a low-cost direct license and is available on Setapp according to reviews/pages: https://tidbits.com/2020/02/05/one-switch-my-new-must-have-mac-utility/ and https://setapp.com/apps/one-switch

## Recommended positioning

> **Motas — Mac quota, made clear.**

Motas should feel like a small, polished Mac utility that solves one daily annoyance very well: seeing quota/usage/limit status before it becomes a problem.

## Recommended launch model

### Phase 1: Direct sale + Homebrew Cask

This should be the first release path.

Why:

- Faster than Mac App Store review.
- Better fit for developer/power-user audience.
- Easier to support features that may need permissions App Store sandbox dislikes.
- Allows direct license system, free trial, Sparkle updates, and custom pricing.
- Homebrew gives credibility among Mac developers without taking commission.

Distribution:

```bash
brew tap motas-app/tap
brew install --cask motas
```

Direct website:

```text
https://motas.dev
https://getmotas.com
```

Release artifact:

```text
Motas-1.0.0.dmg
```

The `.dmg` should contain:

```text
Motas.app
Applications shortcut
```

### Phase 2: Setapp pitch

After Motas has polish and stable usage, apply to Setapp.

Why:

- Setapp users already expect paid Mac utilities.
- Good discovery channel for Mac productivity apps.
- Fits the Downie/One Switch pattern.

Setapp developer page says they support fair revenue models; for a single app, Setapp says they take 25%, and for membership they take 10% plus share 20% with partners who bring users: https://setapp.com/developers

### Phase 3: Mac App Store only if useful

Mac App Store can be useful for trust and non-technical users, but should not block the initial release.

Use Mac App Store if:

- Motas can work within App Sandbox.
- Feature set does not require fragile system access.
- You want Apple-managed payment, IAP, subscriptions, and discovery.

Apple says the Apple Developer Program is needed to distribute apps on the App Store: https://developer.apple.com/support/compare-memberships

Apple Developer Program also supports distribution outside the Mac App Store using Developer ID certificate and notarization: https://developer.apple.com/programs

Apple App Sandbox is an App Store requirement for Mac App Store apps: https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox

## Pricing strategy

### Recommended pricing for Motas v1

Use a **free trial + one-time Pro license**.

Recommended:

```text
Motas Trial: 15 days free
Motas Pro: $19 one-time early/launch price
Motas Pro regular price: $29 one-time after launch period
Major upgrade: discounted upgrade later
```

Alternative low-cost strategy if the app is very small at launch:

```text
Motas Pro: $9.99–$14.99 one-time
```

But the stronger recommendation is:

```text
Early/launch price: $19
Regular price: $29
```

Meaning:

- **$19** is an introductory price for early customers during launch/beta/first public release.
- **$29** is the normal long-term price after Motas has more polish, docs, integrations, and stability.
- Both are **one-time license prices**, not monthly subscription prices.

Reason:

- Downie-style utility pricing sits around the one-time paid Mac utility model; Downie official page shows a direct permanent license at $19.99: https://software.charliemonroe.net/downie
- One Switch is a smaller menu-bar utility and is commonly referenced around $4.99 for single-device licensing: https://tidbits.com/2020/02/05/one-switch-my-new-must-have-mac-utility/
- Motas likely sits between One Switch and Downie depending on scope.

### Suggested license tiers

#### Individual

```text
Motas Pro Individual — $19 early/launch / $29 regular
```

Includes:

- All local quota tracking.
- Menu bar monitor.
- Notifications/alerts.
- History.
- Export.
- Unlimited local sources.

Device rule:

```text
Valid for all Macs personally owned by the same user.
```

This mirrors the friendly indie-Mac-app approach and reduces support friction.

#### Family / Multi-device

Optional later:

```text
Motas Family — $49 one-time
```

Includes:

- Up to 5 users or household Macs.

#### Team

Not for v1 unless Motas has cloud/team features.

Potential later:

```text
Motas Team — $5/user/month or $49/user/year
```

Team features would need:

- Shared dashboard.
- Team quotas.
- Admin billing.
- Slack/email alerts.
- Audit/history.

Do not build this until individual product-market fit is clear.

## Trial design

Recommended trial:

```text
15-day full-feature trial
```

Rationale:

```text
15 days gives users enough time to see recurring quota/usage patterns across real workdays without feeling rushed.
```

Trial should be generous but simple.

After trial expires:

- Keep app readable.
- Disable advanced actions/alerts/history depth.
- Show clear license prompt.
- Never destroy user data.

Suggested free-after-trial limitation:

```text
Free mode:
- 1 quota source
- Manual refresh
- Basic menu bar display

Pro:
- Unlimited sources
- Auto refresh
- Alerts
- History
- Export
- Advanced providers
```

## Payment and licensing options

### Option A: Lemon Squeezy

Best for indie software if you want simple checkout, license keys, taxes handled, and minimal ops.

Lemon Squeezy docs say it can generate license keys with license length and activation limits: https://docs.lemonsqueezy.com/help/licensing/generating-license-keys

Lemon Squeezy describes itself as Merchant of Record for global sales tax/compliance: https://www.lemonsqueezy.com/reporting/merchant-of-record

Pricing page: https://www.lemonsqueezy.com/pricing

Observed/commonly cited fee model is around:

```text
5% + $0.50 per transaction
```

Verify current fees before launch.

Pros:

- Fast setup.
- Handles VAT/sales tax as Merchant of Record.
- License key flow exists.
- Good for one-time software licenses.

Cons:

- Higher transaction fee than raw Stripe.
- Licensing may be basic; advanced offline activation may require custom layer.

### Option B: Paddle

Good for mature Mac software and global SaaS/software sales.

Paddle has a help article specifically about selling Mac apps with trials and licensing: https://www.paddle.com/help/start/intro-to-paddle/selling-a-mac-app-with-trials-and-licensing

Paddle Merchant of Record explanation: https://www.paddle.com/resources/how-to-evaluate-a-merchant-of-record

Commonly cited fee model:

```text
~5% + $0.50 per transaction
```

Verify current fees before launch.

Pros:

- Strong software/MoR focus.
- Handles tax/compliance.
- Established for Mac app sales.

Cons:

- More complex than Lemon Squeezy.
- Current product direction may be more subscription/SaaS-oriented.

### Option C: Stripe

Best if you want maximum control and already handle tax/compliance.

Pros:

- Lower base payment processing fee than MoR platforms.
- Flexible checkout, subscriptions, coupons, invoices.

Cons:

- You are generally merchant of record.
- You need to handle taxes/VAT/sales tax, refunds, compliance, invoicing, and accounting.
- More backend work.

For Motas v1, **do not start with raw Stripe** unless there is already a tax/accounting setup.

## App updates

For direct distribution, use **Sparkle**.

Sparkle is a standard macOS app update framework. It supports signed updates with EdDSA signatures, Apple code signing, sandboxed apps in Sparkle 2, delta updates, and appcasts: https://github.com/sparkle-project/Sparkle

Sparkle docs: https://sparkle-project.org/documentation

Recommended direct-update flow:

```text
1. Build Motas.app
2. Code sign with Developer ID
3. Notarize with Apple
4. Package as .dmg or .zip
5. Sign Sparkle update archive
6. Generate appcast.xml
7. Publish release files + appcast
8. App auto-checks updates
```

## Homebrew release requirements

For Homebrew, use a Cask.

Homebrew docs:

- Acceptable Casks: https://docs.brew.sh/Acceptable-Casks
- Adding Software to Homebrew: https://docs.brew.sh/Adding-Software-to-Homebrew
- Creating and maintaining a tap: https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap

Recommended initial tap:

```text
github.com/motas-app/homebrew-tap
```

Install command:

```bash
brew tap motas-app/tap
brew install --cask motas
```

Example cask:

```ruby
cask "motas" do
  version "1.0.0"
  sha256 "SHA256_HERE"

  url "https://github.com/motas-app/motas/releases/download/v#{version}/Motas-#{version}.dmg"
  name "Motas"
  desc "Mac quota monitor"
  homepage "https://motas.dev"

  app "Motas.app"

  zap trash: [
    "~/Library/Application Support/Motas",
    "~/Library/Preferences/dev.motas.app.plist",
    "~/Library/Caches/dev.motas.app",
  ]
end
```

Homebrew itself does not process payment or license activation. The app must handle licensing after install.

## Mac App Store requirements and fees

Use this later, not first.

Requirements:

- Apple Developer Program membership.
- App Store Connect app record.
- App Sandbox enabled.
- Correct entitlements.
- App privacy labels.
- Screenshots and metadata.
- App Review approval.
- In-App Purchase if selling digital features inside the app.

Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines

Apple In-App Purchase overview: https://developer.apple.com/in-app-purchase

Apple Support explains IAP types: subscriptions, non-consumable purchases, and consumable purchases: https://support.apple.com/en-us/102383

Apple Small Business Program provides reduced commission of 15% for eligible developers on paid apps and in-app purchases: https://developer.apple.com/app-store/small-business-program

Apple news also describes the reduced commission rate of 15%: https://developer.apple.com/news?id=6lyxewwp

Typical App Store commission planning:

```text
Small Business Program: 15%
Standard: 30%
```

Example for $29 Pro purchase:

```text
At 15% commission:
Gross: $29.00
Apple fee: $4.35
Before other taxes/adjustments: $24.65

At 30% commission:
Gross: $29.00
Apple fee: $8.70
Before other taxes/adjustments: $20.30
```

## Expected costs to release

### Required costs

| Item | Expected cost | Notes |
|---|---:|---|
| Apple Developer Program | ~$99/year | Needed for Developer ID signing/notarization and Mac App Store distribution. Verify exact regional price at enrollment. |
| Domain | ~$10–40/year | `motas.dev`, `motas.app`, or `getmotas.com`. |
| Website hosting | $0–20/month | GitHub Pages/Cloudflare Pages can be free. |
| Payment platform | Usually transaction fee | Lemon Squeezy/Paddle commonly around MoR fee; verify current fee. |
| Code signing/notarization | Included with Apple Developer Program | Needed for smooth direct distribution. |
| GitHub releases | Usually free | Good enough for early `.dmg` hosting. |

### Optional costs

| Item | Expected cost | Notes |
|---|---:|---|
| App icon/brand design | $0–500+ | Can start in-house, upgrade later. |
| Landing page design | $0–500+ | Can start simple. |
| Email/support tool | $0–30/month | Can start with a mailbox. |
| Analytics/crash reporting | $0–50/month | Sentry/PostHog/Plausible/etc. |
| Notion/Docs/help center | $0–20/month | Optional. |
| Setapp | Revenue share | No upfront cost expected, but app must pass review/quality bar. |
| Mac App Store | Apple commission | 15% if eligible for Small Business Program, otherwise standard rate. |

## Recommended v1 financial plan

### Launch price

```text
Motas Pro early/launch: $19 one-time
Motas Pro regular: $29 one-time
Trial: 15 days
```

### Revenue assumptions

If selling direct through MoR at approximate 5% + $0.50:

For $19:

```text
Gross: $19.00
Estimated platform fee: $1.45
Before other costs/taxes: $17.55
```

For $29:

```text
Gross: $29.00
Estimated platform fee: $1.95
Before other costs/taxes: $27.05
```

These are planning estimates only. Verify exact payment provider fees before launch.

### Break-even estimate

If first-year fixed cost is roughly:

```text
Apple Developer Program: $99
Domain: $20
Misc: $30
Total: ~$149
```

At $19 direct license with estimated net around $17.55:

```text
Break-even: ~9 sales
```

At $29 direct license with estimated net around $27.05:

```text
Break-even: ~6 sales
```

## Recommended release checklist

### Before public beta

- [ ] Confirm final Bundle ID.
- [ ] Register domain.
- [ ] Create landing page.
- [ ] Join Apple Developer Program.
- [ ] Add Developer ID signing.
- [ ] Add notarization pipeline.
- [ ] Add Sparkle update feed.
- [ ] Add privacy policy.
- [ ] Add license screen.
- [ ] Choose payment provider.
- [ ] Generate license key validation flow.
- [ ] Package `.dmg`.
- [ ] Create GitHub Releases flow.
- [ ] Create Homebrew tap.

### Before paid launch

- [ ] Trial flow tested.
- [ ] License activation tested online.
- [ ] License validation works offline for a grace period.
- [ ] Refund/support process documented.
- [ ] Update flow tested from old version to new version.
- [ ] Brew install tested on clean Mac.
- [ ] Gatekeeper launch tested after download.
- [ ] Crash reporting/log export added.
- [ ] Website has pricing, download, changelog, support, privacy.

### Later

- [ ] Apply to Setapp.
- [ ] Evaluate Mac App Store sandbox feasibility.
- [ ] Add IAP version if App Store release is worth it.
- [ ] Consider team/cloud subscription only after individual traction.

## Strategic recommendation

Do **not** start with subscription as the primary model.

For Motas, the best initial model is:

```text
Direct download
15-day trial
$19 early/launch one-time Pro license
$29 regular one-time Pro license
Homebrew Cask install
Sparkle updates
Setapp later
Mac App Store optional later
```

This matches the indie Mac utility pattern of Downie/One Switch better than a SaaS-first model.

## Notes and caveats

- Prices and platform fees change. Re-check Apple, Setapp, Lemon Squeezy, Paddle, and Homebrew docs before launch.
- Trademark/name checks are separate from distribution checks.
- If Motas needs deep system access, Mac App Store may be restrictive due to sandboxing.
- Homebrew is distribution only; licensing and payments remain Motas responsibility.
- If Motas becomes cloud-backed, add subscription later rather than forcing it into v1.
