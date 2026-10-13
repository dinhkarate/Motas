# Settings, Keychain and automatic refresh

## Configuration boundary

Motas stores only non-secret connector configuration in:

```text
~/Library/Application Support/Motas/settings.json
```

The document is atomic, schema-versioned and contains only:

- enabled flags;
- endpoint URLs;
- Claude Code's status-cache path;
- automatic-refresh preference.

It never contains API keys, dashboard tokens, CLI tokens, cookies or authorization headers. The WidgetKit extension continues to receive only the normalized `StatusSnapshot` through the App Group.

## Secret boundary

9Router and CLIProxyAPI credentials use generic-password Keychain entries:

```text
service: dev.motas.app.connectors
accounts:
- 9router.dashboard-token
- 9router.cli-token
- cliproxyapi.proxy-api-key
- cliproxyapi.management-key
```

Entries are device-only and available after first unlock. Read checks disable user interaction so automatic refresh cannot trigger a Keychain prompt. Claude Code has no Motas-stored credential: its connector reads only the sanitized local status-line cache.

## Configuration precedence

For the current process:

```text
environment value > saved Settings / Keychain value > built-in default
```

Environment values are development overrides. They are never copied into `settings.json` or Keychain.

Invalid environment URLs are ignored with a sanitized configuration warning; saved settings remain available. Connector URLs must be absolute HTTP(S) endpoints and cannot include embedded credentials, query strings, fragments or unsupported paths.

## Save semantics

The Settings UI keeps `SecureField` input only in transient view state:

- an empty secret field means **keep the current Keychain value**;
- a non-empty field replaces the corresponding Keychain value;
- deletion is staged and only applied by **Save Settings**;
- saved values are never copied back into a visible field.

Keychain and filesystem writes cannot form one atomic transaction. If Keychain succeeds but settings JSON fails, Motas keeps the prior in-memory settings and shows a partial-save error. The user must retry Save or restore the prior credential.

## Refresh lifecycle

Motas performs an immediate refresh when effective connectors are available, then refreshes every five minutes while the app runs and automatic refresh is enabled.

Manual refresh, initial refresh, scheduled refresh and post-save refresh all use one coalescing pipeline:

1. One connector batch runs at a time.
2. Concurrent requests mark one pending follow-up batch.
3. A settings change increments a configuration revision.
4. Results from an older revision are discarded rather than replacing newer endpoint or credential state.
5. The scheduler sleeps before each interval and never replays missed ticks after sleep/wake.

The fixed five-minute policy supersedes the earlier one-minute adaptive-refresh suggestion in this prototype. Widget timeline reload behavior remains deferred until the full Xcode/WidgetKit build can be validated.

## Verification scope

Apple Command Line Tools verify Swift package tests, strict-concurrency build and the menu-bar executable. Full Keychain persistence behavior, signing and WidgetKit/App Group integration require a full Xcode installation and a signed macOS application build.
