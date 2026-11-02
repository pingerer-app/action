#!/usr/bin/env python3
"""A tiny stand-in for Pingerer's API, for testing `pingerer github-action` without a
server: python3 fake_api.py PORT. Sites yourbakery.com (site_1, with an
http and an ssl monitor) and shop.yourbakery.com (site_2, whose http
monitor mon_3 fails its first two test runs). Every request is logged to
stderr as "METHOD PATH BODY"."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = "test-token"
SITES = {
    "site_1": {"id": "site_1", "host": "yourbakery.com", "status": "up", "paused": False},
    "site_2": {"id": "site_2", "host": "shop.yourbakery.com", "status": "down", "paused": False},
}
MONITORS = {
    "mon_1": {"id": "mon_1", "site_id": "site_1", "kind": "http", "name": "Uptime", "status": "up", "paused": False},
    "mon_2": {"id": "mon_2", "site_id": "site_1", "kind": "ssl", "name": "SSL certificate", "status": "up", "paused": False},
    "mon_3": {"id": "mon_3", "site_id": "site_2", "kind": "http", "name": "Uptime", "status": "down", "paused": False},
}
WINDOWS = {}
STATE = {"mon_3_tests": 0, "rate_limited": False}


def find_site(key):
    return SITES.get(key) or next((s for s in SITES.values() if s["host"] == key), None)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        # This server closes every connection (HTTP/1.0); saying so stops the
        # client reusing one that's already closed.
        self.send_header("Connection", "close")
        if status == 429:
            self.send_header("Retry-After", "0")
        self.end_headers()
        self.wfile.write(data)

    def not_found(self):
        self.reply(404, {"error": "not_found", "message": "That record wasn't found."})

    def handle_any(self, method):
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        body = json.loads(raw) if raw else {}
        sys.stderr.write(f"{method} {self.path} {raw}\n")
        sys.stderr.flush()

        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.reply(401, {"error": "unauthorized", "message": "Bad token"})
        parts = url.path.strip("/").split("/")[2:]  # after api/v1
        query = parse_qs(url.query)

        if parts[0] == "sites" and len(parts) == 3 and method == "POST":
            site = find_site(parts[1])
            if not site:
                return self.not_found()
            if not STATE["rate_limited"]:
                STATE["rate_limited"] = True
                return self.reply(429, {"error": "rate_limited", "message": "Too many requests."})
            site["paused"] = parts[2] == "pause"
            site["status"] = "paused" if site["paused"] else "pending"
            return self.reply(200, {"data": site})
        if parts[0] == "monitors" and len(parts) == 1 and method == "GET":
            site = find_site(query.get("site_id", [""])[0])
            if not site:
                return self.not_found()
            return self.reply(200, {"data": [m for m in MONITORS.values() if m["site_id"] == site["id"]], "meta": {}})
        if parts[0] == "monitors" and len(parts) == 3 and method == "POST":
            monitor = MONITORS.get(parts[1])
            if not monitor:
                return self.not_found()
            if parts[2] in ("pause", "resume"):
                monitor["paused"] = parts[2] == "pause"
                monitor["status"] = "paused" if monitor["paused"] else "pending"
                return self.reply(200, {"data": monitor})
            if parts[2] == "test":
                ok = True
                if monitor["id"] == "mon_3":
                    STATE["mon_3_tests"] += 1
                    ok = STATE["mon_3_tests"] > 2
                result = {"ok": ok, "status_code": 200 if ok else 502, "latency_ms": 120, "error": None if ok else "502 Bad Gateway",
                          "region": body.get("region", "fsn")}
                return self.reply(200, {"data": result})
        if parts[0] == "maintenance_windows":
            if len(parts) == 1 and method == "POST":
                sites = [find_site(s) for s in body.get("sites", [])]
                if None in sites or not body.get("duration"):
                    return self.reply(422, {"error": "validation_failed", "message": "Sites can't be blank"})
                window = {"id": f"mw_{len(WINDOWS) + 1}", "title": body.get("title"), "state": "in_progress", "all_sites": False,
                          "sites": [{"id": s["id"], "host": s["host"]} for s in sites], "ends_at": "2030-01-01T00:15:00Z",
                          "message": body.get("message"), "notify_subscribers_before": body.get("notify_subscribers_before")}
                WINDOWS[window["id"]] = window
                return self.reply(201, {"data": window})
            if len(parts) == 1 and method == "GET":
                return self.reply(200, {"data": [w for w in WINDOWS.values() if w["state"] != "done"], "meta": {}})
            if len(parts) == 3 and parts[2] == "end" and method == "POST":
                window = WINDOWS.get(parts[1])
                if not window:
                    return self.not_found()
                window["state"] = "done"
                return self.reply(200, {"data": window})
        return self.not_found()

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
