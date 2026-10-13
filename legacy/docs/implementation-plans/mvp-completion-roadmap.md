# Motas MVP Completion Roadmap

Status: ready for implementation

Baseline branch: `feat-deepseek/settings`

Baseline commit: `8dfc45e` (`feat(notifications): add readiness transition engine`)

Last verified baseline:

```text
76 Swift tests passed
MotasPrototype strict Swift 6 build passed
Apple Command Line Tools selected
Full Xcode unavailable/unselected
```

## 1. Goal

Move Motas from a technical alpha/demo into a credible developer-facing MVP without weakening its conservative readiness and credential-safety guarantees.

This roadmap uses two product gates:

### Gate A — Developer MVP / private alpha

A developer can install/run Motas, connect at least one direct provider and one local proxy, understand current readiness, receive actionable information, and export sanitized diagnostics.

### Gate B — Release MVP

The signed app and WidgetKit extension work together on a clean Mac, notifications deliver correctly, live connectors are verified, and the app is packaged through a repeatable release process.

Gate A should be completed before spending significant effort on payment, licensing or broad provider count.

## 2. Current baseline

Already implemented:

- Normalized provider, proxy, quota, observation and readiness models.
- Conservative readiness engine with deterministic precedence.
- Claude Code status-line quota connector.
- Basic 9Router health/account connector.
- Basic CLIProxyAPI health/account connector.
- Persistent secret-free Settings JSON.
- macOS Keychain adapter for proxy credentials.
- Environment override precedence.
- Menu-bar popover and Settings form.
- Manual and five-minute automatic refresh.
- Refresh coalescing and stale-result rejection.
- Atomic non-secret snapshot persistence.
- WidgetKit source for medium/large layouts.
- Pure readiness notification transition engine with cooldown/deduplication.
- 76 Swift tests at baseline.

Not yet complete:

- Guided first connection and connection testing.
- Bounded local status history.
- Sanitized diagnostics export.
- Reset times/freshness/remediation in the UI.
- macOS notification permission and delivery adapter.
- Verified signed App Group + WidgetKit integration.
- Live connector compatibility checks.
- App icon/accessibility/soak testing.
- Signed/notarized distribution.

## 3. Sequencing principles

1. Fix determinism and privacy issues before building history or notification delivery.
2. Finish features testable through Swift Package Manager before depending on full Xcode.
3. Do not claim WidgetKit, Keychain or notification integration as verified without a signed app.
4. Treat unknown/stale/partial as product states, not errors to hide.
5. Prefer one well-tested connector path over adding more providers.
6. Keep the widget and diagnostics secret-free by construction.
7. Implement each milestone as one or more reviewable commits with a passing full test suite.

---

# Milestone 0 — Stability and roadmap cleanup

Environment: Apple Command Line Tools

Priority: immediate

## Objective

Remove deterministic-data defects and close test/documentation gaps that would make history, notifications or widgets noisy.

## 0.1 Stable CLIProxyAPI account IDs

Current issue:

`CLIProxyAPIConnector.account(from:)` falls back to `UUID().uuidString` when the upstream account lacks `auth_index`, `id` and `name`. The same account can therefore receive a different ID on every refresh.

Modify:

```text
Sources/MotasCore/Connectors/CLIProxyAPIConnector.swift
```

Symbols:

```text
CLIProxyAPIConnector.account(from:)
CLIProxyAPIConnector.AuthFile
```

Implementation requirement:

- Use upstream stable identifiers when present.
- Otherwise derive a deterministic, sanitized identifier from non-secret stable fields such as provider/type plus response position.
- Do not hash email, token, filename containing credentials, raw payload or secret-bearing status text.
- If the response provides no stable fields, use a deterministic response index supplied by the mapping call.

Tests:

- Same fixture produces the same IDs across refreshes.
- Two anonymous accounts receive distinct deterministic IDs.
- IDs do not contain an email, token or raw filename.
- Sorting remains stable.

## 0.2 Complete automatic refresh scheduler test matrix

Modify:

```text
Tests/MotasCoreTests/AutomaticRefreshSchedulerTests.swift
```

Add cases for:

- Starting again cancels the previous loop.
- Next interval is scheduled only after the current operation completes.
- Cancellation during sleep exits cleanly.
- Default interval is five minutes.
- Missed intervals are not replayed.

Do not change scheduler behavior unless a test exposes a real defect.

## 0.3 Cleanup stale implementation-plan metadata

Update:

```text
docs/implementation-plans/settings-keychain-auto-refresh.md
```

