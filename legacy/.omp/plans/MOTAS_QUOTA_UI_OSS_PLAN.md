# Motas — real proxy quota + Control-Center-grade macOS UI + MIT/Homebrew release

## Context

Motas (`/Users/macos/Documents/MacProject/Motas`, git remote `git@github.com:dinhkarate/Motas.git`) is a SwiftUI `MenuBarExtra` app that is supposed to show AI coding quota. Today it shows almost nothing: `CLIProxyAPIConnector` and `NineRouterConnector` both return `ProxyStatus` with **zero `quotaWindows`** and `quality: .partial`, so the panel renders health dots and prose only. Only `ClaudeCodeConnector` (status-line file) produces percentages.

End state: Motas reads **real quota numbers out of the proxies themselves** (CLIProxyAPI `POST /v0/management/quota/fetch`, 9Router `GET /api/usage/{connectionId}`), renders them in a Control-Center-density menu bar panel with a quota ring and per-window bars, ships as MIT open source, and installs with `brew install --cask --no-quarantine dinhkarate/motas/motas`. macOS only; Windows/Linux are not targets.

Environment facts that constrain everything (verified this session): macOS 14.8.2, Swift 6.0.3, **Command Line Tools only — no Xcode, `xcodebuild` unavailable**, **0 codesigning identities**. `iconutil`, `sips`, `plutil`, `codesign`, `ditto`, `brew`, `xcodegen` are present. Baseline `swift build --product MotasPrototype` succeeds and `swift test` passes **98 tests**.

Decisions already made by the user, not open: MIT license; delete the WidgetKit widget and the xcodegen project; ad-hoc signing + Homebrew **cask** with a documented `--no-quarantine` caveat; Control-Center-density visual style.

---

## Approach

### Step 1 — Repo cutover to a SwiftPM-only, buildable, MIT app

Delete (all unbuildable without Xcode, all superseded):

- `Sources/MotasWidget/` (whole directory)
- `Motas.xcodeproj/` (whole directory)
- `project.yml`
- `Config/Motas.entitlements`, `Config/MotasWidget.entitlements` (then the empty `Config/`)
- `docs/release-pricing-strategy.md` (paid trial/licence strategy contradicts MIT open source)

Remove the App Group machinery, which existed only to feed the widget. Exact edits:

- `Sources/MotasCore/Persistence/SnapshotStore.swift`: delete `SnapshotStoreError` and the `init(appGroupIdentifier:filename:fileManager:)` initializer. Keep `defaultFilename`, `init(fileURL:)`, `save`, `load`.
- `Sources/MotasCore/Configuration/MotasConfiguration.swift`: delete `appGroupIdentifier`.
- `Sources/MotasAppKit/MotasApp.swift`: in `persistSnapshot()` (line ~372) drop the app-group branch and always use the Application Support store; in `resetMotasData()` (line ~291) drop the app-group snapshot removal.

Restructure the app target now, so the whole rest of the plan uses one set of paths and Step 10's gallery can `import MotasAppKit`. `git mv Sources/MotasApp Sources/MotasAppKit`, then in `Package.swift`:

- product `.executable(name: "MotasPrototype", targets: ["MotasApp"])` → `.executable(name: "Motas", targets: ["MotasMain"])`
- target `.executableTarget(name: "MotasApp", …)` → `.target(name: "MotasAppKit", dependencies: ["MotasCore"], path: "Sources/MotasAppKit", linkerSettings: [.linkedFramework("Security")])` — the `Security` linker setting moves with it
- add `.executableTarget(name: "MotasMain", dependencies: ["MotasAppKit"], path: "Sources/MotasMain")`

Create `Sources/MotasMain/main.swift` containing exactly `import MotasAppKit` and `MotasApp.main()`. In `Sources/MotasAppKit/MotasApp.swift` mark `struct MotasApp` and its `body` `public`, add a `public init()`, and mark `AppModel` and its `@Published` properties and methods `public` (`private(set)` becomes `public private(set)`). `SettingsView`, `PanelView`, `MenuBarIcon`, `MotasTheme`, `QuotaRing`, `QuotaBar` and `Tile` are `public` as they are created in Steps 7–9. `EnvironmentConnectorFactory`, `KeychainConnectorSecretStore` and `TransientSecretStore` stay internal.

Update the four `MotasPrototype` mentions in `README.md` (lines 56, 57, 60, 74) to `Motas`.

Add `LICENSE` at repo root: verbatim MIT text, `Copyright (c) 2026 dinhkarate`.

Fix two real defects that the widget-era design hid:

- No Dock-icon suppression outside a bundle. In `MotasApp.swift`, add to `struct MotasApp: App` an `init()` containing `NSApplication.shared.setActivationPolicy(.accessory)`.
- No way to quit. Handled in Step 7's footer.

`.gitignore`: add `dist/` and `.DS_Store`.

Gate: `swift build --product Motas && swift test` — 98 tests still pass.

### Step 2 — Settings schema v2

`Sources/MotasCore/Configuration/ConnectorSettings.swift`, `struct MotasSettings`: bump `currentSchemaVersion` to `2` and add stored properties, all with defaults:

```swift
public var automaticRefreshInterval: TimeInterval   // default 300
public var quotaProbeEnabled: Bool                  // default true
public var quotaProbeInterval: TimeInterval         // default 600
public var showMenuBarPercentage: Bool              // default true
public var tintMenuBarWhenLow: Bool                 // default true
public var launchAtLogin: Bool                      // default false
```

