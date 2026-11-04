#!/usr/bin/env python3
"""Capture raw responses from a live CLIProxyAPI + 9Router testbed.

Env:
  MOTAS_CPA_URL, MOTAS_9R_URL
  CPA_MGMT_KEY, CPA_CLIENT_KEY
  NINE_ROUTER_CLI_TOKEN   preferred 9Router credential (x-9r-cli-token)
  NINE_PASSWORD           dashboard password, used when no CLI token
  MOTAS_TESTBED_SSH       optional host whose ~/motas-testbed/.env holds the
                          secrets; explicit environment variables win

Raw output goes to MOTAS_RAW_DIR (default ./raw) and may contain emails and
ids — run sanitize-fixtures.py before committing anything. Secrets are never
printed. Each call's status, size and duration is recorded in timings.jsonl.

The 9Router capture writes 9r_prod_providers.json and
9r_prod_usage_by_connection.json (connection id -> {status, body}), the two
files the offline pool tests serve through the real adapter.
"""
import base64
import http.cookiejar
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

OUT = os.environ.get("MOTAS_RAW_DIR", "raw")
os.makedirs(OUT, exist_ok=True)
TIMINGS = []


def load_env():
    """The environment, plus the testbed's .env when MOTAS_TESTBED_SSH is set."""
    values = {}
    host = os.environ.get("MOTAS_TESTBED_SSH")
    if host:
        raw = subprocess.check_output(["ssh", host, "cat ~/motas-testbed/.env"], text=True)
        for line in raw.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    return {**values, **os.environ}


def require(env, name):
    value = env.get(name)
    if not value:
        sys.exit(f"Missing {name} (set it in the environment or ~/motas-testbed/.env).")
    return value


