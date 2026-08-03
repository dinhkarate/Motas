# Implementation Plan: Settings, Keychain and Automatic Refresh

Status: ready for implementation

Plan branch: `plan/settings-keychain-auto-refresh` (documentation only)

Implementation branch: `feat/settings-keychain-auto-refresh`

Intended implementer: DeepSeek or another coding agent

Baseline commit: `7c68044` (`feat(connectors): add Claude Code quota monitoring`)

## 1. Goal

Turn the current environment-configured prototype into a daily-usable macOS app by adding:

1. Persistent, secret-free connector settings.
2. macOS Keychain storage for 9Router and CLIProxyAPI credentials.
3. A safe five-minute automatic refresh loop.
4. A real Settings UI that applies configuration without restarting the app.

Keep the change narrow. Existing connector implementations, normalized models, readiness semantics, widget snapshot boundary and environment-variable development workflow must continue to work.

## 2. Success criteria

The work is complete only when:

- Connector enabled states and endpoints survive app restart.
- Claude Code status-file path survives app restart.
- Proxy credentials are stored only in macOS Keychain.
- Empty `SecureField` values do not erase saved credentials.
- Credential deletion requires an explicit action.
- Existing environment variables still work and override persisted values for the current process.
- Environment credentials are never imported into Keychain.
- The app refreshes once at startup and then every five minutes while running.
- Manual, startup, scheduled and post-save refreshes share one non-overlapping pipeline.
- Results created with obsolete configuration are discarded.
- No credential appears in settings JSON, `StatusSnapshot`, App Group data, errors or logs.
- `swift test` and `swift build --product MotasPrototype` pass with Apple Command Line Tools.
- Full Xcode/widget/signing verification is reported as deferred unless it was actually performed.

## 3. Current architecture to preserve

The repository already contains:

- `StatusConnector` and immutable connector configuration structs.
- Claude Code, 9Router and CLIProxyAPI connectors.
- Concurrent, deterministic `ConnectorRefresher` aggregation.
- Conservative `ReadinessEngine` behavior for fresh, partial and stale data.
- Atomic, non-secret `StatusSnapshot` persistence.
- `AppModel` isolated to `@MainActor`.
- WidgetKit source that reads only the shared normalized snapshot.

Current connector roles must remain:

- Claude Code: primary provider.
- Enabled 9Router: primary and required proxy.
- CLIProxyAPI: fallback/not required when 9Router is enabled; otherwise primary/required.

Do not make roles user-editable in this milestone.

## 4. Architecture decision

### Put in `MotasCore`

- Secret-free settings value types.
- Settings validation.
- Settings storage protocol and JSON implementation.
- Secret storage protocol.
- Effective configuration resolver and environment precedence.
- Refresh policy and reusable scheduler.
- Unit tests and in-memory fakes.

These are domain/orchestration concerns and must be testable through Swift Package Manager.

### Put in `MotasApp`

- Concrete `Security.framework` Keychain adapter.
- Application Support path selection.
- Production dependency composition.
- `AppModel` settings/refresh lifecycle.
- SwiftUI Settings form and transient secret fields.

The widget must never receive a secret-store instance or Keychain entitlement.

### Do not add

- A dependency-injection framework.
- A separate storage package target.
- Keychain sharing with the widget.
- A background daemon or XPC service.

## 5. Implementation checkpoints

Implement and commit each checkpoint separately. Do not combine all work into one unreviewable commit.

---

## Checkpoint 1: Secret-free persistent settings

Suggested commit:

```text
feat(settings): add persistent connector configuration model
```

### Add `Sources/MotasCore/Configuration/ConnectorSettings.swift`

Add these public, `Sendable`, `Codable`, `Equatable` types:

- `MotasSettings`
- `ClaudeCodeSettings`
- `NineRouterSettings`
- `CLIProxyAPISettings`
- `ConnectorSecretKey`
- `ConnectorSettingsValidationError`

Recommended `MotasSettings` fields:

```text
schemaVersion
automaticRefreshEnabled
claudeCode
nineRouter
cliProxyAPI
```

Use schema version `1`.

Recommended defaults:

All connector `isEnabled` values default to `false`. This preserves explicit first-run demo behavior and prevents unsolicited localhost probes.

