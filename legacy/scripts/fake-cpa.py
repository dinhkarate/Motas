#!/usr/bin/env python3
"""Fake CLIProxyAPI for Motas end-to-end verification (stdlib only).

Serves:
  GET  /v1/models                -> two discoverable models
  GET  /v0/management/auth-files -> two files with auth_index a1/a2
  POST /v0/management/quota/fetch -> a1 at 0.62, a2 at 0.11 on "Claude" / "5-hour"

Usage: python3 scripts/fake-cpa.py 8317
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

QUOTA = {
    "a1": 0.62,
    "a2": 0.11,
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/v1/models":
            self._send({"data": [{"id": "gpt-5.5"}, {"id": "claude-opus-4-6"}]})
        elif self.path == "/v0/management/auth-files":
            self._send({
                "files": [
                    {"auth_index": "a1", "name": "a1.json", "provider": "claude",
                     "email": "work@example.com", "status": "active"},
                    {"auth_index": "a2", "name": "a2.json", "provider": "claude",
                     "email": "personal@example.com", "status": "active"},
                ]
            })
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        if self.path != "/v0/management/quota/fetch":
            self._send({"error": "not found"}, 404)
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            body = {}
        fraction = QUOTA.get(body.get("auth_index"))
        if fraction is None:
            self._send({"error": "no quota provider available for credential"}, 501)
            return
        self._send({
            "subscription": {"plan": "Pro"},
            "groups": [{
                "displayName": "Claude",
                "buckets": [{
                    "window": "5-hour",
                    "remainingFraction": fraction,
                    "resetTime": "2026-09-14T12:00:00Z",
                }],
            }],
        })


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8317
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