def call(name, method, url, headers=None, body=None, opener=None):
    """One request; records status, bytes and milliseconds, never the secret."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, method=method, data=data, headers=headers or {})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    start = time.perf_counter()
    try:
        with (opener or urllib.request.build_opener()).open(req, timeout=40) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        status, raw = 0, json.dumps({"error": str(error)}).encode()
    ms = round((time.perf_counter() - start) * 1000)
    TIMINGS.append({"call": name, "status": status, "bytes": len(raw), "ms": ms})
    return status, raw


def save(name, status, raw):
    with open(os.path.join(OUT, name + ".json"), "wb") as file:
        file.write(raw)
    try:
        doc = json.loads(raw)
        shape = sorted(doc.keys()) if isinstance(doc, dict) else f"list[{len(doc)}]"
    except Exception:
        doc, shape = None, f"non-json {len(raw)}B"
    ms = TIMINGS[-1]["ms"] if TIMINGS else 0
    print(f"{name}: {status} {shape} ({ms} ms)")
    return doc


def save_json(name, value):
    with open(os.path.join(OUT, name + ".json"), "w") as file:
        json.dump(value, file, indent=2, sort_keys=True)
        file.write("\n")


def jwt_claims(token):
    try:
        payload = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except Exception:
        return {}


def capture_cpa(env):
    cpa = require(env, "MOTAS_CPA_URL").rstrip("/")
    management = {"Authorization": "Bearer " + require(env, "CPA_MGMT_KEY")}
    client = {"Authorization": "Bearer " + require(env, "CPA_CLIENT_KEY")}

    save("cpa_v1_models", *call("cpa_v1_models", "GET", cpa + "/v1/models", client))
    listing = save("cpa_auth_files", *call("cpa_auth_files", "GET", cpa + "/v0/management/auth-files", management))
    files = (listing or {}).get("files", [])
    for entry in files:
        auth_index = entry.get("auth_index")
        provider = entry.get("provider") or entry.get("type") or "unknown"
        save(f"cpa_quota_fetch_{provider}",
             *call(f"cpa_quota_fetch_{provider}", "POST", cpa + "/v0/management/quota/fetch",
                   management, {"auth_index": auth_index}))
        if provider == "codex":
            account_id = entry.get("chatgpt_account_id") or entry.get("account_id") or \
                jwt_claims(entry.get("id_token", "")).get("https://api.openai.com/auth", {}).get("chatgpt_account_id")
            header = {"Authorization": "Bearer $TOKEN$", "User-Agent": "codex-cli"}
            if account_id:
                header["Chatgpt-Account-Id"] = account_id
            print("  codex account id resolved:", bool(account_id))
            save("cpa_apicall_codex_usage",
                 *call("cpa_apicall_codex_usage", "POST", cpa + "/v0/management/api-call", management, {
                     "auth_index": auth_index, "method": "GET",
                     "url": "https://chatgpt.com/backend-api/wham/usage", "header": header}))
        elif provider == "antigravity":
            project = entry.get("project_id", "")
            body = json.dumps({"project": project})
            header = {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json",
                      "User-Agent": "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)"}
            for index, url in enumerate([
                "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
                "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
                "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
            ]):
                save(f"cpa_apicall_antigravity_{index}",
                     *call(f"cpa_apicall_antigravity_{index}", "POST", cpa + "/v0/management/api-call",
                           management, {"auth_index": auth_index, "method": "POST", "url": url,
                                        "header": header, "data": body}))
        elif provider == "claude":
            save("cpa_apicall_claude_usage",
                 *call("cpa_apicall_claude_usage", "POST", cpa + "/v0/management/api-call", management, {
                     "auth_index": auth_index, "method": "GET",
                     "url": "https://api.anthropic.com/api/oauth/usage",
                     "header": {"Authorization": "Bearer $TOKEN$",
                                "anthropic-beta": "oauth-2025-04-20",
                                "User-Agent": "claude-cli/2.1.280 (external, cli)"}}))


def capture_nine_router(env):
    nine = require(env, "MOTAS_9R_URL").rstrip("/")
    token = env.get("NINE_ROUTER_CLI_TOKEN")
    password = env.get("NINE_PASSWORD")
    opener = None
    headers = {}

    if token:
        headers = {"x-9r-cli-token": token}
        print("9Router: CLI token")
    elif password:
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        save("9r_login", *call("9r_login", "POST", nine + "/api/auth/login", body={"password": password}, opener=opener))
        print("9Router: dashboard password")
    else:
        sys.exit("Set NINE_ROUTER_CLI_TOKEN or NINE_PASSWORD (or MOTAS_TESTBED_SSH).")

    save("9r_unauth_providers", *call("9r_unauth_providers", "GET", nine + "/api/providers"))
    listing = save("9r_prod_providers", *call("9r_prod_providers", "GET", nine + "/api/providers", headers, opener=opener))
    connections = (listing or {}).get("connections", [])

    usage = {}
    for connection in connections:
        connection_id = connection.get("id")
        if not connection_id:
            continue
        provider = connection.get("provider") or "unknown"
        status, raw = call(f"9r_usage_{provider}", "GET", nine + f"/api/usage/{connection_id}", headers, opener=opener)
        try:
            body = json.loads(raw)
        except Exception:
            body = raw.decode(errors="replace")
        usage[connection_id] = {"status": status, "body": body}
        print(f"  usage {provider} {connection_id}: {status} {len(raw)}B")

    save_json("9r_prod_usage_by_connection", usage)
    save("9r_health", *call("9r_health", "GET", nine + "/api/health"))
    save("9r_version", *call("9r_version", "GET", nine + "/api/version"))


def write_timings():
    with open(os.path.join(OUT, "timings.jsonl"), "w") as file:
        for timing in TIMINGS:
            file.write(json.dumps(timing, sort_keys=True) + "\n")
    if TIMINGS:
        slowest = sorted(TIMINGS, key=lambda item: item["ms"], reverse=True)[:5]
        print("slowest:", ", ".join(f"{item['call']} {item['ms']} ms" for item in slowest))


def main():
    env = load_env()
    capture_cpa(env)
    capture_nine_router(env)


if __name__ == "__main__":
    try:
        main()
    finally:
        write_timings()