```text
Claude status file:
~/Library/Application Support/Motas/claude-code-status.json

9Router:
http://localhost:20128

CLIProxyAPI:
http://localhost:8317

automaticRefreshEnabled:
true
```

Expand `~` and persist the Claude path as a normalized absolute file URL/path.

Do not add a user-editable refresh interval. This milestone uses a fixed five-minute interval.

### Stable Keychain account identifiers

Use a closed enum, not caller-defined strings:

```text
nineRouterDashboardToken   -> 9router.dashboard-token
nineRouterCLIToken         -> 9router.cli-token
cliProxyAPIProxyKey        -> cliproxyapi.proxy-api-key
cliProxyAPIManagementKey   -> cliproxyapi.management-key
```

These raw values become stable Keychain account names and must not be casually renamed later.

### Settings URL validation

For endpoints entered through Settings, require:

- Scheme `http` or `https`.
- Non-empty host.
- No username or password.
- No query string.
- No fragment.
- Optional valid port.
- No path except `/` or a connector's already-supported suffix (`/v1` and `/v0/management` for CLIProxyAPI); normalize supported suffixes through `EndpointNormalizer` before persistence.

Reject examples such as:

```text
http://user:secret@localhost:8317
http://localhost:8317?api_key=secret
```

Do not require the Claude status file to exist at save time.

Environment URL behavior must be safe and explicit: accept only absolute `http`/`https` URLs with a host. For invalid environment URLs, emit a sanitized resolution issue and fall back to persisted configuration rather than constructing a connector that may later hit a force-unwrap. Compatibility means all currently documented valid environment inputs still work; it does not mean preserving unsafe relative-URL acceptance.

### Add `Sources/MotasCore/Persistence/ConnectorSettingsStore.swift`

Protocol:

```swift
public protocol ConnectorSettingsStore: Sendable {
    func load() throws -> MotasSettings?
    func save(_ settings: MotasSettings) throws
}
```

Add `JSONConnectorSettingsStore` with these rules:

- File location is supplied by the containing app.
- Missing file returns `nil`.
- Save atomically.
- Create the parent directory when needed.
- Decode a minimal `{ schemaVersion }` envelope first, reject unsupported future versions, then decode the current full schema. Validate schema version on save too.
- Malformed JSON throws and is not silently overwritten at startup.
- Encode deterministic sorted keys.
- Store only immutable URL state where possible for Swift 6 safety.

Production path:

```text
~/Library/Application Support/Motas/settings.json
```

This file belongs to the containing app, not the App Group container.

### Update `Sources/MotasCore/Configuration/MotasConfiguration.swift`

Add:

```text
settingsFilename = settings.json
defaultAutomaticRefreshInterval = 300 seconds
minimumAutomaticRefreshInterval = 60 seconds
keychainService = dev.motas.app.connectors
```

### Add tests

Create `Tests/MotasCoreTests/ConnectorSettingsStoreTests.swift`.

Required cases:

1. Missing file returns `nil`.
2. Settings round-trip atomically.
3. Defaults have expected endpoints and refresh policy.
4. Encoded settings contain no token/key fields or values.
5. Malformed JSON throws and is not overwritten.
6. Future schema version throws.
7. Valid local HTTP/HTTPS endpoints pass.
8. Userinfo, query, fragment, missing host and unsupported schemes fail.
9. Nonexistent Claude status file can still be saved.

### Verify checkpoint 1

```bash
swift test --filter ConnectorSettingsStoreTests
swift test
swift build --product MotasPrototype
git diff --check
```

---

## Checkpoint 2: Keychain and effective configuration resolution

Suggested commit:

```text
feat(settings): resolve connector secrets from macOS Keychain
```

### Add `Sources/MotasCore/Persistence/ConnectorSecretStore.swift`

Protocol:

```swift
public protocol ConnectorSecretStore: Sendable {
    func value(for key: ConnectorSecretKey) throws -> String?
    func set(_ value: String, for key: ConnectorSecretKey) throws
    func removeValue(for key: ConnectorSecretKey) throws
    func containsValue(for key: ConnectorSecretKey) throws -> Bool
}
```

Tests must use an in-memory fake. Default `swift test` must never modify the developer's real Keychain.