Synthesized `Codable` would reject existing v1 `settings.json`. Write an explicit `init(from decoder:)` that uses `decodeIfPresent` for every property and substitutes the defaults above, and always encodes `schemaVersion: 2`. `validated()` additionally clamps `automaticRefreshInterval` into `60...3600` and `quotaProbeInterval` into `300...7200`; clamping is silent, not an error.

`Sources/MotasAppKit/MotasApp.swift` `configureAutomaticRefresh()`: replace `MotasConfiguration.defaultAutomaticRefreshInterval` with `settings.automaticRefreshInterval`.

Test (`Tests/MotasCoreTests/ConnectorSettingsStoreTests.swift`): decoding a JSON document containing only the v1 keys yields `automaticRefreshInterval == 300`, `quotaProbeEnabled == true`, `schemaVersion == 2` after re-encode. This defends the upgrade path for users who already have `~/Library/Application Support/Motas/settings.json`.

### Step 3 — Quota probe core in MotasCore

New file `Sources/MotasCore/Connectors/QuotaProbe.swift`:

```swift
public enum RefreshTrigger: Sendable, Equatable { case scheduled, manual }

public struct QuotaProbePolicy: Sendable, Equatable {
    public var isEnabled: Bool          // default true
    public var interval: TimeInterval   // default 600
    public var manualFloor: TimeInterval // default 60
    public var cacheMaximumAge: TimeInterval // default 3600
}

public actor QuotaProbeCache {
    public init(policy: QuotaProbePolicy = .init())
    public func setPolicy(_ policy: QuotaProbePolicy)
    /// false when disabled, cooling down, or previously marked unsupported.
    public func shouldProbe(key: String, trigger: RefreshTrigger, now: Date) -> Bool
    public func store(_ windows: [QuotaWindow], key: String, now: Date)
    public func markUnsupported(key: String)
    public func markFailure(key: String, now: Date)
    /// Windows from the last successful probe if newer than `cacheMaximumAge`.
    public func cached(key: String, now: Date) -> [QuotaWindow]?
}
```

Cooldown rule: `shouldProbe` returns true when no entry exists, or `now - lastAttempt >= interval` for `.scheduled`, or `now - lastAttempt >= manualFloor` for `.manual`. `markUnsupported` is permanent for the process lifetime (used for HTTP 501/404 from a quota endpoint) and makes `shouldProbe` return false forever for that key. `markFailure` records `lastAttempt` so a broken account is not hammered.

`Sources/MotasCore/Connectors/StatusConnector.swift`: change the requirement to `func refresh(trigger: RefreshTrigger) async -> ConnectorResult` and add

```swift
public extension StatusConnector {
    func refresh() async -> ConnectorResult { await refresh(trigger: .scheduled) }
}
```

so the ~20 existing `await connector.refresh()` callsites in `Tests/MotasCoreTests/` keep compiling. `StaticConnector.refresh(trigger:)` ignores the trigger. `ClaudeCodeConnector.refresh(trigger:)` ignores it (local file read, no rate limit).

`Sources/MotasCore/Connectors/ConnectorRefresher.swift`: add `trigger: RefreshTrigger` to `refresh()` → `public func refresh(trigger: RefreshTrigger = .scheduled) async -> StatusSnapshot`, forwarded into each `connector.refresh(trigger:)`. `ConnectorTestRunner.run` passes `.manual`.

New file `Sources/MotasCore/Utilities/FlexibleDate.swift`:

```swift
public enum FlexibleDate {
    /// Parses ISO8601 with and without fractional seconds, and numeric epoch
    /// seconds or milliseconds supplied as a string. Returns nil otherwise.
    public static func parse(_ raw: String?) -> Date?
}
```
Numeric discrimination matches 9Router's own rule: value `< 1e12` is seconds, otherwise milliseconds. Never invent a reset time — `nil` in, `nil` out.

New file `Sources/MotasCore/Connectors/QuotaAggregation.swift`:

```swift
public enum QuotaAggregation {
    /// Lowercases and replaces every run of non-alphanumeric characters with a
    /// single "-", trimming leading and trailing separators. Empty input yields
    /// "quota". Both proxy connectors use this for QuotaWindow ids.
    public static func slug(_ raw: String) -> String

    /// Route-level view of a rotating account pool: for each distinct window
    /// `name`, keep the account bucket with the HIGHEST remainingFraction,
    /// because a router can still serve traffic through the best account.
    /// Result is sorted by window name ascending for snapshot determinism.
    public static func routeWindows(
        from accounts: [ProxyAccountStatus],
        idPrefix: String
    ) -> [QuotaWindow]
}
```
Output ids are `"\(idPrefix)/route/\(slug(name))"`, `unit: .percentage`, `isEnforced: true`, `resetsAt` copied from the winning bucket. Windows whose `remainingFraction` is nil are excluded. This is what makes `ReadinessEngine`'s existing "Proxy quota running low" branch fire on real data.

Also add to `QuotaAggregation`:

```swift
/// .exhausted when every account is exhausted, .healthy when at least one is
/// healthy, .degraded otherwise, .unknown when the list is empty.
public static func poolHealth(_ accounts: [ProxyAccountStatus]) -> OperationalHealth
```
One dead account out of five must not degrade the whole route.

Gate: `swift test` — 98 tests still pass.

### Step 4 — CLIProxyAPI quota connector

`Sources/MotasCore/Connectors/CLIProxyAPIConnector.swift`.

`CLIProxyAPIConfiguration` gains `public let quotaCache: QuotaProbeCache?` (nil disables probing). `refresh(trigger:)` keeps the existing `GET /v1/models` reachability check and the existing `GET /v0/management/auth-files` account mapping unchanged, then probes quota for each account.

