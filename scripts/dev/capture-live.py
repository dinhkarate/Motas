#!/usr/bin/env python3
"""Capture raw responses from a live CLIProxyAPI + 9Router testbed.

Env: MOTAS_CPA_URL, MOTAS_9R_URL, and either MOTAS_TESTBED_SSH (host whose
~/motas-testbed/.env holds CPA_MGMT_KEY, CPA_CLIENT_KEY, NINE_PASSWORD) or
those three variables directly. Secrets are never printed. Raw output goes to
MOTAS_RAW_DIR (default ./raw) and may contain emails and ids — run
sanitize-fixtures.py before committing anything.
"""
import base64, json, os, subprocess, sys, urllib.request, urllib.error, http.cookiejar

OUT = os.environ.get("MOTAS_RAW_DIR", "raw")
os.makedirs(OUT, exist_ok=True)
if os.environ.get("MOTAS_TESTBED_SSH"):
    env = dict(l.split("=", 1) for l in subprocess.check_output(
        ["ssh", os.environ["MOTAS_TESTBED_SSH"], "cat ~/motas-testbed/.env"], text=True).split())
else:
    env = {k: os.environ[k] for k in ("CPA_MGMT_KEY", "CPA_CLIENT_KEY", "NINE_PASSWORD")}
CPA = os.environ["MOTAS_CPA_URL"].rstrip("/")
NR = os.environ["MOTAS_9R_URL"].rstrip("/")


def call(method, url, headers=None, body=None, opener=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, method=method, data=data, headers=headers or {})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with (opener or urllib.request.build_opener()).open(req, timeout=40) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def save(name, status, raw):
    with open(os.path.join(OUT, name + ".json"), "wb") as f:
        f.write(raw)
    try:
        j = json.loads(raw)
        shape = sorted(j.keys()) if isinstance(j, dict) else f"list[{len(j)}]"
    except Exception:
        shape = f"non-json {len(raw)}B"
    print(f"{name}: {status} {shape}")
    return json.loads(raw) if raw[:1] in (b"{", b"[") else None


def jwt_claims(tok):
    try:
        p = tok.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    except Exception:
        return {}


# ---------- CPA ----------
mg = {"Authorization": "Bearer " + env["CPA_MGMT_KEY"]}
save("cpa_v1_models", *call("GET", CPA + "/v1/models", {"Authorization": "Bearer " + env["CPA_CLIENT_KEY"]}))
files = save("cpa_auth_files", *call("GET", CPA + "/v0/management/auth-files", mg))["files"]
for f in files:
    idx, prov = f.get("auth_index"), f.get("provider") or f.get("type")
    save(f"cpa_quota_fetch_{prov}", *call("POST", CPA + "/v0/management/quota/fetch", mg, {"auth_index": idx}))
    if prov == "codex":
        acct = f.get("chatgpt_account_id") or f.get("account_id") or \
            jwt_claims(f.get("id_token", "")).get("https://api.openai.com/auth", {}).get("chatgpt_account_id")
        hdr = {"Authorization": "Bearer $TOKEN$", "User-Agent": "codex-cli"}
        if acct:
            hdr["Chatgpt-Account-Id"] = acct
        print("  codex account id resolved:", bool(acct))
        save("cpa_apicall_codex_usage", *call("POST", CPA + "/v0/management/api-call", mg, {
            "auth_index": idx, "method": "GET", "url": "https://chatgpt.com/backend-api/wham/usage", "header": hdr}))
    if prov == "antigravity":
        body = json.dumps({"project": f.get("project_id", "")})
        hdr = {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json",
               "User-Agent": "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)"}
        for i, u in enumerate(["https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
                               "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
                               "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"]):
            save(f"cpa_apicall_antigravity_{i}", *call("POST", CPA + "/v0/management/api-call", mg, {
                "auth_index": idx, "method": "POST", "url": u, "header": hdr, "data": body}))

# ---------- 9Router ----------
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
save("9r_login", *call("POST", NR + "/api/auth/login", body={"password": env["NINE_PASSWORD"]}, opener=op))
print("  cookies:", [c.name for c in jar])
save("9r_unauth_providers", *call("GET", NR + "/api/providers"))
conns = save("9r_providers", *call("GET", NR + "/api/providers", opener=op)).get("connections", [])
for c in conns:
    save(f"9r_usage_{c.get('provider')}", *call("GET", NR + f"/api/usage/{c['id']}", opener=op))
save("9r_health", *call("GET", NR + "/api/health"))
save("9r_version", *call("GET", NR + "/api/version"))