Mark it implemented and record:

- commits `d8949e0`, `ce72b90`, `d5b1117`;
- Command Line Tools verification;
- deferred signed Keychain and WidgetKit checks.

Do not rewrite the entire historical phase checklist in this milestone. Add one note that the checklist is historical/stale and this roadmap is the current execution source.

## Acceptance criteria

- No random IDs enter `StatusSnapshot`.
- Scheduler behavior has explicit regression coverage.
- No production behavior is broadened.
- Full tests and strict build pass.

## Suggested commit

```text
fix(core): stabilize connector identity and refresh tests
```

## Verification

```bash
swift test --filter CLIProxyAPI
swift test --filter AutomaticRefreshScheduler
swift test
swift build -Xswiftc -strict-concurrency=complete --product MotasPrototype
git diff --check
```

---

# Milestone 1 — Bounded status history

Environment: Apple Command Line Tools

Priority: immediate after Milestone 0

## Objective

Persist recent normalized status transitions locally for diagnostics and future trend UI without storing credentials or unbounded data.

## Add Core model

Add:

```text
Sources/MotasCore/History/StatusHistory.swift
```

Recommended symbols:

```text
StatusHistoryEntry
StatusHistoryPolicy
StatusHistory
```

`StatusHistoryEntry` should contain only:

- schema version;
- capture timestamp;
- readiness state/title/source ID;
- normalized provider health/quality/quota summary;
- normalized proxy health/quality/route summary.

Prefer reusing a sanitized `StatusSnapshot` or a smaller summary rather than duplicating connector-specific DTOs.

Do not store:

- Keychain identifiers beyond stable enum names;
- endpoint URLs;
- account emails;
- raw observation payloads;
- cookies/tokens/headers;
- connector response bodies.

## Add store

Add:

```text
Sources/MotasCore/Persistence/StatusHistoryStore.swift
```

Recommended symbols:

```text
StatusHistoryStore
JSONStatusHistoryStore
StatusHistoryStoreError
```

Requirements:

- Atomic JSON write.
- Versioned document.
- Deterministic sorted keys.
- Missing file returns empty history.
- Malformed/future schema produces a sanitized error and is not silently overwritten on load.
- Retention by both count and age.

Recommended initial policy:

```text
maximum entries: 500
maximum age: 30 days
```

History file location:

```text
~/Library/Application Support/Motas/history.json
```

Do not place history in the App Group; the widget only needs the current snapshot.

## Integrate with AppModel

Modify:

```text
Sources/MotasApp/MotasApp.swift
```

Add an injectable history store.

Append history only when:

- a snapshot is accepted for the current configuration revision;
- the normalized state materially differs from the latest stored entry, or the configured sampling interval has elapsed.

Do not append:

- obsolete refresh results;
- demo scenario changes unless an explicit development-only option is enabled;
- failed snapshot-persistence attempts as duplicate history events.

History write failure must not discard the live snapshot. Surface a sanitized diagnostics/storage warning separately.

## Tests

Add:

```text
Tests/MotasCoreTests/StatusHistoryStoreTests.swift
```

Required cases:

1. Missing file returns empty history.
2. Round-trip preserves deterministic order.
3. Count retention removes oldest entries.
4. Age retention removes expired entries.
5. Same state/source duplicate is suppressed by the append policy.
6. Material state/source change is stored.
7. Malformed file throws without overwrite.
8. Future schema version throws.
9. Encoded history contains no credential-like fields or fixture secrets.
10. Obsolete refresh results cannot be appended through the Core append policy.

## Acceptance criteria

- History is bounded and secret-free.
- Current snapshot remains the source of truth.
- History failures do not break readiness refresh.
- Tests prove retention and privacy.

## Suggested commits

```text
feat(history): add bounded normalized status storage
feat(history): record accepted readiness transitions
```

## Verification

```bash
swift test --filter StatusHistory
swift test --filter SnapshotStore
swift test
swift build -Xswiftc -strict-concurrency=complete --product MotasPrototype
git diff --check
```

---

# Milestone 2 — Sanitized diagnostics export

Environment: Apple Command Line Tools

Dependency: Milestone 1

## Objective

Let users export enough information for troubleshooting without exposing credentials or raw upstream responses.

## Add pure diagnostics builder

Add:

```text
Sources/MotasCore/Diagnostics/DiagnosticReport.swift
```

Recommended symbols:

```text
DiagnosticReport
DiagnosticConnectorSummary
DiagnosticReportBuilder
DiagnosticExportFormat
```