`containsValue` exists so Settings can show “Stored in Keychain” without loading the secret into a UI field.

### Add `Sources/MotasApp/KeychainConnectorSecretStore.swift`

Use generic-password Keychain records:

```text
kSecClassGenericPassword
kSecAttrService = dev.motas.app.connectors
kSecAttrAccount = ConnectorSecretKey.rawValue
kSecAttrSynchronizable = false
kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

For read/existence queries, prevent surprise authentication UI:

```text
kSecUseAuthenticationUI = kSecUseAuthenticationUIFail
```

CRUD rules:

- `errSecItemNotFound` on read returns `nil`.
- Set updates first, then adds if not found.
- Remove treats not-found as success.
- Existence query requests metadata only, never password data.
- Errors are typed and sanitized.
- Never include secret values, query dictionaries or raw returned data in errors.

If linking is required:

- Add `.linkedFramework("Security")` to the `MotasApp` target in `Package.swift`.
- In `project.yml`, add this XcodeGen dependency under `targets.Motas.dependencies`:

```yaml
- sdk: Security.framework
```

- Do not add Security to the package dependency list or widget target.

Do not modify `Config/MotasWidget.entitlements`.

### Add `Sources/MotasCore/Configuration/ConnectorConfigurationResolver.swift`

Recommended types:

- `ConnectorConfigurationResolver`
- `ResolvedConnectorConfiguration`
- `ConfigurationResolutionIssue`
- `ConnectorConfigurationSource`

Inputs:

- `MotasSettings`
- Whether a persisted settings document exists.
- `[String: String]` environment dictionary.
- `ConnectorSecretStore`.

Outputs:

- `ClaudeCodeConfiguration?`
- `NineRouterConfiguration?`
- `CLIProxyAPIConfiguration?`
- Sanitized issues.
- Source metadata needed by Settings labels.

The resolver must be pure except for calls through `ConnectorSecretStore`. It must not read `ProcessInfo` directly.

### Exact precedence

```text
Explicit environment value
    > persisted Settings / Keychain
    > built-in default
