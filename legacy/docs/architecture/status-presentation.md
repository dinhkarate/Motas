# Truthful status presentation

The normalized model already contains quota reset times, observation quality and safe connector messages. The menu-bar surface now presents those values through pure Core helpers and app-side views.

## Display rules

- Snapshot age is shown as a relative “updated” value.
- `stale`, `partial` and `unavailable` quality remain visible even when a quota percentage exists.
- Enforced quota windows show remaining percentage and reset countdown when available.
- Past reset times are labeled as passed, never as a future countdown.
- Unauthorized, unreachable, unsupported, exhausted and stale states receive a concrete remediation hint.
- Connector messages are shown only as normalized, connector-authored safe text.

Widget source follows the same reset/stale rules, but WidgetKit/App Group compilation and visual validation remain deferred until full Xcode is selected.