Inputs:

- current `StatusSnapshot`;
- bounded recent history;
- non-secret settings summary;
- application/version/build metadata supplied by the app;
- sanitized configuration-resolution issues.

Outputs:

- deterministic JSON;
- readable Markdown/plain text.

Report content:

- generated timestamp;
- Motas version/build;
- current readiness state/title;
- provider/proxy IDs, health, quality and last-success timestamp;
- quota percentages and reset times;
- redacted endpoint labels only;
- recent readiness transitions;
- sanitized connector messages;
- settings enabled states and environment-override presence.

Never include:

- secure-field values;
- Keychain content;
- full endpoint URLs with path/query/userinfo;
- account emails;
- cookies/authorization headers;
- Claude transcript/session data;
- raw JSON response bodies.

## App integration

Modify:

```text
Sources/MotasApp/SettingsView.swift
Sources/MotasApp/MotasApp.swift
```

Add a Diagnostics section with:

- Copy diagnostics.
- Save diagnostics file.
- Reset local data (settings/history/snapshot/Keychain) only after a confirmation dialog.

If a native save panel requires app-target APIs, keep the report builder in Core and add a minimal macOS adapter in `MotasApp`.

Reset behavior must explicitly remove:

- `settings.json`;
- `history.json`;
- fallback snapshot;
- all four Keychain records.

Do not remove the Claude Code cache because Motas does not own it.

## Tests

Add:

```text
Tests/MotasCoreTests/DiagnosticReportTests.swift
```

Required cases:

- Deterministic JSON/Markdown output.
- Endpoint label remains redacted.
- Secret-bearing fixtures never appear.
- History is bounded in the report.
- Partial/stale/unauthorized states remain distinguishable.
- Reset plan lists only Motas-owned files and Keychain records.

## Acceptance criteria

- A support report can be generated offline.
- Export contains actionable state and timing information.
- Privacy tests scan both JSON and text output.
- Reset action does not delete third-party data.

## Suggested commits

```text
feat(diagnostics): build sanitized support reports
feat(settings): add diagnostics export and reset actions
```

## Verification

```bash
swift test --filter DiagnosticReport
swift test
swift build --product MotasPrototype
swift build -Xswiftc -strict-concurrency=complete --product MotasPrototype
git diff --check
```

---

# Milestone 3 — Truthful status presentation

Environment: Apple Command Line Tools for compile/tests; interactive menu-bar verification on macOS

Dependency: Milestone 0

## Objective

Show the status data Motas already has: freshness, reset times, connector messages and remediation actions.

## Core formatting helpers

Add only if needed:

```text
Sources/MotasCore/Presentation/StatusPresentation.swift
```

Recommended pure helpers:

```text
QuotaResetFormatter
FreshnessFormatter
StatusRemediation
```

Keep date/time decisions testable by accepting `now` and `Calendar`/timezone inputs.

## Menu-bar changes

Modify:

```text
Sources/MotasApp/StatusPopoverView.swift
```

Display:

- “Updated N min ago” instead of only clock time.
- Fresh/partial/stale/unavailable badge per source.
- Lowest enforced quota plus reset countdown/date.
- `Observation.message` when non-healthy or partial/stale.
- A concrete action such as “Open Settings,” “Start Claude Code,” or “Check proxy service.”
- Explicit Quit action.

Requirements:

- Stale quota must visibly say stale even when a percentage exists.
- Reset times in the past must not be presented as future.
- Unknown quota must not show 100%.
- Dynamic explanation text must not leak endpoint or credential material.

## Widget source changes

Modify source only in this milestone:

```text
Sources/MotasWidget/MotasWidget.swift
```

Prepare for full-Xcode validation by adding:

- snapshot age/stale indicator;
- reset time where space allows;
- clear unknown/unavailable fallback;
- stable row limits for medium and large families.

Do not claim WidgetKit completion until Milestone 5.

## Tests

Add pure formatter tests:

```text
Tests/MotasCoreTests/StatusPresentationTests.swift
```

Required cases:

- Reset in minutes/hours/days.
- Past reset time.
- Fresh versus stale relative age.
- Missing reset.
- Partial/stale badge precedence.
- Remediation mapping for unauthorized, unsupported, unreachable and missing Claude cache.

## Acceptance criteria

- A user can understand why state is not ready without reading logs.
- Reset time and freshness are visible.
- Demo mode still works.
- SwiftPM app builds and launches.

## Suggested commit