```

Claude Code:

- Explicit `MOTAS_CLAUDE_CODE_ENABLED=1` enables.
- Explicit `MOTAS_CLAUDE_CODE_ENABLED=0` disables.
- If absent, use persisted setting.
- `MOTAS_CLAUDE_STATUS_FILE` overrides persisted path.

9Router:

- Valid `MOTAS_9ROUTER_URL` overrides URL and enables connector.
- Otherwise use persisted enabled state and URL.
- `MOTAS_9ROUTER_DASHBOARD_TOKEN` overrides Keychain.
- `MOTAS_9ROUTER_CLI_TOKEN` overrides Keychain.

CLIProxyAPI:

- Valid `MOTAS_CLIPROXYAPI_URL` overrides URL and enables connector.
- Otherwise use persisted enabled state and URL.
- `MOTAS_CLIPROXYAPI_KEY` overrides Keychain.
- `MOTAS_CLIPROXYAPI_MANAGEMENT_KEY` overrides Keychain.

Empty secret environment values count as absent and fall back to Keychain.

Do not read a connector's Keychain items when that connector is disabled. Do not read an individual Keychain item when a non-empty environment secret already wins precedence. This avoids irrelevant locked-Keychain errors and makes source labels deterministic.

Environment values must never be copied into settings JSON or Keychain.

### Adapt `Sources/MotasApp/EnvironmentConnectorFactory.swift`

Keep the filename to reduce diff size, but turn it into a thin app adapter:

- Preserve existing `connectors(environment:)` behavior for development compatibility.
- Add an overload accepting settings and a secret store.
- Delegate all merge/precedence rules to the Core resolver.
- Instantiate the existing immutable connectors from resolved configurations.

Do not duplicate precedence logic in MotasApp.

### Add resolver tests

Create `Tests/MotasCoreTests/ConnectorConfigurationResolverTests.swift`.

Required cases:

1. Persisted Claude configuration resolves.
2. Persisted 9Router resolves both Keychain tokens.
3. Persisted CLIProxyAPI resolves both Keychain keys.
4. Environment-only behavior matches current documented behavior for valid absolute HTTP/HTTPS URLs.
5. Environment URL overrides persisted URL.
6. Environment secret overrides Keychain.
7. Empty environment secret falls back to Keychain.
8. `MOTAS_CLAUDE_CODE_ENABLED=0` disables persisted Claude.
9. 9Router remains primary/required.
10. CLIProxyAPI is fallback when 9Router is enabled.
11. CLIProxyAPI is primary/required without 9Router.
12. Keychain failure produces only sanitized issues.
13. Environment values are not persisted.
14. Disabled connectors do not query Keychain.
15. Environment-overridden secret keys do not query Keychain.
16. Invalid/relative environment URLs emit a sanitized issue and fall back safely.
17. Endpoint paths are rejected or normalized according to the supported suffix rules.

### Verify checkpoint 2

```bash
swift test --filter ConnectorConfigurationResolverTests
swift test
swift build --product MotasPrototype
git diff --check
```

Do not print or inspect real credential values during verification.

---

## Checkpoint 3: Persistent Settings UI and AppModel lifecycle

Suggested commit:

```text
feat(settings): add connector configuration UI
```

### Modify `Sources/MotasApp/MotasApp.swift`

Give `AppModel` injectable dependencies without adding a DI framework:

- Settings store.
- Secret store.
- Environment dictionary.
- Automatic-refresh scheduler (added in checkpoint 4, or introduce a protocol seam now).
- Existing snapshot persistence path/factory if needed for tests.

Production defaults:

- `JSONConnectorSettingsStore` at Application Support `settings.json`.
- `KeychainConnectorSecretStore`.
- `ProcessInfo.processInfo.environment`.

Add published state as needed:

```text
settings
configurationError
settingsSaveError
isSavingSettings
isDemoMode
effective connector/source metadata
```

Keep `lastRefreshError` for refresh/snapshot persistence errors. Do not reuse it for settings failures.

### Startup sequence

Perform this exact sequence:

1. Load persisted settings.
2. Missing document: load in-memory defaults and remember that nothing is persisted.
3. Malformed document: publish a sanitized error, use in-memory defaults and do not overwrite the file.
4. Resolve effective configuration using settings, environment and Keychain.
5. Build connector values.
6. Initialize snapshot:
   - Effective connectors exist: unknown snapshot, then immediate refresh.
   - No settings document and no environment connectors: retain explicit demo behavior.
   - Persisted settings exist but all connectors are disabled: honest unknown/no-primary state, not green demo data.
7. Persist initial non-secret snapshot.
8. Start automatic refresh only when enabled and connectors exist.

### Saving settings

Add an operation such as:

```text
saveSettings(_:secretUpdates:secretRemovals:)
```

Order:

1. Validate all non-secret settings.
2. Mark save in progress.
3. Apply explicit Keychain replacements/removals.
4. Save settings JSON.
5. Replace published in-memory settings only after JSON save succeeds.
6. Increment configuration revision.
7. Re-resolve and rebuild connectors.
8. Restart/stop scheduler as needed.
9. Request one immediate refresh using the new configuration.
10. Clear save state or publish sanitized error.

Keychain and filesystem writes are not a true transaction:

- If a Keychain operation fails, do not save settings JSON.
- If Keychain succeeds but JSON save fails, retain old in-memory settings and report the error.
- Do not implement destructive automatic rollback.
- Important: replacing an existing stable Keychain account before a JSON failure changes the credential that the old persisted endpoint will use on the next resolution/relaunch; it is not merely an orphan. Surface this as a partial-save error instructing the user to retry saving or restore the previous credential.
- Add a test or deterministic fake-store scenario for “Keychain replacement succeeds, settings JSON save fails.”

### Modify `Sources/MotasApp/SettingsView.swift`

Replace the placeholder connector labels with a real form.

Global section:

- Automatic refresh toggle.
- Text: “Refreshes every 5 minutes while Motas is running.”
- Sanitized configuration/save errors.

Claude Code section:

- Enabled toggle.
- Status-file path.
- Effective source/override label.
- Note that Motas reads a sanitized status-line cache and stores no Claude credential.

9Router section:

- Enabled toggle.
- Endpoint URL.
- Dashboard-token `SecureField`.
- CLI-token `SecureField`.
- Status per secret: environment, Keychain or missing.
- Explicit remove action per stored secret.

Removal is staged in the draft UI and applied only when the user presses Save. Canceling or closing without Save must not delete credentials. After a failed Save, keep the staged removal state so the user can retry.

CLIProxyAPI section:

- Enabled toggle.
- Endpoint URL.
- Proxy API key `SecureField`.
- Management key `SecureField`.
- Status and explicit remove action per secret.

Secret-field rules:

- Fields always open empty.
- Never load an existing credential into a `SecureField`.
- Empty on Save means unchanged.
- Non-empty on Save means replace.
- Delete only through an explicit remove action.
- Clear transient fields after successful save.
- Preserve input after failure so the user can retry.
- If environment supplies a secret, show “Provided by environment.”

Use one explicit Save button and disable it while saving.

Prototype scenario controls appear only when `isDemoMode` is true.

### Minimal popover adjustment

Modify `Sources/MotasApp/StatusPopoverView.swift` only if required:

- Manual refresh must use the same coalescing refresh pipeline.
- Keep the refresh button disabled while a batch runs.
- Keep settings/configuration errors separate from refresh errors.
- A small “Demo” label is optional.

Do not add connector editing to the popover.

### Verify checkpoint 3

```bash
swift test
swift build --product MotasPrototype
swift run MotasPrototype
git diff --check
```

Manual checks:

1. Save enabled states and endpoints.
2. Quit and relaunch.
3. Confirm non-secret settings survive.
4. Confirm secure fields remain blank.
5. Confirm stored-state labels are correct.
6. Confirm a persisted all-disabled setup reports unknown, not ready demo data.
7. Confirm environment-only launch still works without settings/Keychain.
8. Confirm staged secret removal does nothing until Save.
9. Confirm Keychain replacement followed by settings-write failure produces a clear partial-save error and does not falsely report full success.
10. If WidgetCenter reload is not implemented, document it explicitly as deferred rather than claiming the ADR is satisfied.

---

## Checkpoint 4: Safe scheduled refresh and concurrency hardening

Suggested commit:

```text
feat(refresh): add cancellable automatic connector refresh
```

### Add `Sources/MotasCore/Refresh/AutomaticRefreshScheduler.swift`

Recommended symbols:

- `AutomaticRefreshScheduler`
- `AutomaticRefreshPolicy`

A small `@MainActor` scheduler is sufficient.

Requirements:

- Own exactly one `Task<Void, Never>?`.
- `start(interval:operation:)` cancels the previous task.
- `stop()` cancels and clears it.
- Sleep before each scheduled operation; startup refresh remains explicit.
- Use cancellation-aware `Task.sleep`.
- Exit immediately on cancellation.
- Run operation, then sleep again.
- Never replay missed ticks after sleep/wake.
- Clamp intervals to at least 60 seconds.
- Default interval is 300 seconds.

Inject the sleep operation for deterministic tests:

```swift
@Sendable (Duration) async throws -> Void
```

### Harden `AppModel.refresh()`

The current `guard !isRefreshing else { return }` loses refresh requests. Replace it with coalescing state:

```text
isRefreshing
refreshPending
configurationRevision
```

Algorithm:

1. If already refreshing, set `refreshPending = true` and return.
2. Capture current connector array and configuration revision.
3. Run one `ConnectorRefresher` batch.
4. Apply/persist the result only if captured revision still equals current revision.
5. Discard obsolete results after settings changes.
6. Clear running state.
7. If pending, immediately run one more batch with current connectors.
8. Collapse any number of triggers into at most one pending batch.

All state transitions remain on `@MainActor`; do not add locks.

### Scheduler lifecycle

Restart scheduler after:

- Automatic refresh toggle changes.
- Enabled connectors change.
- Endpoint changes.
- Credential replacement/removal changes effective configuration.
- Initial configuration resolution at launch.

Stop scheduler when:

- Automatic refresh is disabled.
- No effective connectors exist.
- An explicit app/model lifecycle shutdown path runs.

Do not require `AppModel.deinit` to synchronously call an `@MainActor` scheduler method; Swift 6 treats `deinit` as nonisolated. The scheduler must cancel its owned task through a nonisolated-safe lifetime design, or the app must call an explicit main-actor shutdown method. Avoid a retain cycle between scheduler task and `AppModel`.

### Add scheduler tests

Create `Tests/MotasCoreTests/AutomaticRefreshSchedulerTests.swift` using a controlled fake sleeper.

Required cases:

1. Start does not refresh immediately.
2. One released sleep produces one refresh.
3. Next interval starts only after current operation finishes.
4. Calling start again cancels old loop.
5. Stop prevents future operations.
6. Cancellation during sleep exits cleanly.
7. Unsafe interval clamps to minimum.
8. Default is five minutes.
9. Missed intervals are not replayed.

Add a small, UI-independent refresh-coalescing coordinator in MotasCore and test it from `MotasCoreTests`; `AppModel` should adapt that state machine on `@MainActor`. Do not move SwiftUI-specific published state into Core.

Required coalescing cases:

- Two triggers during one refresh cause exactly one follow-up batch.
- Configuration revision change discards old result.
- New configuration receives an immediate pending refresh.

### Verify checkpoint 4

```bash
swift test --filter AutomaticRefreshSchedulerTests
swift test
swift test --parallel
swift build --product MotasPrototype
swift build -Xswiftc -strict-concurrency=complete --product MotasPrototype
git diff --check
```

## 6. Documentation updates required during implementation

Add:

```text
docs/architecture/settings-keychain-auto-refresh.md
```

Document:

- Settings file path/schema.
- App-only Keychain boundary.
- Keychain service and account names.
- Environment precedence.
- Save/removal semantics.
- Five-minute scheduler behavior. State that it supersedes the earlier one-minute adaptive-refresh suggestion in `docs/architecture/normalized-status-model.md` for this milestone, and update that older document to avoid contradiction.
- Refresh coalescing and configuration revision.
- Swift 6 isolation choices.
- Keychain/filesystem partial transaction limitation.
- Command Line Tools verification and deferred Xcode checks.

Update:

- `README.md`
- `docs/connectors/claude-code.md`
- `docs/connectors/9router.md`
- `docs/connectors/cliproxyapi.md`

README policy after implementation:

- Settings + Keychain are normal app configuration.
- Environment variables remain development overrides.
- Environment values override persisted values for that process.
- Environment credentials are not imported into Keychain.
- Settings JSON location and Keychain service may be documented, but never secret values.

## 7. Security invariants

These are hard requirements:

- Never add secrets to `MotasSettings`.
- Never add secrets to `StatusSnapshot` or App Group files.
- Never echo credentials in logs, UI errors or tests.
- Never request password output with `security -w` or `security -g` in automated verification.
- Never expose Keychain to WidgetKit.
- Never read Claude OAuth credentials.
- Never silently accept endpoint URLs containing embedded credentials.
- Automatic refresh must not display Keychain authentication UI.
- Environment credentials remain process-local overrides.

When checking Keychain metadata manually, commands may omit secret output:

```bash
security find-generic-password \
  -s dev.motas.app.connectors \
  -a 9router.dashboard-token
