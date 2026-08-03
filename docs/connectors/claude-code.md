# Claude Code connector

## Decision

Motas reads Claude Code subscription quota from the official status-line JSON contract instead of reading Claude credentials or calling an internal OAuth endpoint.

Claude Code exposes these optional fields to a configured status-line command:

```json
{
  "rate_limits": {
    "five_hour": {
      "used_percentage": 23.5,
      "resets_at": 1738425600
    },
    "seven_day": {
      "used_percentage": 41.2,
      "resets_at": 1738857600
    }
  }
}
```

Reference: [Claude Code status-line documentation](https://code.claude.com/docs/en/statusline).

## Privacy boundary

`scripts/motas-claude-statusline` receives the full status-line payload but persists only:

- capture timestamp;
- 5-hour used percentage and reset timestamp;
- 7-day used percentage and reset timestamp.

It does not read or persist Claude OAuth credentials, API keys, account identifiers, transcript paths, prompts, model output, working directories, session IDs or costs. The cache is written atomically with mode `0600`.

Default cache path:

```text
~/Library/Application Support/Motas/claude-code-status.json
```

## Setup

Make the capture script executable and use its absolute path in Claude Code's `statusLine` setting:

```bash
chmod +x scripts/motas-claude-statusline
```

Example `~/.claude/settings.json` entry:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/Motas/scripts/motas-claude-statusline"
  }
}
```

Then enable the connector when running the prototype:

```bash
MOTAS_CLAUDE_CODE_ENABLED=1 swift run MotasPrototype
```

Override the cache location for testing or non-default installations:

```bash
MOTAS_CLAUDE_CODE_ENABLED=1 \
MOTAS_CLAUDE_STATUS_FILE=/path/to/claude-code-status.json \
swift run MotasPrototype
```

Claude Code invokes the status-line command after conversation updates. Until a payload containing `rate_limits` is received, Motas reports the connector as unsupported/unavailable instead of guessing quota.

## Normalization

- `five_hour` becomes the enforced `5-hour` quota window.
- `seven_day` becomes the enforced `Weekly` quota window.
- `remainingFraction = 1 - used_percentage / 100`.
- Missing windows produce partial data; Motas never fabricates them.
- A cache older than 30 minutes is stale and cannot produce a ready state.
- An enforced window at 100% used maps provider health to exhausted.
- Malformed input is unavailable and raw file contents are never copied into the status snapshot.
