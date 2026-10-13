# Bounded local status history

Motas stores a bounded, normalized history at:

```text
~/Library/Application Support/Motas/history.json
```

The history is not an event log of raw provider responses. Each entry contains only:

- capture time;
- readiness state/title/source ID;
- provider health/quality/quota summaries;
- proxy health/quality/route/account-count summaries.

It never stores endpoints, emails, cookies, authorization headers, tokens, transcripts or raw observation messages.

## Retention

Default policy:

```text
maximum entries: 500
maximum age: 30 days
```

Entries are sorted chronologically and identical normalized state/source summaries are suppressed. A meaningful readiness/source/quota change creates a new entry.

## Failure behavior

History is auxiliary:

- a malformed or future history document produces a sanitized warning;
- the live snapshot remains available;
- history is rebuilt through future accepted refreshes;
- history write failure does not fail readiness evaluation.

The widget does not read history; it reads only the current App Group snapshot.