```

## 8. Likely failure modes

### Keychain access differs between SwiftPM and signed app

SwiftPM executable, development-signed app and release app may have different Keychain ACL identities.

Required response:

- Keep environment configuration working.
- Compile the adapter under SwiftPM.
- Validate persistence using the final signed app later.
- Do not add a Keychain access group just to share CLI and app credentials.

### Keychain locked or interaction disallowed

- Return a sanitized issue.
- Do not show authentication UI during refresh.
- Continue public connector health checks when possible.
- Do not misclassify missing monitoring authorization as network unreachable.

### Malformed settings JSON

- Do not crash.
- Do not overwrite at startup.
- Use in-memory defaults and show a sanitized error.
- Permit an explicit Save to replace it later.

### Settings write fails after Keychain update

- Keep old in-memory settings.
- Report a partial-save failure.
- Explain that an updated stable Keychain item may now be used with the old persisted endpoint/configuration after re-resolution or relaunch.
- Tell the user to retry Save or restore the previous credential.
- Do not attempt untested destructive rollback.

### Environment override is confusing

- Show “Provided by environment” or “Overridden by environment.”
- Removing a Keychain record must not claim an environment-provided credential disappeared.

### Duplicate or obsolete refreshes

- Scheduler owns one loop.
- Start always cancels old loop.
- Configuration revision prevents stale result application.
- Coalescing allows at most one pending batch.

### Swift 6 isolation errors

- Keep settings/configuration as immutable `Sendable` value types.
- Keep UI state on `@MainActor`.
- Keep Security dictionaries local to methods.
- Avoid broad `@unchecked Sendable`.
- Do not store mutable shared `FileManager` state.

## 9. Non-goals

Do not implement as part of this milestone:

- Guided onboarding.
- Test-connection buttons.
- Multiple instances of one connector type.
- User-editable roles or route priority.
- Per-connector/custom refresh frequencies.
- One-minute adaptive polling.
- Refresh while the app is not running.
- Launch at login.
- Background daemon/XPC.
- Sleep/wake notification integration.
- Notifications or cooldown rules.
- Status history or diagnostics export.
- Environment-secret import into Keychain.
- Claude credential/OAuth access.
- Keychain sharing with widget.
- App Store sandbox work.
- Proxy mutation/start/stop/reset operations.
- Generalized plugin architecture.
- Guaranteed real-time WidgetKit refresh. After a successfully applied meaningful snapshot change, request `WidgetCenter.shared.reloadTimelines(ofKind:)` only if this can be compiled in the app target; otherwise explicitly document the existing ADR requirement as deferred pending full-Xcode validation.

## 10. Current-machine verification

The current machine has Swift 6 and Apple Command Line Tools, but full Xcode is not selected.

Run after every checkpoint:

```bash
cd /Users/macos/Documents/MacProject/Motas