Per account with a non-empty `auth_index`, when `await cache.shouldProbe(key: "cliproxyapi/\(authIndex)", trigger:, now:)`:

`POST` to `EndpointNormalizer.url(base:, path: "/v0/management/quota/fetch")`, `Content-Type: application/json`, `Accept: application/json`, `Authorization: Bearer <managementKey>`, `timeoutInterval: 8`, body `{"auth_index":"<authIndex>"}`.

Response decoding (`QuotaFetchResponse` from CLIProxyAPI v7 `sdk/pluginapi/types.go`; its custom marshalers emit camelCase **and** snake_case aliases, so decoding camelCase alone is correct and complete):

```swift
private struct CPAQuotaResponse: Decodable {
    struct Subscription: Decodable { let plan: String?; let tierName: String? }
    struct Bucket: Decodable {
        let window: String?
        let remainingFraction: Double?
        let resetTime: String?
        let description: String?
    }
    struct Group: Decodable { let displayName: String?; let buckets: [Bucket]? }
    let subscription: Subscription?
    let groups: [Group]?
}
```

Status handling — no retries, no mutation endpoints ever:

- `200` → map buckets; `await cache.store(windows, key:, now:)`.
- `501` (`{"error":"no quota provider available for credential"}`) or `404` → `await cache.markUnsupported(key:)`. 501 is decided by the plugin registry before any upstream call, so probing to discover support is free; this is why `GET /v0/management/quota/providers` is deliberately not used.
- `401`/`403` → `markFailure`, and the proxy message becomes `"CLIProxyAPI is running, but the management key was rejected."` (existing literal).
- Anything else, decode failure, or transport error → `markFailure`, keep the account without windows.

Bucket → `QuotaWindow` mapping, skipping any bucket whose `remainingFraction` is nil:

- `id`: `"cliproxyapi/\(authIndex)/\(slug(groupName))/\(slug(windowName))"`
- `name`: `windowName` when `groupName` is empty; `groupName` when `windowName` is empty; `"\(groupName) · \(windowName)"` when both exist; `"Quota"` when neither.
- `unit: .percentage`, `remainingFraction:` clamped to `0...1` by the `QuotaWindow` initializer, `resetsAt: FlexibleDate.parse(bucket.resetTime)`, `isEnforced: true`.

Account assembly: `ProxyAccountStatus.quotaWindows` = mapped windows (or `await cache.cached(key:)` when the cooldown suppressed the probe); account `health` becomes `.exhausted` when any enforced window has `remainingFraction == 0`, otherwise the existing `auth-files` status mapping stands. `subscription.plan`/`tierName`, when present, is appended to the account `label` as `"\(label) · \(plan)"`.

Proxy assembly: `ProxyStatus.quotaWindows = QuotaAggregation.routeWindows(from: accounts, idPrefix: "cliproxyapi")`; `health = QuotaAggregation.poolHealth(accounts)`; `quality` is `.fresh` when at least one account returned windows and none failed, `.partial` otherwise. Message when quota exists: `"\(usable) of \(accounts.count) accounts available · quota from \(windowCount) provider windows."`; keep the existing partial-data messages when it does not.

New tests in `Tests/MotasCoreTests/ProxyConnectorTests.swift` against a stubbed `HTTPTransport` (the file already stubs one):

