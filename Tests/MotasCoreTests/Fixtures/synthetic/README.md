# Synthetic 9Router fixtures

Bodies that 9Router v0.5.104 can return but that were not observed in the
2026-11-02 production capture (`../live/9r_prod_*.json`). Each string is
copied from the 9Router source (`open-sse/services/usage/*.js`, the compiled
`app/api/usage/[connectionId]` route and `middleware.js`), not invented.

| File | HTTP status | Source |
|---|---|---|
| `9r_usage_codex_upstream_{502,403,401}` | 200 | `usage/codex.js` — any non-OK upstream status |
| `9r_usage_antigravity_auth_expired` / `_forbidden` | 200 | `usage/google.js` — quota API 401 / 403 |
| `9r_usage_antigravity_api_500` | 200 | `usage/google.js` — other upstream errors, timeouts |
| `9r_usage_antigravity_empty_quotas` | 200 | free tier whose best-effort weekly fetch failed |
| `9r_usage_gemini_cli_quota_{403,429}` | 200 | `usage/google.js` — any status |
| `9r_usage_qoder_unable` | 200 | `usage/misc.js` — network error |
| `9r_usage_claude_admin` | 200 | `usage/claude.js` — by design, no figures |
| `9r_usage_claude` | 200 | `usage/claude.js` key names (`session (5h)`, `weekly (7d)`, `weekly <model> (7d)`) |
| `9r_usage_route_500` | 500 | usage route — handler threw |
| `9r_usage_not_found` | 404 | usage route — connection id unknown |
| `9r_usage_session_unauthorized` | 401 | middleware — cookie / CLI token missing or invalid (Motas's own session, never an account verdict) |
| `9r_login_password_disabled` | 403 | `POST /api/auth/login` with OIDC-only login |