git status --short
git diff --check
swift --version
swift package describe
swift test
swift test --parallel
swift build --product MotasPrototype
swift build -Xswiftc -strict-concurrency=complete --product MotasPrototype
```

Environment compatibility smoke test:

```bash
MOTAS_CLAUDE_CODE_ENABLED=1 \
MOTAS_9ROUTER_URL=http://localhost:20128 \
MOTAS_CLIPROXYAPI_URL=http://localhost:8317 \
swift run MotasPrototype
```

`swift run MotasPrototype` is an interactive manual smoke test and will keep the menu bar process running; do not use it as an unattended finite CI command.

Inspect settings JSON without printing Keychain data:

```bash
python3 -m json.tool \
  "$HOME/Library/Application Support/Motas/settings.json"
```

The file may contain endpoints, booleans, schema version and Claude status path. It must not contain:

```text
dashboardToken
cliToken
proxyAPIKey
managementKey
authorization
cookie
```

## 11. Deferred full-Xcode verification

After full Xcode is installed and selected:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
brew install xcodegen
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

Manual signed-app checks:

1. Save, replace and remove all four credential types.
2. Quit/relaunch and confirm credentials remain available.
3. Confirm replacing a credential does not create duplicates.
4. Confirm auto-refresh never opens a Keychain prompt.
5. Lock/unlock and confirm normal refresh resumes.
6. Sleep/wake and confirm no refresh burst.
7. Change endpoint during an in-flight refresh and confirm old result is discarded.
8. Verify widget reads only normalized App Group snapshot.
9. Inspect snapshot for secrets.
10. Verify widget has no Keychain entitlement.
11. Verify App Group signing and medium/large widget behavior.

## 12. Handoff instructions for DeepSeek

Start by reading the documentation-only plan branch, then create a separate implementation branch:

```bash
git fetch origin
git checkout plan/settings-keychain-auto-refresh
git pull --ff-only
git switch -c feat/settings-keychain-auto-refresh
```

Do not commit production implementation to the `plan/` branch.

Before coding:

1. Read this document completely.
2. Read `AGENTS.md`.
3. Run baseline `swift test` and `swift build --product MotasPrototype`.
4. Confirm working tree is clean.
5. Implement checkpoint 1 only.

For each checkpoint:

1. Add failing tests first where practical.
2. Make the minimum production change.
3. Run the checkpoint-specific commands and full test suite.
4. Review `git diff --check` and inspect for secrets.
5. Commit only that checkpoint.
6. Include this trailer as the final commit line:

```text
Co-authored-by: claude-chan <claude-chan@thatnghiep.dev>
```

Do not claim widget, signing or live Keychain verification unless full Xcode and a signed app were actually used.
