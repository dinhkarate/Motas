# Legacy 0.2 files

Files exactly as Motas 0.2 writes them, used to test that v0.3 still loads
them. They were produced on 2026-11-03 by encoding representative values with
the 0.2 code (commit `57f8ce4`) before the v0.3 model changes:
`SharedSnapshot.save` (`snapshot.json`), `SettingsStore.save`
(`settings.json`) and `HistoryStore.record` (`history.json`). All values are
made up; emails use `example.com`.

| File | Covers |
|---|---|
| `snapshot_v0.2.json` | account state `error` with a `stateMessage`; `windows`, `unavailable` and `failed` readings; proxy health `ok`, `unauthorized`, `unreachable`, `needsKeychainAccess` and `failed` |
| `settings_v0.2.json` | one 9Router and one CLIProxyAPI proxy, no `auth` key |
| `history_v0.2.json` | provider-keyed `PoolSample`s |