```text
feat(ui): show freshness reset times and remediation
```

## Verification

```bash
swift test --filter StatusPresentation
swift test
swift build --product MotasPrototype
swift run MotasPrototype
```

`swift run MotasPrototype` is an interactive manual check, not a finite CI command.

---

# Milestone 4 — Guided first connection

Environment: Apple Command Line Tools for compile; interactive macOS verification

Dependencies: Milestones 2 and 3

## Objective

Let a developer reach a truthful live status in about two minutes without knowing environment-variable names or internal connector architecture.

## Add onboarding state

Add:

```text
Sources/MotasCore/Onboarding/OnboardingState.swift
```

Recommended types:

```text
OnboardingStep
OnboardingConnectorChoice
OnboardingProgress
```

Persist only completion/progress flags in non-secret settings. Do not persist secret drafts.

## App UI

Add:

```text
Sources/MotasApp/OnboardingView.swift
```

Flow:

1. Explain local-only data and Keychain boundary.
2. Choose Claude Code, 9Router or CLIProxyAPI.
3. Show connector-specific setup instructions.
4. Save connector settings/secrets using the existing `AppModel.saveSettings` path.
5. Run a read-only connection check.
6. Show normalized result and remediation.
7. Suggest adding a complementary direct provider or proxy.

## Test connection behavior

Do not add mutation routes.

Use existing connectors with a dedicated one-shot operation that returns normalized status. The test must:

- use the draft settings/secret input without persisting first where practical;
- never log or return secret values;
- distinguish unauthorized from unreachable;
- time out consistently;
- not alter automatic-refresh state until Save succeeds.

Recommended app symbols:

```text
AppModel.testConnector(...)
ConnectionTestResult
```

If test orchestration can be made UI-independent, place it in Core and test it through fakes.

## Acceptance criteria

- First-run demo is labeled clearly as demo.
- User can connect one real source without shell environment variables.
- Failed connection produces a specific next action.
- Secure fields remain transient.
- Existing Settings remains the advanced/edit surface.

## Suggested commits

```text
feat(onboarding): add first connection flow
feat(settings): add read-only connection testing
```

## Verification

```bash
swift test
swift build --product MotasPrototype
swift run MotasPrototype
```

Manual matrix:

- Claude cache missing/present.
- 9Router reachable/unreachable/unauthorized.
- CLIProxyAPI reachable/unreachable/unauthorized.
- Cancel onboarding without secret persistence.
- Save and relaunch.

---

# Milestone 5 — Full Xcode, signed app and WidgetKit completion

Environment: full Xcode + XcodeGen + Apple Development Team

Blocker: full Xcode is currently unavailable/unselected

## 5.1 Regenerate project

The checked-out `Motas.xcodeproj` is ignored and may be stale. Regenerate from source of truth:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
brew install xcodegen
xcodegen generate
```

Do not hand-edit generated project files.

## 5.2 App assets and URL routing

Add:

- App icon asset catalog.
- Widget icon/branding where required.
- `motas://status` URL scheme or remove unsupported widget URL.
- Explicit application Quit action validation.

Update `project.yml`, not the generated project.

## 5.3 App Group verification

Verify:

- `group.dev.motas.app` registered.
- App and widget use the same App Group.
- Widget has no Keychain entitlement.
- App-to-widget snapshot sharing works after relaunch.
- Fallback Application Support snapshot is never mistaken for widget sharing.

## 5.4 Widget truthfulness and reload

Modify:

```text
Sources/MotasApp/MotasApp.swift
Sources/MotasWidget/MotasWidget.swift
```

After a materially changed accepted snapshot:

- persist App Group snapshot;
- request `WidgetCenter.shared.reloadTimelines(ofKind:)` from the app target;
- do not reload for identical snapshots on every timer tick.

Validate:

- medium and large families;
- light and dark mode;
- stale snapshot after app stops;
- missing App Group snapshot;
- reset times;
- row truncation;
- no secrets.

## 5.5 Signed Keychain verification

Manual cases:

- Save all four secret types.
- Quit/relaunch and read them.
- Replace without duplicate records.
- Remove explicitly.
- Lock/unlock Mac.
- Confirm automatic refresh never prompts.
- Confirm widget cannot read them.

## Acceptance criteria

- `xcodebuild` builds and tests app + widget.
- Signed app and widget share snapshots.
- Widget truthfully displays stale/unknown states.
- Signed Keychain behavior is verified.

## Suggested commit

```text
feat(widget): complete signed App Group integration
```

