# ADR-001: Motas macOS Surface Architecture

- Status: Accepted
- Date: 2026-07-23
- Decision owners: Product and engineering
- Roadmap task: `P0.5`

## Context

Motas must keep AI quota and proxy/router health visible without forcing users to open multiple dashboards. The product needs two native macOS surfaces:

1. A live, interactive surface for current data and connector actions.
2. A desktop surface that remains glanceable when the app is not frontmost.

The main options were:

- WidgetKit only.
- A floating always-on-top desktop panel.
- Menu bar only.
- A hybrid menu bar application plus WidgetKit extension.

## Decision

Motas v1 will use a **native hybrid architecture**:

```text
Motas macOS application
├── MenuBarExtra (.window)      live and interactive
├── Settings window             connector configuration
├── Background refresh service  provider/proxy polling
├── Shared normalized snapshot  App Group container
└── WidgetKit extension         desktop glance surface
```

The product will target **macOS 14 Sonoma or later** initially.

### Primary surface: menu bar

Use SwiftUI `MenuBarExtra` with `.window` style.

It is responsible for:

- Current global readiness.
- Provider and proxy/router detail rows.
- Manual refresh.
- Error and stale-data explanation.
- Opening Settings and detailed views.
- Running interactive operations that need the containing app.

The menu bar is the authoritative live UI because the app controls its refresh lifecycle.

### Secondary surface: WidgetKit desktop widget

Use a native WidgetKit extension with at least:

- Medium widget: global readiness plus the most important sources.
- Large widget: readiness, quota windows, reset times, proxy health and freshness.

The widget is responsible for glanceable status, not real-time monitoring. It reads the latest normalized snapshot written by the containing app.

### Deferred surface: floating panel

A custom always-on-top or desktop-level floating panel is not part of v1.

It may be reconsidered after beta if users need:

- Higher refresh frequency while the desktop is visible.
- Free positioning or custom sizing.
- Richer interaction than WidgetKit supports.

Deferring it avoids window-level edge cases, Space/full-screen behavior, accidental obstruction and another surface to maintain.

## Data and update flow

```text
Connector credentials (Keychain, app only)
             │
             ▼
Background refresh service
             │
             ▼
Normalized ProviderStatus / ProxyStatus
             │
             ├──► MenuBarExtra live state
             │
             └──► Atomic snapshot in App Group
                            │
                            ▼
                  WidgetKit timeline entry
```

Rules:

1. Connectors execute in the containing app, not in the widget extension.
2. The app writes a versioned, non-secret snapshot atomically to the shared App Group container.
3. After a meaningful state change, the app requests `WidgetCenter` to reload Motas timelines.
4. The widget provides timeline entries and marks data stale when its freshness threshold is exceeded.
5. Widget refresh frequency is best-effort and controlled by WidgetKit; the UI must never claim real-time accuracy.
6. Interactive widget actions use App Intents only for safe actions such as requesting refresh or opening a specific app scene.

## Security boundary

- API keys, management keys, OAuth/session material and cookies stay in macOS Keychain.
- The WidgetKit extension does not receive credentials.
- The App Group snapshot contains only normalized display data.
- Endpoint URLs may be omitted or redacted from the widget snapshot.
- Errors and logs must be sanitized before entering shared storage.
- Connector access is read-only wherever upstream systems permit it.

## Snapshot requirements

The shared snapshot must contain enough information to render without networking:

```text
schemaVersion
capturedAt
globalReadiness
globalExplanation
source summaries
quota windows
reset times
proxy health
active fallback tier, when known
data freshness and partial-data flags
```

It must not contain:

```text
API keys
management keys
cookies
OAuth tokens
raw authorization headers
unredacted error payloads
```

## Interaction model

### Menu bar

Supported:

- Refresh now.
- Open connector details.
- Open Settings.
- Enable or disable notifications.
- Diagnose connector errors.

### Widget

Supported in v1:

- Open Motas to the relevant source.
- Request a safe refresh through App Intent if practical.
- Select the displayed source through widget configuration if needed.

Not supported in v1:

- Credential entry.
- Scrolling lists.
- Editing endpoints.
- Destructive proxy/router control.
- Claims of second-by-second status.

## Distribution implications

### Direct and Homebrew distribution

The containing app can use local-network access, configuration discovery and read-only local data access permitted by macOS and user consent.

### Mac App Store

App Store distribution remains optional. Before submission, Motas must separately test:

- App Sandbox restrictions.
- Local-network connector access.
- Reading CLI/config locations.
- Credential and App Group entitlements.

No architecture decision assumes that all direct-distribution connectors will work unchanged in the sandboxed edition.

## Alternatives considered

### WidgetKit only

Rejected because WidgetKit uses system-managed timelines and is unsuitable as the sole live monitoring surface. Setup, diagnostics and manual refresh also need an app UI.

### Floating panel first

Rejected for v1 because it adds positioning, focus, Spaces, full-screen and window-level complexity while being less conventional than a native desktop widget.

### Menu bar only

Rejected because Motas explicitly differentiates through an always-visible desktop widget and users may have crowded menu bars.

## Consequences

Positive:

- Native macOS experience.
- Clear live-versus-glance responsibilities.
- Widget never holds secrets.
- Compatible with direct/Homebrew-first distribution.
- Shared UI components and normalized models can serve both surfaces.

Tradeoffs:

- A WidgetKit extension and App Group add project complexity.
- Widget data may be older than menu bar data.
- The product must communicate freshness honestly.
- App Store compatibility still requires a separate feasibility review.

## Verification plan

Phase 1 must prove:

1. `MenuBarExtra` renders mock readiness data.
2. The containing app writes an atomic shared snapshot.
3. A macOS desktop widget renders the same snapshot.
4. Dark and light appearances remain readable.
5. Killing network access produces an honest stale/unknown state.
6. No secret appears in the shared container.

## Sources

- Apple WidgetKit overview: https://developer.apple.com/documentation/widgetkit
- Creating a widget extension: https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension
- Keeping a widget up to date: https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- Adding interactivity: https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- SwiftUI MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra
