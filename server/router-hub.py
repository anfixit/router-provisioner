#!/usr/bin/env python3
"""Router hub: takes metrics from routers, hands them tasks.

Routers sit behind NAT and cannot be reached. They already talk to Telegram,
but only through their own tunnel - so when the tunnel dies, the one channel
that could fix it dies with it. This server sits in the same country as the
routers, so they reach it directly, no tunnel involved. That is the whole point:
it works exactly when Telegram does not.

Two rules keep it small enough to trust:

  Only the actions below exist. A task is a word from a fixed list, never a
  command, so a leaked key cannot become a shell.

  The key is checked on every request, and a wrong key is answered with 404
  rather than 403 - there is no reason to confirm that this endpoint is real.
"""

import http.server
import json
import os
import re
import socketserver
import threading
import time
import urllib.parse

PORT = int(os.environ.get("HUB_PORT", "9095"))
KEY = os.environ.get("HUB_KEY", "")
STATE_DIR = os.environ.get("HUB_STATE", "/var/lib/router-hub")
ACTIONS = ("fix", "logs", "status", "none")
LABEL_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
METRIC_MAX = 256 * 1024
STALE_AFTER = 3600

os.makedirs(STATE_DIR, exist_ok=True)
# Re-entrant on purpose: the task handler reads and clears under one lock, and
# clearing takes the same lock again. A plain Lock deadlocks there, and the
# symptom is a router that polls forever and never gets its task.
_lock = threading.RLock()


def _path(kind, label):
    return os.path.join(STATE_DIR, f"{kind}-{label}")


def read_task(label):
    try:
        with open(_path("task", label), encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def write_task(label, action):
    with _lock:
        with open(_path("task", label), "w", encoding="utf-8") as handle:
            handle.write(action)


def store_metrics(label, body):
    with _lock:
        with open(_path("metrics", label), "w", encoding="utf-8") as handle:
            handle.write(body)


def all_metrics():
    """Everything the routers last said, plus how long ago they said it.

    A router that stops reporting is the failure this exists to catch, so the
    age is published as a metric of its own rather than left to be inferred
    from a missing series."""
    out = []
    now = time.time()
    for name in sorted(os.listdir(STATE_DIR)):
        if not name.startswith("metrics-"):
            continue
        label = name[len("metrics-"):]
        full = os.path.join(STATE_DIR, name)
        try:
            age = now - os.path.getmtime(full)
            with open(full, encoding="utf-8") as handle:
                body = handle.read()
        except OSError:
            continue
        out.append(f'router_report_age_seconds{{router="{label}"}} {age:.0f}')
        if age <= STALE_AFTER:
            out.append(body.rstrip())
    return "\n".join(out) + "\n"


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "router-hub"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body="", ctype="text/plain; charset=utf-8"):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _authorised(self, query):
        return bool(KEY) and query.get("key", [""])[0] == KEY

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        parts = [p for p in parsed.path.split("/") if p]

        # Prometheus scrapes this from the same host; no key, no secrets in it.
        if parts == ["metrics"]:
            self._send(200, all_metrics())
            return

        if not self._authorised(query):
            self._send(404, "not found\n")
            return

        # The router asking whether anything is waiting. Reading a task clears
        # it: a repair that ran must not run again on the next poll.
        if len(parts) == 2 and parts[0] == "task":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            with _lock:
                action = read_task(label)
                if action:
                    write_task(label, "")
            self._send(200, (action or "none") + "\n")
            return

        # The owner setting a task from a browser, from anywhere.
        if len(parts) == 3 and parts[0] == "set":
            label, action = parts[1], parts[2]
            if not LABEL_RE.match(label) or action not in ACTIONS:
                self._send(400, "bad request\n")
                return
            write_task(label, "" if action == "none" else action)
            self._send(200, f"{label}: {action}\n")
            return

        # A plain page listing what each router last said, for a quick look.
        if parts == ["status"]:
            now = time.time()
            rows = []
            for name in sorted(os.listdir(STATE_DIR)):
                if not name.startswith("metrics-"):
                    continue
                label = name[len("metrics-"):]
                age = now - os.path.getmtime(os.path.join(STATE_DIR, name))
                pending = read_task(label) or "-"
                rows.append(f"{label}: {age:.0f}s назад, задание: {pending}")
            self._send(200, "\n".join(rows) + "\n" if rows else "пусто\n")
            return

        self._send(404, "not found\n")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        parts = [p for p in parsed.path.split("/") if p]

        if not self._authorised(query):
            self._send(404, "not found\n")
            return

        if len(parts) == 2 and parts[0] == "metrics":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > METRIC_MAX:
                self._send(413, "too big\n")
                return
            store_metrics(label, self.rfile.read(length).decode("utf-8", "replace"))
            self._send(200, "ok\n")
            return

        self._send(404, "not found\n")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    if not KEY:
        raise SystemExit("HUB_KEY is not set; refusing to run without one")
    with Server(("0.0.0.0", PORT), Handler) as httpd:
        httpd.serve_forever()
