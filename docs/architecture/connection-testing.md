# Guided setup and read-only connection testing

Settings now includes a minimal first-run guide and a **Test enabled connectors** action.

## Safety boundary

The test runner:

- builds immutable connector configurations from the current draft;
- uses transient secret values only;
- performs the existing read-only connector refresh calls;
- returns normalized health/quality/message summaries;
- does not save Settings or Keychain values;
- does not mutate proxies, accounts or provider sessions.

The user must explicitly press **Save Settings** to persist endpoint/toggle changes or credential updates.

## Result mapping

```text
healthy      connector returned healthy data
degraded     connector responded but has degraded/exhausted detail
unauthorized monitoring credential was rejected
unreachable  endpoint could not be reached
unsupported  connector setup/data source is unavailable
unknown      result could not be classified safely
```

Raw response bodies and secrets are never part of `ConnectionTestResult`.

## First-run behavior

When no persisted connectors exist, Motas labels the current view as demo mode and shows setup instructions. Demo mode does not run connection tests or notifications against mock scenario changes. Enabling a real connector and saving exits demo mode.