- A `quota/fetch` body `{"subscription":{"plan":"Pro"},"groups":[{"displayName":"Claude","buckets":[{"window":"5-hour","remainingFraction":0.34,"resetTime":"2026-09-14T12:00:00Z"}]}]}` yields exactly one account window named `"Claude · 5-hour"` with `remainingFraction == 0.34` and a non-nil `resetsAt`, and one route window with the same fraction.
- Two accounts, `0.10` and `0.80` on the same window name → route window is `0.80` (pool semantics).
- `501` marks the account unsupported and a second `refresh(trigger: .manual)` issues **no** second `quota/fetch` request (assert the stub's recorded request count).
- A bucket with `"remainingFraction": null` produces no window rather than `0%`.

### Step 5 — 9Router quota connector

`Sources/MotasCore/Connectors/NineRouterConnector.swift`. Same shape: `NineRouterConfiguration` gains `quotaCache`, `refresh(trigger:)` keeps `GET /api/health` and `GET /api/providers` unchanged, then probes.

Extend the private `Connection` decodable with `let authType: String?` (`/api/providers` strips only `apiKey`, `accessToken`, `refreshToken`, `idToken`, so `authType` is present).

Per connection where `isActive != false` and `authType` is `"oauth"`, `"apikey"` or `"api_key"`, and the cooldown allows: `GET /api/usage/{connectionId}` with the same protected headers the connector already builds (`x-9r-cli-token`, else `Cookie: auth_token=…`), `timeoutInterval: 10`. **Never** append `?force=1` — that bypasses 9Router's own 5-minute upstream cache and will trigger provider 429s.

```swift
private struct NineRouterUsageResponse: Decodable {
    struct Quota: Decodable {
        let used: Double?; let total: Double?; let remaining: Double?
        let remainingPercentage: Double?; let resetAt: String?; let unlimited: Bool?
    }
    let plan: String?
    let message: String?
    let error: String?
    let quotas: [String: Quota]?
}
```

The legacy admin path returns arbitrary JSON under `quotas`, so a decode failure of `quotas` must degrade to "no windows, quality partial", never to an error state. Decode the envelope first; if `quotas` fails to decode, keep `plan`/`message`.

Window mapping per `(key, quota)` pair, sorted by key for determinism:

- Skip when `unlimited == true`.
- `remainingFraction` = `remainingPercentage / 100` when present, else `remaining / total` when `total > 0`, else skip the entry entirely.
- `id`: `"9router/\(connectionId)/\(slug(key))"`, `name`: the raw key (`"session (5h)"`, `"weekly (7d)"`, `"weekly opus (7d)"`), `unit: .percentage`, `resetsAt: FlexibleDate.parse(quota.resetAt)`, `isEnforced: true`.

Status handling: `200` with quotas → `store`; `200` with only `message`/`error` → `markFailure`; `401`/`403` → `markFailure` plus the existing authorization message; `404` → `markUnsupported`; other → `markFailure`. Route aggregation, pool health and quality follow Step 4 with `idPrefix: "9router"`.

Tests in `Tests/MotasCoreTests/ProxyConnectorTests.swift`: a `{"plan":"Claude Code","quotas":{"session (5h)":{"remainingPercentage":13,"resetAt":"1789000000"}}}` payload yields one window named `"session (5h)"` with `remainingFraction == 0.13` and `resetsAt` decoded from epoch **seconds**; `{"quotas":{"x":{"unlimited":true}}}` yields no windows; `{"message":"Claude connected. Unable to fetch usage: …"}` leaves the connection healthy with `quality == .partial`.

### Step 6 — Wire the cache and cold start into AppModel

`Sources/MotasAppKit/MotasApp.swift`:

- Add `private let quotaCache = QuotaProbeCache()`; after each settings load/save call `await quotaCache.setPolicy(QuotaProbePolicy(isEnabled: settings.quotaProbeEnabled, interval: settings.quotaProbeInterval, manualFloor: 60, cacheMaximumAge: 3600))`.
- `refresh()` becomes `func refresh(trigger: RefreshTrigger = .scheduled) async`, passing the trigger into `ConnectorRefresher(...).refresh(trigger:)`. The scheduler passes `.scheduled`; the panel's Refresh button and `saveSettings` pass `.manual`.
- Cold start: in `init`, after `loadSettings()`/`rebuildConnectors()`, replace `snapshot = isDemoMode ? MockData.readySnapshot() : MockData.unknownSnapshot()` with: when not in demo mode, try `SnapshotStore(fileURL: …/motas-status-snapshot.json).load()` and use it if present, so the panel opens with the last known state instead of "Readiness unknown". Demo mode keeps `MockData.readySnapshot()`.

`Sources/MotasAppKit/EnvironmentConnectorFactory.swift`: add `quotaCache: QuotaProbeCache?` to both public `connectors(...)` entry points and thread it into `NineRouterConfiguration` / `CLIProxyAPIConfiguration`. `ConnectorConfigurationResolver.resolve` gains a `quotaCache: QuotaProbeCache?` parameter (default `nil`) and stores it on the two configurations it builds; `AppModel.testSettings` passes `nil` so a Settings connection test never burns an upstream provider call.

### Step 7 — The panel

Delete `Sources/MotasAppKit/StatusPopoverView.swift`. Create:

**`Sources/MotasAppKit/Design/MotasTheme.swift`** — every magic number lives here, nowhere else:

```swift
enum MotasTheme {
    static let panelWidth: CGFloat = 340
    static let panelPadding: CGFloat = 14
    static let tileSpacing: CGFloat = 8
    static let tileCornerRadius: CGFloat = 10
    static let tileFill = Color.primary.opacity(0.055)
    static let tileStroke = Color.primary.opacity(0.07)
    static let heroRingDiameter: CGFloat = 72
    static let heroRingWidth: CGFloat = 8
    static let barHeight: CGFloat = 5
    static let cautionFraction = 0.20   // matches ReadinessPolicy
    static let criticalFraction = 0.05
    static func quotaTint(_ remaining: Double?) -> Color   // nil → .secondary,
        // < .05 → .red, < .20 → .orange, else → .green
}
```
Fixed opacities rather than `.quaternary`/`.quinary` so light and dark both read correctly and nothing depends on a material rendering inside `ImageRenderer` (Step 10 renders these views offscreen, where materials come out transparent).

**`Sources/MotasAppKit/Design/QuotaRing.swift`** — `QuotaRing(fraction: Double?, diameter: CGFloat, lineWidth: CGFloat, showsLabel: Bool)`. `ZStack` of a track `Circle().stroke(Color.primary.opacity(0.10), lineWidth:)` and `Circle().trim(from: 0, to: fraction).stroke(tint, style: StrokeStyle(lineWidth:, lineCap: .round)).rotationEffect(.degrees(-90))`, animated with `.animation(.smooth(duration: 0.25), value: fraction)`. Label is `Text("\(Int((fraction*100).rounded()))%")` in `.system(size: diameter * 0.28, weight: .semibold, design: .rounded)` over `Text("left").font(.caption2).foregroundStyle(.secondary)`. `fraction == nil` draws the track only and no label.

**`Sources/MotasAppKit/Design/QuotaBar.swift`** — one row: name `Text` `.caption` `.frame(width: 74, alignment: .leading)` `.lineLimit(1)` `.truncationMode(.tail)`; a `Capsule` track `Color.primary.opacity(0.10)` of height `barHeight` with a `Capsule` fill of `geometry.size.width * fraction`; `Text("\(pct)%")` `.caption.monospacedDigit()` `.frame(width: 36, alignment: .trailing)`; and, when `StatusPresentation.resetLabel(for:now:)` is non-nil, that string `.caption2.foregroundStyle(.secondary)`. When `remainingFraction == nil` the bar renders as track-only with `Text("—")` — never `0%`, per `docs/architecture/status-presentation.md`.

**`Sources/MotasAppKit/Design/Tile.swift`** — `Tile { content }` = `VStack(alignment: .leading, spacing: 6) { content }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: MotasTheme.tileCornerRadius, style: .continuous).fill(MotasTheme.tileFill)).overlay(RoundedRectangle(...).strokeBorder(MotasTheme.tileStroke))`.

**`Sources/MotasAppKit/PanelView.swift`** — `struct PanelView: View { @ObservedObject var model: AppModel }`, root `VStack(alignment: .leading, spacing: 12)`, `.padding(MotasTheme.panelPadding)`, `.frame(width: MotasTheme.panelWidth)`. No window-level material: `MenuBarExtra(.window)` already provides popover chrome.

1. **Hero.** `HStack(spacing: 12)`. Left: `QuotaRing` for the *tightest* window when one exists, else `Image(systemName: model.snapshot.readiness.state.symbolName)` at `.system(size: 26)` in a 56pt `Circle().fill(state.tint.opacity(0.15))`. Right: `readiness.title` `.headline`; `readiness.explanation` `.subheadline.foregroundStyle(.secondary)` `.fixedSize(horizontal: false, vertical: true)`; when a tightest window exists a third line `"\(window.name) · \(resetLabel)"` `.caption.foregroundStyle(.secondary)`. When `model.isDemoMode`, a `Text("DEMO").font(.caption2.weight(.bold))` capsule sits beside the title.

   Tightest-window rule, implemented as `StatusPresentation.tightestWindow(providers:proxies:) -> (name: String, remainingFraction: Double, resetsAt: Date?)?` in `Sources/MotasCore/Presentation/StatusPresentation.swift`: consider every `QuotaWindow` where `isEnforced` and `remainingFraction != nil`, drawn from `ProviderStatus.quotaWindows` and `ProxyStatus.quotaWindows` of sources whose `role` is `.primary` or `.fallback` (`.informational` excluded, matching the readiness rules); return the minimum by `remainingFraction`, ties broken by window `id` ascending. Unit-test this directly.

2. **Sources section.** `Text("SOURCES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)` then `VStack(spacing: MotasTheme.tileSpacing)` of one `Tile` per provider then per proxy, in snapshot order.

   Provider tile: header `HStack` = 7pt `Circle` in `health.tint`, `name` `.system(.body, weight: .medium)`, `Spacer()`, `health.displayName` `.caption.foregroundStyle(.secondary)`. Then a `QuotaBar` for each enforced window. Then, when `StatusPresentation.remediation(health:quality:)` is non-nil, `Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)`.

   Proxy tile: same header but the trailing text is `endpointLabel ?? health.displayName`; a `.caption.foregroundStyle(.secondary)` subtitle `"\(usable) of \(accounts.count) accounts · \(route.activeTier.displayName) tier"` (omit either clause when the data is absent); `QuotaBar`s for the route-level windows; and, when `accounts.count > 0`, a `DisclosureGroup("Accounts")` `.font(.caption)` listing per account a 6pt dot, the label, and its windows rendered as `"34% · 5-hour"` chips `.caption2.monospacedDigit()`.

3. **Empty state.** When `snapshot.providers.isEmpty && snapshot.proxies.isEmpty && !isDemoMode`, replace the sources section with a `Tile` containing `"No source connected"` `.headline`, `"Point Motas at CLIProxyAPI or 9Router to see live quota."` `.caption.foregroundStyle(.secondary)`, and a `SettingsLink { Text("Open Settings") }.buttonStyle(.borderedProminent).controlSize(.small)`.

4. **Footer.** `Divider()` then `HStack`: `Text("Updated \(StatusPresentation.relativeAge(of: snapshot.capturedAt, now: Date()))")` `.caption.foregroundStyle(.secondary)`; `Spacer()`; three `PanelIconButton`s — `arrow.clockwise` (`Task { await model.refresh(trigger: .manual) }`, disabled and swapped for a `ProgressView().controlSize(.small)` while `model.isRefreshing`, `.keyboardShortcut("r")`), `gearshape` wrapped in `SettingsLink`, and `power` calling `NSApplication.shared.terminate(nil)` with `.keyboardShortcut("q")`. `PanelIconButton` is a local `View` in `PanelView.swift`: 22×22, `.buttonStyle(.plain)`, `@State private var isHovering`, background `Circle().fill(Color.primary.opacity(isHovering ? 0.10 : 0))`, `.help(…)` on each. Below the footer, `model.lastRefreshError` still renders `.caption.foregroundStyle(.red)`.

   `Quit` did not exist before; without it a `MenuBarExtra(.window)` app installed from a cask cannot be closed.

   Contingency: if `SettingsLink` fails to open the window from the packaged bundle, replace the `Settings` scene with `Window("Motas Settings", id: "motas-settings")` and drive it with `@Environment(\.openWindow)`; do not add a second mechanism alongside `SettingsLink`.

### Step 8 — Menu bar icon

New `Sources/MotasAppKit/MenuBarIcon.swift`:

```swift
@MainActor
enum MenuBarIcon {
    /// Ring + optional percentage, rasterized for the status bar.
    static func image(
        fraction: Double?,
        state: ReadinessState,
        showsPercentage: Bool,
        tintWhenLow: Bool
    ) -> NSImage
}
```

Renders a `HStack(spacing: 3)` of a 14pt `QuotaRing(lineWidth: 2.5, showsLabel: false)` — falling back to `Image(systemName: state.symbolName)` at `.system(size: 13, weight: .semibold)` when `fraction == nil` — plus, when `showsPercentage` and a fraction exists, `Text("\(pct)%").font(.system(size: 11, weight: .medium)).monospacedDigit()`. Height is fixed at 18pt. Rasterize with `ImageRenderer` (macOS 13+), `renderer.scale = NSScreen.main?.backingScaleFactor ?? 2`, and set `nsImage.size` back to the point size so the status bar scales correctly.

Colour policy: when `tintWhenLow` is false, or the fraction is above `MotasTheme.cautionFraction` and the readiness state is `.ready`, force monochrome by rendering in `Color.primary` and setting `nsImage.isTemplate = true` — this is what makes the icon behave correctly in dark mode and under menu bar tinting. Otherwise render in the semantic colour and leave `isTemplate = false` so orange/red survive.

`MotasApp.body`: replace the `Label("Motas", systemImage: …)` label with `Image(nsImage: MenuBarIcon.image(fraction: StatusPresentation.tightestWindow(...)?.remainingFraction, state: model.snapshot.readiness.state, showsPercentage: model.settings.showMenuBarPercentage, tintWhenLow: model.settings.tintMenuBarWhenLow))` and the content with `PanelView(model: model)`.

### Step 9 — Settings window

Rewrite `Sources/MotasAppKit/SettingsView.swift` as a `TabView` with `.frame(width: 520, height: 440)`; each tab body is a `Form { … }.formStyle(.grouped)`.

- **General** (`gearshape`): `Toggle("Launch at login")`; `Toggle("Automatic refresh")` plus `Picker("Refresh every")` with tags `300/600/900/1800` labelled `"5 minutes"/"10 minutes"/"15 minutes"/"30 minutes"`, disabled when the toggle is off; `Toggle("Show percentage in menu bar")`; `Toggle("Tint menu bar icon when quota is low")`.
- **Sources** (`server.rack`): three `GroupBox`es — Claude Code, CLIProxyAPI, 9Router — each keeping the existing controls and secret-source labels from the current file, each gaining a `Button("Test")` that runs `model.testSettings` and shows that connector's `ConnectionTestResult` inline as `Label(status, systemImage:)` tinted by status. Below them: `Toggle("Fetch account quota from proxies")` bound to `quotaProbeEnabled`, `Picker("Quota refresh every")` with tags `600/1200/1800/3600`, and the footnote `"Quota probes ask the proxy to call the upstream provider. Motas never forces a refresh and never calls reset endpoints."`
- **Advanced** (`wrench.and.screwdriver`): the existing diagnostics buttons (`Copy report`, `Save JSON…`), the reset alert, and the demo scenario `Picker` shown only when `model.isDemoMode`.

Launch at login is applied in `AppModel`, not the view:

```swift
func setLaunchAtLogin(_ enabled: Bool) -> String?   // nil on success, message on failure
```
using `SMAppService.mainApp.register()` / `.unregister()` (`import ServiceManagement`). Running from `swift run` throws; catch and return `"Launch at login is only available for the installed Motas.app."`, and surface it under the toggle. Persist the requested value either way.

### Step 10 — Visual proof harness and app icon

A menu bar app cannot be screenshotted headlessly, so add a real render target rather than shipping unverified UI.

`Package.swift`: add `.executable(name: "MotasGallery", targets: ["MotasGallery"])` and `.executableTarget(name: "MotasGallery", dependencies: ["MotasCore", "MotasAppKit"], path: "Sources/MotasGallery")`. `MotasAppKit` is already an importable library target from Step 1.

`Sources/MotasGallery/main.swift`:

- `swift run MotasGallery <outputDir>` writes, for each of `MockData.readySnapshot/cautionSnapshot/fallbackSnapshot/proxyDownSnapshot/unknownSnapshot` plus one synthetic snapshot carrying proxy account quota windows, two PNGs — `<name>-light.png` and `<name>-dark.png` — of `PanelView` fed by an `AppModel` seeded with that snapshot, rendered through `ImageRenderer` at `scale = 2` with `.environment(\.colorScheme, …)` and a backdrop of `Color(white: 0.96)` / `Color(white: 0.13)` (materials do not rasterize). It also writes `menubar-<state>-<light|dark>.png` for the four menu bar variants.
- `swift run MotasGallery --icon <path.png>` writes a 1024×1024 icon: the `QuotaRing` mark at 0.72 in white on a `LinearGradient` from `#2B7CFF` to `#0A4CD1`, corner-rounded to the macOS icon squircle by drawing into a `RoundedRectangle(cornerRadius: 224, style: .continuous)`.

`scripts/make-icon.sh`: runs `--icon`, then `sips -z N N` into `dist/AppIcon.iconset/icon_{16,32,128,256,512}x{,@2x}.png`, then `iconutil -c icns dist/AppIcon.iconset -o dist/AppIcon.icns`. Both tools are at `/usr/bin` and need no Xcode.

`AppModel` needs a seedable path for the gallery: add `public init(previewSnapshot: StatusSnapshot, demoMode: Bool = false)` that assigns `snapshot`, `settings = .default()` and empty source labels, and skips settings loading, history loading, connector building, snapshot persistence and scheduling entirely. The gallery is a real render harness, not scaffolding — it stays in the repo and runs in CI.

### Step 11 — Packaging, CI and the cask

`scripts/build-app.sh` (bash, `set -euo pipefail`, `VERSION="${1:-0.0.0-dev}"`):

1. `swift build -c release --arch arm64 --arch x86_64 --product Motas`
2. `rm -rf dist/Motas.app`; create `dist/Motas.app/Contents/{MacOS,Resources}`
3. copy `.build/apple/Products/Release/Motas` → `Contents/MacOS/Motas`
4. write `Contents/Info.plist` with `CFBundleIdentifier=dev.motas.app`, `CFBundleName=Motas`, `CFBundleExecutable=Motas`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString=$VERSION`, `CFBundleVersion=$VERSION`, `CFBundleIconFile=AppIcon`, `LSMinimumSystemVersion=14.0`, `LSUIElement=true`, `NSHumanReadableCopyright=Copyright © 2026 dinhkarate. MIT licensed.`; validate with `plutil -lint`
5. `scripts/make-icon.sh` if `dist/AppIcon.icns` is missing; copy it into `Contents/Resources`
6. `codesign --force --options runtime --timestamp=none --sign - dist/Motas.app` and verify with `codesign --verify --strict`

Fallback if the universal build fails under Command Line Tools: drop to `swift build -c release --product Motas` (host arch only, output `.build/release/Motas`) and note the limitation in the release body. Do not silently ship a single-arch binary as universal.

`scripts/make-release.sh <version>`: runs `build-app.sh`, `ditto -c -k --keepParent dist/Motas.app dist/Motas-<version>.zip`, `shasum -a 256`, and rewrites `packaging/homebrew/motas.rb` with the new version and digest.

`packaging/homebrew/motas.rb`:

```ruby
cask "motas" do
  version "0.1.0"
  sha256 "REPLACED_BY_make-release.sh"
  url "https://github.com/dinhkarate/Motas/releases/download/v#{version}/Motas-#{version}.zip"
  name "Motas"
  desc "Menu bar AI quota monitor for CLIProxyAPI, 9Router and Claude Code"
  homepage "https://github.com/dinhkarate/Motas"
  depends_on macos: ">= :sonoma"
  app "Motas.app"
  zap trash: [
    "~/Library/Application Support/Motas",
    "~/Library/Preferences/dev.motas.app.plist",
  ]
  caveats <<~EOS
    Motas is ad-hoc signed, not notarized. Install with:
      brew install --cask --no-quarantine dinhkarate/motas/motas
  EOS
end
```

`.github/workflows/ci.yml` — `on: [push, pull_request]`, `runs-on: macos-15`, `maxim-lobanov/setup-xcode@v1` with `xcode-version: '16.2'` (Swift 6 toolchain; the `macos-14` runner only ships Swift 5.10 and cannot build `swift-tools-version:6.0`), then `swift build`, `swift test`, `scripts/build-app.sh`, `swift run MotasGallery gallery`, and upload `gallery/` as an artifact.

`.github/workflows/release.yml` — `on: push: tags: ['v*']`, same runner setup, then `scripts/make-release.sh ${GITHUB_REF_NAME#v}`, `gh release create` with the zip, the `.sha256` and `packaging/homebrew/motas.rb` attached. A final step guarded by `if: secrets.HOMEBREW_TAP_TOKEN != ''` clones `dinhkarate/homebrew-motas`, copies the cask to `Casks/motas.rb`, and pushes; when the secret is absent the cask stays a release asset and the release notes tell the maintainer to copy it manually.

### Step 12 — GOAL.md and the documents that now contradict it

Create `GOAL.md` at repo root — this is the `/goal` artifact and the file every future contributor and agent reads first:

- **Mission**: one paragraph — a native macOS menu bar app that answers "can I start a long coding session right now?" by reading quota from *your own proxy stack*, not from official provider dashboards.
- **Why proxies**: CLIProxyAPI and 9Router already hold the OAuth credentials and already query provider quota endpoints; Motas reuses that work instead of asking the user for provider credentials.
- **Non-negotiables**: macOS only; read-only against every proxy (no reset, switch, start or stop endpoints, ever); credentials only in Keychain; never invent a percentage, a reset time or a green state (points at `docs/architecture/status-presentation.md` and `readiness-rules.md`); MIT; distributed through Homebrew.
- **Shipped surface**: menu bar ring + panel + settings; connectors Claude Code, CLIProxyAPI, 9Router.
- **Deliberately not now**, one line each: WidgetKit widget (needs full Xcode), notarization (needs a Developer ID), notification delivery (`ReadinessNotificationEngine` exists but has no `UNUserNotificationCenter` adapter), Windows/Linux, any paid tier.

Rewrite `docs/product/v1-scope.md`: strike "Direct signed/notarized DMG", "Sparkle update channel", "15-day trial and one-time license for paid v1", "Medium and large WidgetKit desktop widgets" and "Shared non-secret snapshot through an App Group"; replace the distribution block with the ad-hoc cask reality; add proxy-sourced quota to the must-ship list.

Rewrite `README.md`: what Motas is, a screenshot from the gallery, `brew install --cask --no-quarantine dinhkarate/motas/motas`, build-from-source (`swift build`, `swift test`, `swift run Motas`, `scripts/build-app.sh`), connector setup for all three sources, the privacy boundary, and MIT.

Append a "Quota" section to `docs/connectors/cliproxyapi.md` (`POST /v0/management/quota/fetch`, the `groups[].buckets[]` shape, 501 = unsupported, pool aggregation, the no-mutation rule) and to `docs/connectors/9router.md` (`GET /api/usage/{connectionId}`, the `quotas` map, the standing prohibition on `?force=1`).

`scripts/motas_board.py` and `scripts/motas-board` are unrelated GitHub-project tooling; leave them alone.

---

## Critical files & anchors

| File | Anchor | Why |
|---|---|---|
| `Sources/MotasAppKit/MotasApp.swift` | `AppModel.refresh()` ~L90-124 (coalescer), `persistSnapshot()` ~L372, `rebuildConnectors()` | Every wiring change lands here; the `RefreshCoalescer.shouldApplyResult(capturedAt:)` guard must keep working when `refresh` gains a trigger |
| `Sources/MotasCore/Connectors/CLIProxyAPIConnector.swift` | `loadManagementDetails(checkedAt:modelCount:)` L132-197, `managementRequest(path:)` L210 | Quota probing hangs off the existing auth-files walk; `managementRequest` is GET-only today and needs a POST sibling |
| `Sources/MotasCore/Connectors/NineRouterConnector.swift` | `loadProtectedDetails(checkedAt:)` L105-167, `request(path:protected:)` L173 | Same, and `request` already encodes the two protected-auth header variants |
| `Sources/MotasCore/Readiness/ReadinessEngine.swift` | `ReadinessPolicy` thresholds `0.20` / `0.05` | Unchanged, but the panel's caution/critical colours must use the same numbers via `MotasTheme` |
| `Sources/MotasCore/Presentation/StatusPresentation.swift` | `relativeAge`, `resetLabel`, `remediation` | Reuse verbatim; `tightestWindow` is added beside them |

---

## Verification

Run from the repo root. Prerequisite: Swift 6.0.3 CLT (already present).

1. **Unit suite.** `swift test` — the 98 existing tests plus the new settings-migration, aggregation, `tightestWindow`, CPA-quota and 9Router-quota tests all pass. Specific new-behaviour assertion: CPA `groups[0].buckets[0].remainingFraction == 0.34` produces a `QuotaWindow` named `"Claude · 5-hour"` with `remainingFraction == 0.34`, and a second `.manual` refresh after a `501` issues no further `quota/fetch` request.

2. **End-to-end against a fake proxy.** Add `scripts/fake-cpa.py` — a stdlib `http.server` that serves `GET /v1/models` → `{"data":[{"id":"gpt-5.5"},{"id":"claude-opus-4-6"}]}`, `GET /v0/management/auth-files` → two files with `auth_index` `a1`/`a2`, and `POST /v0/management/quota/fetch` → `a1` at `0.62` on `"Claude · 5-hour"` and `a2` at `0.11`. Then:

   ```bash
   python3 scripts/fake-cpa.py 8317 &
   MOTAS_CLIPROXYAPI_URL=http://127.0.0.1:8317 \
   MOTAS_CLIPROXYAPI_MANAGEMENT_KEY=test \
   swift run Motas &
   sleep 8
   python3 -m json.tool "$HOME/Library/Application Support/Motas/motas-status-snapshot.json"
   ```
   Expected: the persisted snapshot contains a `cliproxyapi` proxy whose `quotaWindows` holds one entry with `remainingFraction: 0.62` (pool best, not `0.11`) and whose two accounts carry `0.62` and `0.11`. Kill both processes afterwards.

3. **Visual proof.** `swift run MotasGallery /tmp/motas-gallery` then inspect every PNG. Accept only when: the ready panel shows a green ring with a centred percentage and no clipped text at 340pt; the caution panel's ring, the matching quota bar and the menu bar icon are all orange; the dark variants have legible tile borders; the proxy tile shows route bars above a collapsed `Accounts` disclosure; and the empty-state tile shows the `Open Settings` button.

4. **Bundle and launch.** `scripts/build-app.sh 0.1.0 && codesign --verify --strict --verbose=2 dist/Motas.app && open dist/Motas.app` — the ring appears in the menu bar with no Dock icon, clicking it opens the panel, `Cmd-,` opens Settings, and the power button quits the process (`pgrep -x Motas` returns nothing afterwards).

5. **Cask sanity.** `brew audit --cask --new packaging/homebrew/motas.rb` reports no errors other than the expected "not notarized" style notes, and `shasum -a 256 dist/Motas-0.1.0.zip` matches the `sha256` written into the cask.

6. **Live proxies, when available.** No CLIProxyAPI (`8317`) or 9Router (`20128`) is listening on this machine right now, so this is opportunistic: start either one, enable it in Settings with its management key, press Refresh, and confirm real percentages appear. If the response shape differs from the fixtures, fix the decoder and add the observed payload as a new fixture — do not loosen the decoder into accepting unknown shapes silently.

---

## Assumptions & contingencies

- **Tap repository.** `dinhkarate/homebrew-motas` is assumed to be creatable by the user. If it does not exist when the release workflow runs, the cask-push step is skipped by its `if:` guard and the cask ships as a release asset; nothing fails.
- **Universal binary.** Assumed buildable with `--arch arm64 --arch x86_64` under Command Line Tools. If the x86_64 slice fails to link, build host-arch only and state "Apple Silicon only" in the release notes and the cask `desc`; do not block the release.
- **9Router API drift.** 9Router is a fast-moving Next.js app with no stable external monitoring contract. `GET /api/usage/{connectionId}` is assumed to keep returning `{plan, quotas: {name: {remainingPercentage, resetAt, unlimited}}}`. If the shape changes, the connector must degrade to `quality: .partial` with the accounts still listed — never to a red or fabricated state.
- **CPA quota support is per-credential.** Accounts whose provider plugin has no quota provider return `501`; those accounts legitimately show no bars. If *every* account returns `501`, the tile shows account health only and the subtitle reads `"Quota not exposed by this proxy build."`
- **Notarization later.** If a Developer ID becomes available, the only changes are the `codesign --sign` identity, a `notarytool submit --wait` + `stapler staple` step in `release.yml`, and removing the cask `caveats`; nothing in the app changes.
