#!/usr/bin/env python3
"""Turn raw proxy captures into committable test fixtures.

Usage: sanitize-fixtures.py RAW_DIR OUT_DIR

Replaces emails, account/user/project ids, auth indexes and file paths with
stable fakes, drops upstream response headers, and trims bulky fields. Numbers,
timestamps, plan names and structure are kept exactly so parsers are tested
against real shapes. Fails if anything that looks like a token survives.
"""
import json, os, re, sys

raw_dir, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I)
fakes = {}


def fake(kind, value):
    key = (kind, value)
    if key not in fakes:
        n = sum(1 for k in fakes if k[0] == kind) + 1
        fakes[key] = {
            "email": f"account{n}@example.com",
            "uuid": f"00000000-0000-4000-8000-{n:012d}",
            "hex": f"{n:016x}",
            "project": f"sample-project-{n}",
            "user": f"user-sample{n}",
        }[kind]
    return fakes[key]


def scrub_str(key, s):
    s = EMAIL.sub(lambda m: fake("email", m.group(0)), s)
    s = UUID.sub(lambda m: fake("uuid", m.group(0)), s)
    if key in ("auth_index",):
        return fake("hex", s)
    if key in ("project_id", "projectId", "project"):
        return fake("project", s) if s else s
    if key in ("user_id",):
        return fake("user", s)
    if key in ("chatgpt_account_id", "chatgptAccountId", "account_id") and s:
        return fake("uuid", s)
    if key == "stringValue":
        return "<trimmed>"
    return s


def scrub(v, key=""):
    if isinstance(v, dict):
        return {k: scrub(x, k) for k, x in v.items()}
    if isinstance(v, list):
        return [scrub(x, key) for x in v]
    if isinstance(v, str):
        return scrub_str(key, v)
    return v


def process(name, doc):
    if isinstance(doc, dict) and {"status_code", "header", "body"} <= doc.keys():
        # CPA /api-call envelope: body is a JSON string. Keep envelope shape.
        body = doc["body"]
        try:
            inner = scrub(json.loads(body))
            if "models" in inner and isinstance(inner["models"], dict):
                inner["models"] = {k: inner["models"][k] for k in list(inner["models"])[:4]}
            body = json.dumps(inner, separators=(",", ":"))
        except (TypeError, ValueError):
            body = scrub_str("body", body)
        return {"status_code": doc["status_code"], "header": {"Content-Type": ["application/json"]}, "body": body}
    return scrub(doc)


TOKENISH = re.compile(r"(eyJ[A-Za-z0-9_-]{20,}|ya29\.|sk-[A-Za-z0-9]{20,}|1//0[A-Za-z0-9_-]{20,}|rt_[A-Za-z0-9]{20,})")
for fn in sorted(os.listdir(raw_dir)):
    if not fn.endswith(".json") or fn == "9r_login.json":
        continue
    doc = process(fn, json.load(open(os.path.join(raw_dir, fn))))
    text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
    if TOKENISH.search(text) or EMAIL.search(text.replace("@example.com", "")):
        sys.exit(f"refusing to write {fn}: token- or email-like content survived")
    with open(os.path.join(out_dir, fn), "w") as f:
        f.write(text)
    print("wrote", fn)
