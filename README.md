# Motas

**Motas = Mac + Quota**

Motas is a native macOS AI quota and proxy-health utility. It combines a live menu bar surface with a desktop WidgetKit companion so users can see whether their AI coding stack is ready before starting a long session.

## Current prototype

Implemented:

- Normalized provider/proxy/quota models.
- Conservative readiness engine.
- Mock Claude Code data.
- Basic read-only 9Router health/account connector.
- Basic read-only CLIProxyAPI health/account connector.
- SwiftUI `MenuBarExtra` prototype.
- WidgetKit extension source using a shared snapshot.
- Atomic JSON snapshot persistence.
- Swift tests for readiness, connectors and snapshot privacy.

Planned connectors:

- Claude Code
- 9Router
- CLIProxyAPI
- OpenRouter (optional MVP)
- ProxyPal (post-MVP)

## Requirements

Core package and menu bar prototype:

```text
macOS 14+
Swift 6+
```

Full app + desktop widget project generation:

```text
Full Xcode installation
XcodeGen
Apple Development team for App Group signing
```

## Build and test the core prototype

```bash
swift test
swift build --product MotasPrototype
swift run MotasPrototype
```

`swift run MotasPrototype` launches the menu bar prototype. Open Settings to switch between mock readiness scenarios.

To monitor local proxies instead of mock data:

```bash
MOTAS_9ROUTER_URL=http://localhost:20128 \
MOTAS_CLIPROXYAPI_URL=http://localhost:8317 \
swift run MotasPrototype
```

Optional monitoring credentials:

```text
MOTAS_9ROUTER_DASHBOARD_TOKEN
MOTAS_9ROUTER_CLI_TOKEN
MOTAS_CLIPROXYAPI_KEY
MOTAS_CLIPROXYAPI_MANAGEMENT_KEY
```

Environment variables are a prototype-only configuration surface. Production credentials will move to Keychain-backed Settings.

## Generate the Xcode project

Install XcodeGen after full Xcode is installed:

```bash
brew install xcodegen
xcodegen generate
open Motas.xcodeproj
```

Before signing, set your Apple Development Team and register the App Group:

```text
group.dev.motas.app
```

The generated Xcode project is intentionally ignored because `project.yml` is the source of truth.

## Architecture

- [macOS surface architecture](docs/adr/001-macos-surface-architecture.md)
- [Normalized status model](docs/architecture/normalized-status-model.md)
- [Readiness rules](docs/architecture/readiness-rules.md)
- [9Router connector research](docs/connectors/9router.md)
- [CLIProxyAPI connector research](docs/connectors/cliproxyapi.md)
- [MVP user stories](docs/product/mvp-user-stories.md)
- [Frozen v1 scope](docs/product/v1-scope.md)

## Verification status

The current environment has Apple Command Line Tools and Swift 6, so the Swift package and menu bar executable are buildable/testable.

The WidgetKit target cannot be validated with `xcodebuild` until full Xcode is installed and selected with `xcode-select`.