## Verification

```bash
xcodegen generate
xcodebuild \
  -project Motas.xcodeproj \
  -scheme Motas \
  -destination 'platform=macOS' \
  test

xcodebuild \
  -project Motas.xcodeproj \
  -scheme Motas \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

---

# Milestone 6 — macOS notification delivery

Environment: full Xcode + signed app

Dependencies: notification engine already implemented; Milestone 5 app validation

## Objective

Deliver the existing Core notification events through macOS without notification spam or secret leakage.

## Add app adapter

Add:

```text
Sources/MotasApp/ReadinessNotificationService.swift
```

Recommended protocol/type:

```text
ReadinessNotificationDelivering
UserNotificationService
```

Responsibilities:

- Request permission from an explicit user action.
- Read current authorization state.
- Deliver `ReadinessNotificationEvent`.
- Map critical versus normal/low severity safely.
- Use normalized title/reason only.
- Do not include raw `Observation.message` unless it has a dedicated safety review.

## Persist notification history

Add a small history store or include it in non-secret app settings:

```text
lastEventKey
lastNotifiedAt
```

Do not store an unbounded notification log in Settings.

## AppModel integration

When an accepted snapshot replaces the previous accepted snapshot:

1. Evaluate `ReadinessNotificationEngine`.
2. Persist updated notification history.
3. Deliver event only if authorization permits.
4. Notification failure must not fail snapshot refresh.

Do not evaluate notification events for:

- demo mode;
- obsolete refresh results;
- initial snapshot;
- identical accepted snapshots.

## Settings UI

Add:

- Enable readiness notifications.
- Notify on unknown toggle.
- Authorization status.
- Open System Settings action when denied.

Keep cooldown fixed initially unless user research requires customization.

## Tests

Use a fake `ReadinessNotificationDelivering` for application orchestration.

Required cases:

- Initial accepted snapshot silent.
- Accepted transition delivers once.
- Obsolete refresh result never delivers.
- Demo mode never delivers.
- Permission denied does not break refresh.
- History persists across app restart.
- Delivered content contains no fixture secrets.

## Acceptance criteria

- Real macOS notification arrives for fallback/blocked/proxyDown transitions.
- Repeated auto-refresh does not spam.
- Permission denied is handled gracefully.
- Cooldown survives relaunch.

## Suggested commit

```text
feat(notifications): deliver readiness alerts on macOS
```

---

# Milestone 7 — Live connector validation and compatibility fixtures

Environment: live Claude Code, 9Router and CLIProxyAPI installations

Dependencies: Milestones 0, 3 and 4

## Objective

Prove that fixtures and connector assumptions match real supported versions.

## Versioned sanitized fixtures

Add:

```text
Tests/Fixtures/ClaudeCode/<version>/
Tests/Fixtures/9Router/<version>/
Tests/Fixtures/CLIProxyAPI/<version>/
```

Before committing fixtures:

- remove emails, tokens, IDs and local filesystem paths;
- replace them with stable synthetic values;
- document the upstream version and endpoint;
- retain only fields needed by parser tests.

## Live validation matrix

Claude Code:

- Status-line script receives five-hour/seven-day windows.
- Cache updates during a real session.
- Missing `rate_limits` remains honest unsupported/partial.

9Router:

- `/api/health` current contract.
- Dashboard cookie and CLI token auth.
- `/api/providers` current fields.
- Unauthorized versus unreachable.
- Multiple provider accounts and stable ordering.

CLIProxyAPI:

- `/v1/models` current contract.
- `/v0/management/auth-files` current contract.
- Management disabled/rejected.
- Anonymous account ID stability.
- Multiple account/provider states.

## Readiness policy review

Current proxy connectors often return `.partial`, which can keep real configurations in `caution` even when routing works.

Do not weaken readiness merely to show green.

Instead, determine whether connectors can positively verify:

- required route reachability;
- primary path availability;
- fallback route availability;
- optional account details separately.

If the normalized model needs a distinction between route verification and account-detail completeness, update the model and readiness rules explicitly with tests.

## Acceptance criteria

- Sanitized fixtures represent documented supported versions.
- All three real connector flows work on at least one supported installation.
- Version/compatibility failures produce partial/unsupported, not false ready.
- No live secret enters git history.

## Suggested commits

```text
test(connectors): add versioned compatibility fixtures
fix(connectors): align normalization with live services
```

---

# Milestone 8 — Private-alpha hardening

Environment: signed app + real services

Dependencies: Milestones 1–7

## Objective

Prove Motas remains safe and understandable through normal developer use.

## Manual/automated matrix

- Eight-hour workday run.
- Sleep/wake.
- Network offline/online.
- Proxy stopped/restarted.
- Keychain locked/unlocked.
- Settings changed during in-flight refresh.
- Notification permission allowed/denied.
- Widget after app quit.
- Corrupt settings/history/snapshot files.
- Reset all Motas data.
- Light/dark mode.
- VoiceOver and keyboard navigation.
- Clean user account without existing Application Support files.

## Add app icon and accessibility polish

Requirements:

- Real AppIcon asset.
- Accessible labels for menu-bar status and icon-only controls.
- No color-only status meaning.
- Reasonable keyboard navigation.
- Text remains readable in dark/light mode.

## Acceptance criteria

- No crash or unbounded file growth during soak test.
- No Keychain prompts from automatic refresh.
- Offline/stale transitions remain truthful.
- Diagnostics export helps reproduce issues.
- First-time developer completes setup without shell commands.

## Suggested commit

```text
chore(alpha): harden lifecycle accessibility and assets
```

---

# Milestone 9 — Release MVP distribution

Environment: Developer ID, notarization and release infrastructure

Dependency: Gate A complete and private alpha accepted

## Objective

Ship a repeatable signed build to external users.

## Required work

- Developer ID Application signing.
- Hardened runtime review.
- Notarized DMG.
- Clean-Mac Gatekeeper test.
- GitHub Release artifact and checksums.
- Homebrew Cask in project tap.
- Install/uninstall/troubleshooting docs.
- Privacy policy and support contact.
- Changelog/release checklist.

## Updates and licensing

Sparkle, trial and licensing are in frozen v1 scope but should be sequenced after a stable signed private alpha.

Recommended order:

1. Signed/notarized manual releases.
2. Sparkle feed and update signing.
3. Trial/license storage and offline grace.
4. Payment provider integration.

Do not block private alpha on payment implementation.

## Acceptance criteria

- Fresh Mac installs, launches and passes Gatekeeper.
- Uninstall instructions remove only Motas-owned data.
- Update path is tested before enabling automatic updates.
- License failure cannot block access to diagnostics/uninstall.

---

# 4. Recommended execution order

Immediate Command Line Tools sequence:

```text
M0 Stability/determinism
  ↓
M1 Status history
  ↓
M2 Diagnostics export
  ↓
M3 Truthful UI/freshness/reset times
  ↓
M4 Guided onboarding and connection test
```

Then full-Xcode sequence:

```text
M5 Signed app + WidgetKit/App Group
  ↓
M6 UserNotifications delivery
  ↓
M7 Live connector validation
  ↓
M8 Private-alpha hardening
  ↓
M9 Distribution
```

M7 live connector validation may start earlier in parallel when real services are available, but fixture commits must remain sanitized and reviewable.

## First implementation slice

Start with Milestone 0, then Milestone 1.

The first slice should not include onboarding, notifications delivery or WidgetKit changes. Its success condition is:

> Stable connector identities and a bounded, secret-free status history with complete SwiftPM tests.

## Branching recommendation

Continue from:

```bash
git checkout feat-deepseek/settings
git pull --ff-only
```

Create a focused branch for the next implementation slice:

```bash
git switch -c feat-deepseek/history-diagnostics
```

Do not implement all milestones on one long-lived branch.

## Commit rules

- One coherent milestone/checkpoint per commit.
- Run full tests before every push.
- Include the AI co-author trailer as the final commit line:

```text
Co-authored-by: claude-chan <claude-chan@thatnghiep.dev>
```

## Universal verification

For Command Line Tools milestones:

```bash
swift test
swift test --parallel
swift build --product MotasPrototype
swift build -Xswiftc -strict-concurrency=complete --product MotasPrototype
python3 -m py_compile scripts/motas-claude-statusline scripts/motas_board.py
git diff --check
git status --short
```

For full-Xcode milestones, also run the `xcodegen` and `xcodebuild` commands documented in Milestone 5.

## Universal non-goals until Gate A

- Adding many new providers.
- Team/cloud synchronization.
- Automatic proxy mutation.
- Background daemon/XPC service.
- Multi-instance connectors.
- Custom user-defined readiness rules.
- Usage-based Motas billing.
- Mac App Store submission.
- General connector plugin SDK.

The critical product promise remains: truthful readiness, local credentials, actionable status, and a reliable native macOS surface.
