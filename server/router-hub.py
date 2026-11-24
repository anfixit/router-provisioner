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

import getpass
import hashlib
import hmac
import http.cookies
import http.server
import ipaddress
import json
import os
import re
import secrets
import socketserver
import sys
import threading
import time
import unicodedata
import urllib.parse

PORT = int(os.environ.get("HUB_PORT", "9095"))
KEY = os.environ.get("HUB_KEY", "")
STATE_DIR = os.environ.get("HUB_STATE", "/var/lib/router-hub")
# The address behind the hub's own name. A router reaches the hub by name like
# everything else, so the DNS outage that makes it dial the wrong nodes also
# hides the one channel that could tell it so - that is what happened on
# 2 November 2026. Handed to the router at enrolment, it is used only when the
# name does not resolve, so a hub that moves is still found the ordinary way.
PUBLIC_IP = os.environ.get("HUB_PUBLIC_IP", "")
ACTIONS = ("fix", "logs", "status", "config", "route", "resub", "update", "move", "dns-google", "none")

# Config that may be pushed is deliberately one setting: which routing lists a
# router uses. A leaked key must not become a way to reconfigure someone else's
# network, so nothing else is accepted and every name is checked against what
# NetShift actually knows before it is stored.
COMMUNITY_SERVICES = (
    "russia_inside russia_outside ukraine_inside geoblock block porn news "
    "anime youtube hdrezka tiktok google_ai google_play hodca discord meta "
    "twitter cloudflare cloudfront digitalocean hetzner ovh telegram roblox"
).split()
LABEL_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
# The one thing a route push carries: a piece of a node name from the
# subscription, such as "Нидерланды". Letters, digits, space and hyphen only, so
# it can never be anything but a filter.
KEYWORD_RE = re.compile(r"^[\w -]{2,32}$")
# A move hands a router a different hub. A leaked key must not become a way to
# lead routers off to someone else's server, so the target is one of our own
# names and a public address, and the router checks both again before it
# touches hub.conf.
MOVE_HOSTS = ("anfisson.duckdns.org", "kanbanfi.ru")
MOVE_URL_RE = re.compile(r"^https://([a-z0-9.-]+)(/[A-Za-z0-9/_-]*)?$")
METRIC_MAX = 256 * 1024
ARCHIVE_MAX = 8 * 1024 * 1024
STALE_AFTER = 3600
ENROLL_TTL = 3600
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{16,64}$")
# The owner page is off unless a password hash is set, so a hub deployed
# without one exposes nothing new. The hash is read at call time (not copied)
# so a changed password drops every session and tests can swap it.
ADMIN_HASH = os.environ.get("HUB_ADMIN_PASSWORD_HASH", "")
SESSION_TTL = 30 * 86400
SESSION_COOKIE = "hub_session"
# Only for trying the page over plain http by hand; a Secure cookie is never
# stored by the browser there.
INSECURE_COOKIE = os.environ.get("HUB_INSECURE_COOKIE") == "1"
LOGIN_MAX = 4096
UI_BODY_MAX = 16 * 1024
# The page may queue only these. Tasks that carry a payload (move, route,
# setconfig) or change DNS stay behind the router key, so a stolen browser
# session cannot steer a router somewhere else.
UI_ACTIONS = ("logs", "update", "fix", "status", "resub")
# How many routers one bulk task may name; far above the fleet, well under
# UI_BODY_MAX (a label is at most 32 characters).
UI_BULK_MAX = 200
# Read from disk on every request, so a page fix needs no restart.
UI_FILE = os.environ.get("HUB_UI", os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "hub-ui.html"))
# The page builds everything from the hub's own JSON with textContent; this
# policy makes sure nothing else - no outside script, no frame, no form posting
# elsewhere - can run even if a router's reply slipped through as markup.
UI_HEADERS = (
    ("Cache-Control", "no-store"),
    ("X-Content-Type-Options", "nosniff"),
    ("Content-Security-Policy",
     "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
     "connect-src 'self'; img-src data:; form-action 'self'; "
     "frame-ancestors 'none'; base-uri 'none'"),
)
META_TEXT_MAX = 64
REPLY_MAX = 4096
REPLY_KEEP = 10
METRIC_LINE_RE = re.compile(r"^router_(\w+)\{([^}]*)\}\s+(\S+)$")
RAW = "https://raw.githubusercontent.com/anfixit/router-provisioner/main"

# Created at server start, not at import: `--hash-password` runs on a host
# where the state path is neither wanted nor writable.
def ensure_state_dir():
    os.makedirs(STATE_DIR, exist_ok=True)


# Wrong passwords hold a thread for ~1 s plus PBKDF2; the container has a small
# pids limit, so cap the guessers instead of letting them starve the routers.
_login_slots = threading.BoundedSemaphore(2)
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


def reported_version(label):
    """The provisioner version a router last reported, or "?" if it has not.

    Checking that an update actually landed is the commonest question asked of
    this server, and answering it meant reading the raw metrics by hand.
    """
    try:
        with open(_path("metrics", label), encoding="utf-8") as handle:
            for line in handle:
                if 'name="router-provisioner"' in line:
                    start = line.index('version="') + len('version="')
                    return line[start:line.index('"', start)]
    except (OSError, ValueError):
        pass
    return "?"


def clean_text(value):
    """A label text safe to show and store, or None.

    Control characters are refused rather than stripped: a name that needed
    stripping was not typed by a person, and silently altering it hides that."""
    if not isinstance(value, str):
        return None
    value = value.strip()
    if len(value) > META_TEXT_MAX:
        return None
    if any(unicodedata.category(ch).startswith("C") for ch in value):
        return None
    return value


def read_meta(label):
    try:
        with open(_path("meta", label), encoding="utf-8") as handle:
            data = json.load(handle)
        return {"name": str(data.get("name", "")),
                "owner": str(data.get("owner", "")),
                "most": data.get("most") is True}
    except (OSError, ValueError, AttributeError):
        return {"name": "", "owner": "", "most": False}


def write_meta(label, name, owner, most):
    with _lock:
        with open(_path("meta", label), "w", encoding="utf-8") as handle:
            json.dump({"name": name, "owner": owner, "most": bool(most)},
                      handle, ensure_ascii=False)


def store_reply(label, text, now):
    """Keep the last REPLY_KEEP router replies, one JSON object per line."""
    with _lock:
        lines = [json.dumps(r, ensure_ascii=False) for r in read_replies(label)]
        lines.append(json.dumps({"ts": now, "text": text}, ensure_ascii=False))
        with open(_path("reply", label), "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines[-REPLY_KEEP:]) + "\n")


def read_replies(label):
    out = []
    try:
        with open(_path("reply", label), encoding="utf-8") as handle:
            for line in handle:
                try:
                    item = json.loads(line)
                    out.append({"ts": item["ts"], "text": str(item["text"])})
                except (ValueError, KeyError, TypeError):
                    continue
    except (OSError, ValueError):
        pass
    return out[-REPLY_KEEP:]


def mark_taken(label, action, now):
    """Remember that the router collected a task, so the page can say so after
    the pending task is cleared."""
    with _lock:
        with open(_path("taken", label), "w", encoding="utf-8") as handle:
            json.dump({"action": action, "ts": now}, handle)


def read_taken(label):
    try:
        with open(_path("taken", label), encoding="utf-8") as handle:
            data = json.load(handle)
        return {"action": str(data["action"]), "ts": data["ts"]}
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _metric_values(label):
    """The few numbers the page shows, from the router's last report."""
    found = {}
    try:
        with open(_path("metrics", label), encoding="utf-8") as handle:
            for line in handle:
                match = METRIC_LINE_RE.match(line.strip())
                if match:
                    found.setdefault(match.group(1), match.group(3))
    except (OSError, ValueError):
        pass

    def number(name):
        try:
            return int(float(found[name]))
        except (KeyError, ValueError, OverflowError):
            return None

    def flag(name):
        value = number(name)
        return None if value is None else value == 1

    # clash_api_up is None for routers on a report that predates it.
    return (flag("singbox_running"), number("nodes_alive"),
            number("nodes_total"), flag("clash_api_up"))


def router_rows(now):
    labels = set()
    for name in os.listdir(STATE_DIR):
        for kind in ("metrics-", "meta-"):
            if name.startswith(kind) and LABEL_RE.match(name[len(kind):]):
                labels.add(name[len(kind):])
    rows = []
    for label in sorted(labels, key=str.lower):
        try:
            last_seen = os.path.getmtime(_path("metrics", label))
        except OSError:
            last_seen = None
        try:
            archive_ts = os.path.getmtime(_path("archive", label))
        except OSError:
            archive_ts = None
        singbox, alive, total, clash_api = _metric_values(label)
        rows.append({
            **read_meta(label),
            "label": label,
            "last_seen": last_seen,
            "stale": last_seen is not None and now - last_seen > STALE_AFTER,
            "waiting": last_seen is None,
            "version": reported_version(label),
            "singbox": singbox,
            "nodes_alive": alive,
            "nodes_total": total,
            "clash_api": clash_api,
            "task": read_task(label),
            "taken": read_taken(label),
            "replies": read_replies(label)[::-1],
            "archive_ts": archive_ts,
        })
    return rows


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


def enroll_script(label, base):
    """What a friend's router runs once to join the hub.

    One line pasted over ssh, no file to edit. The key travels inside the
    script, so the link that serves it is single-use and short-lived."""
    return f"""#!/bin/ash
set -e
mkdir -p /etc/router-provisioner
umask 077
cat > /etc/router-provisioner/hub.conf <<'EOF'
HUB_URL='{base}'
HUB_KEY='{KEY}'
HUB_IP='{PUBLIC_IP}'
LABEL='{label}'
EOF
chmod 600 /etc/router-provisioner/hub.conf
if [ ! -x /usr/bin/router-provisioner-report ]; then
    # The installer needs a terminal and the OpenWrt package servers, which a
    # router already running NetShift cannot reach (their names resolve to a
    # fake address). The helpers themselves only need GitHub.
    for helper in report command logship upgrade; do
        uclient-fetch -4 -q -O /tmp/rp-$helper \\
            {RAW}/runtime/router-provisioner-$helper
        head -n 1 /tmp/rp-$helper | grep -q '^#!'
        cp /tmp/rp-$helper /usr/bin/router-provisioner-$helper
        chmod 700 /usr/bin/router-provisioner-$helper
        rm -f /tmp/rp-$helper
    done
    uclient-fetch -4 -q -O /etc/router-provisioner/version {RAW}/VERSION
    touch /etc/crontabs/root
    grep -vE 'router-provisioner-(report|command|logship|upgrade)' /etc/crontabs/root > /tmp/rp-cron || true
    {{
        cat /tmp/rp-cron
        echo '*/5 * * * * /usr/bin/router-provisioner-report'
        echo '*/2 * * * * /usr/bin/router-provisioner-command'
        echo '0 9 */3 * * /usr/bin/router-provisioner-logship'
        echo '45 3 * * * /usr/bin/router-provisioner-upgrade'
    }} > /etc/crontabs/root
    rm -f /tmp/rp-cron
    chmod 600 /etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1 || true
fi
/usr/bin/router-provisioner-report >/dev/null 2>&1 || true
echo "Готово: роутер подключён к хабу как {label}."
"""


def make_enroll(label):
    """Store a one-time enrolment token for the label and return the token."""
    token = secrets.token_urlsafe(16)
    with _lock:
        with open(_path("enroll", token), "w", encoding="utf-8") as handle:
            handle.write(label)
    return token


def enroll_command(base, token):
    return "uclient-fetch -4 -q -O- %s/enroll/%s | sh" % (base, token)


def label_taken(label):
    return any(os.path.exists(_path(kind, label)) for kind in ("metrics", "meta"))


def move_target(url, ip):
    match = MOVE_URL_RE.match(url)
    if not match or match.group(1) not in MOVE_HOSTS:
        return None
    try:
        address = ipaddress.IPv4Address(ip)
    except ValueError:
        return None
    if not address.is_global:
        return None
    return "%s %s" % (url.rstrip("/"), address)


def take_enroll(token):
    """The label a token was made for, or "" - and the token is spent."""
    path = _path("enroll", token)
    with _lock:
        try:
            age = time.time() - os.path.getmtime(path)
            with open(path, encoding="utf-8") as handle:
                label = handle.read().strip()
            os.remove(path)
        except OSError:
            return ""
    return label if age <= ENROLL_TTL else ""


def hash_password(password, iterations=600_000, salt=None):
    salt = salt if salt is not None else secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    return "pbkdf2_sha256$%d$%s$%s" % (iterations, salt.hex(), digest.hex())


def check_password(password, stored):
    """True if the password matches; a mangled stored string is just False."""
    # An empty password must never match, even if such a hash was stored.
    if not password:
        return False
    try:
        scheme, iterations, salt, digest = stored.split("$")
        if scheme != "pbkdf2_sha256":
            return False
        expected = hashlib.pbkdf2_hmac(
            "sha256", password.encode(), bytes.fromhex(salt), int(iterations))
        return hmac.compare_digest(expected, bytes.fromhex(digest))
    except (ValueError, TypeError):
        return False


def _session_key():
    # Derived from the hash, so changing the password invalidates every
    # session without any server-side session store.
    return hashlib.sha256(b"session:" + ADMIN_HASH.encode()).digest()


def _sign(expiry):
    return hmac.new(_session_key(), str(expiry).encode(), hashlib.sha256).hexdigest()


def make_session(now):
    expiry = int(now) + SESSION_TTL
    return "%d.%s" % (expiry, _sign(expiry))


def session_ok(value, now):
    if not ADMIN_HASH:
        return False
    expiry, _, signature = value.partition(".")
    # isdigit() alone accepts "²" and unbounded strings, which break int().
    if not (expiry.isascii() and expiry.isdigit() and len(expiry) <= 12) \
            or not hmac.compare_digest(
            signature.encode(), _sign(int(expiry)).encode()):
        return False
    return int(expiry) > now


def session_cookie(value, max_age):
    return "%s=%s; HttpOnly;%s SameSite=Strict; Path=/hub/; Max-Age=%d" % (
        SESSION_COOKIE, value, "" if INSECURE_COOKIE else " Secure;", max_age)


def public_base(headers):
    return os.environ.get("HUB_PUBLIC_URL") or "https://%s/hub" % (
        headers.get("Host") or "localhost")


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "router-hub"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body="", ctype="text/plain; charset=utf-8", headers=()):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _authorised(self, query):
        given = query.get("key", [""])[0]
        return bool(KEY) and secrets.compare_digest(given.encode(), KEY.encode())

    def _session(self):
        jar = http.cookies.SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie", ""))
        except http.cookies.CookieError:
            return False
        morsel = jar.get(SESSION_COOKIE)
        return bool(morsel) and session_ok(morsel.value, time.time())

    def _ui_guard(self, write):
        """Answer for the owner page API; True means the caller may go on.

        404 when the page is off, 401 (not 404) without a session so an open
        tab can tell it has expired and stop polling, 403 for a write that
        lacks the custom header a cross-site form cannot add."""
        if not ADMIN_HASH:
            self._send(404, "not found\n")
            return False
        if not self._session():
            self._send(401, "login required\n")
            return False
        if write and self.headers.get("X-Hub-UI") != "1":
            self._send(403, "forbidden\n")
            return False
        return True

    def _send_archive(self, label):
        try:
            with open(_path("archive", label), "rb") as handle:
                body = handle.read()
        except OSError:
            self._send(404, "no archive yet\n")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Disposition",
                         'attachment; filename="%s.tar.gz"' % label)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, data):
        self._send(code, json.dumps(data, ensure_ascii=False),
                   "application/json; charset=utf-8",
                   (("Cache-Control", "no-store"),))

    def _fail(self, code, message):
        self._json(code, {"error": message})

    def _read_json(self):
        """The request body as a dict, or None after answering 400 itself."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length <= 0 or length > UI_BODY_MAX:
            self._fail(400, "Некорректный запрос.")
            return None
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, RecursionError):
            data = None
        if not isinstance(data, dict):
            self._fail(400, "Некорректный запрос.")
            return None
        return data

    def _ui_post(self, parts):
        if parts not in (["ui", "api", "task"], ["ui", "api", "tasks"],
                         ["ui", "api", "meta"], ["ui", "api", "enroll"]):
            self._send(404, "not found\n")
            return
        data = self._read_json()
        if data is None:
            return

        # One task for several routers at once. All labels are checked before
        # any is written, so a bad one cannot leave the batch half done.
        if parts == ["ui", "api", "tasks"]:
            labels, action = data.get("labels"), data.get("action")
            if action not in UI_ACTIONS:
                self._fail(400, "Такое задание отсюда не ставится.")
                return
            if (not isinstance(labels, list) or not 0 < len(labels) <= UI_BULK_MAX
                    or not all(isinstance(item, str) and LABEL_RE.fullmatch(item)
                               for item in labels)):
                self._fail(400, "Нужен список до %d меток: латиница, цифры, - и _."
                           % UI_BULK_MAX)
                return
            unique = list(dict.fromkeys(labels))
            for item in unique:
                write_task(item, action)
            self._json(200, {"ok": True, "count": len(unique)})
            return

        label = data.get("label")
        # fullmatch: `$` in LABEL_RE also accepts a trailing newline, which must
        # never reach a file name or the enrolment script.
        if not isinstance(label, str) or not LABEL_RE.fullmatch(label):
            self._fail(400, "Метка: до 32 символов, латиница, цифры, - и _.")
            return

        if parts == ["ui", "api", "task"]:
            action = data.get("action")
            if action not in UI_ACTIONS:
                self._fail(400, "Такое задание отсюда не ставится.")
                return
            write_task(label, action)
            self._json(200, {"ok": True})
            return

        if parts in (["ui", "api", "meta"], ["ui", "api", "enroll"]):
            name = clean_text(data.get("name", ""))
            owner = clean_text(data.get("owner", ""))
            if name is None or owner is None:
                self._fail(400, "Подписи: до %d символов, без управляющих символов."
                           % META_TEXT_MAX)
                return
            if not isinstance(data.get("most"), bool):
                self._fail(400, "Поле «МОСТ» должно быть да или нет.")
                return
            most = data["most"]
            if parts[2] == "meta":
                write_meta(label, name, owner, most)
                self._json(200, {"ok": True})
                return
            reinstall = data.get("reinstall") is True
            # Check and write under one lock, so two clicks cannot both pass
            # the check and the second overwrite the first one's labels.
            with _lock:
                if label_taken(label):
                    if not reinstall:
                        self._fail(409, "Метка уже занята. Если это переустановка "
                                        "того же роутера, отметьте галочку.")
                        return
                    old = read_meta(label)
                    name, owner = name or old["name"], owner or old["owner"]
                write_meta(label, name, owner, most)
                token = make_enroll(label)
            self._json(200, {"code": token, "command": enroll_command(
                public_base(self.headers), token)})

    def _see_other(self, cookie):
        self._send(303, headers=(("Location", public_base(self.headers) + "/"),
                                 ("Set-Cookie", cookie)))

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        parts = [p for p in parsed.path.split("/") if p]

        # The page itself carries no secrets: without a session its script
        # gets 401 from the API and shows the login form.
        if not parts:
            if not ADMIN_HASH:
                self._send(404, "not found\n")
                return
            try:
                with open(UI_FILE, encoding="utf-8") as handle:
                    page = handle.read()
            except OSError:
                self._send(404, "not found\n")
                return
            self._send(200, page, "text/html; charset=utf-8", UI_HEADERS)
            return

        # The owner page lives apart from the router paths and has its own
        # credential, so it is settled before the router key is looked at.
        if parts[:1] == ["ui"]:
            if parts[:2] == ["ui", "api"]:
                if not self._ui_guard(write=False):
                    return
                if parts == ["ui", "api", "routers"]:
                    now = time.time()
                    self._send(200, json.dumps(
                        {"now": now, "routers": router_rows(now)},
                        ensure_ascii=False),
                        "application/json; charset=utf-8",
                        (("Cache-Control", "no-store"),))
                    return
                if len(parts) == 4 and parts[2] == "logs":
                    if not LABEL_RE.match(parts[3]):
                        self._fail(400, "Некорректная метка.")
                        return
                    self._send_archive(parts[3])
                    return
            self._send(404, "not found\n")
            return

        # Prometheus scrapes this from the same host; no key, no secrets in it.
        # Raw path on purpose: "/metrics/" must not slip through the proxy rule
        # that only closes the exact path.
        if parsed.path == "/metrics":
            self._send(200, all_metrics())
            return

        # A friend's router joining. The one-time token is the credential, so
        # this sits before the key check; anything wrong is a plain 404.
        if len(parts) == 2 and parts[0] == "enroll":
            label = take_enroll(parts[1]) if TOKEN_RE.match(parts[1]) else ""
            if not label:
                self._send(404, "not found\n")
                return
            self._send(200, enroll_script(label, public_base(self.headers)))
            return

        if not self._authorised(query):
            self._send(404, "not found\n")
            return

        # The owner minting the one line a friend pastes into their router.
        if len(parts) == 2 and parts[0] == "mkenroll":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            token = make_enroll(label)
            self._send(200, enroll_command(public_base(self.headers), token) + "\n")
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
                    # Bookkeeping only: a failed write must not eat the task
                    # that was just cleared.
                    try:
                        mark_taken(label, action, time.time())
                    except OSError:
                        pass
            self._send(200, (action or "none") + "\n")
            return

        # Handing back the archive a router uploaded. Telegram needs a bot
        # token and a working tunnel; this path needs neither, so a router with
        # only the hub configured can still be asked what happened to it.
        if len(parts) == 2 and parts[0] == "logs":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            self._send_archive(label)
            return

        # The owner pushing which routing lists a router should use.
        if len(parts) == 2 and parts[0] == "setconfig":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            raw = query.get("lists", [""])[0]
            names = [n.strip() for n in raw.split(",") if n.strip()]
            unknown = [n for n in names if n not in COMMUNITY_SERVICES]
            if not names or unknown:
                self._send(400, "unknown lists: %s\n" % (", ".join(unknown) or "-"))
                return
            # russia_outside is the list of Russian services that are blocked
            # when reached from abroad, so proxying them is the exact opposite
            # of what it is for. It was pushed that way once and VK, mail.ru,
            # Yandex and the radio went out through a Dutch exit. The router
            # refuses it too, but a refusal that only reaches the router's own
            # journal is one nobody reads; say so here, where it is asked.
            if "russia_outside" in names:
                self._send(400, "russia_outside must not be proxied; it "
                                "belongs in the direct section, which the "
                                "routers now set themselves\n")
                return
            with _lock:
                with open(_path("config", label), "w", encoding="utf-8") as handle:
                    handle.write(" ".join(names))
                write_task(label, "config")
            self._send(200, "%s: %d lists queued\n" % (label, len(names)))
            return

        # The router collecting what it should apply.
        if len(parts) == 2 and parts[0] == "config":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            try:
                with open(_path("config", label), encoding="utf-8") as handle:
                    self._send(200, handle.read().strip() + "\n")
            except OSError:
                self._send(200, "\n")
            return

        # The owner sending Anthropic through a group of nodes picked by name.
        # The domains are fixed on the router; only the name filter travels.
        if len(parts) == 2 and parts[0] == "setroute":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            keyword = query.get("keyword", [""])[0].strip()
            if not KEYWORD_RE.match(keyword):
                self._send(400, "bad keyword\n")
                return
            with _lock:
                with open(_path("route", label), "w", encoding="utf-8") as handle:
                    handle.write(keyword)
                write_task(label, "route")
            self._send(200, "%s: route queued\n" % label)
            return

        # The router collecting the name filter it should apply.
        if len(parts) == 2 and parts[0] == "route":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            try:
                with open(_path("route", label), encoding="utf-8") as handle:
                    self._send(200, handle.read().strip() + "\n")
            except OSError:
                self._send(200, "\n")
            return

        if len(parts) == 2 and parts[0] == "setmove":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            target = move_target(query.get("url", [""])[0].strip(),
                                 query.get("ip", [""])[0].strip())
            if not target:
                self._send(400, "bad target\n")
                return
            with _lock:
                with open(_path("move", label), "w", encoding="utf-8") as handle:
                    handle.write(target)
                write_task(label, "move")
            self._send(200, "%s: move queued\n" % label)
            return

        # The router collecting where it should go.
        if len(parts) == 2 and parts[0] == "move":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            try:
                with open(_path("move", label), encoding="utf-8") as handle:
                    self._send(200, handle.read().strip() + "\n")
            except OSError:
                self._send(200, "\n")
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
                rows.append(
                    f"{label}: {age:.0f}s назад, задание: {pending}, "
                    f"версия: {reported_version(label)}"
                )
            self._send(200, "\n".join(rows) + "\n" if rows else "пусто\n")
            return

        self._send(404, "not found\n")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        parts = [p for p in parsed.path.split("/") if p]

        if parts == ["ui", "login"]:
            if not ADMIN_HASH:
                self._send(404, "not found\n")
                return
            length = int(self.headers.get("Content-Length") or 0)
            form = urllib.parse.parse_qs(
                self.rfile.read(min(max(length, 0), LOGIN_MAX)).decode("utf-8", "replace"))
            if not _login_slots.acquire(blocking=False):
                self._send(404, "not found\n")
                return
            try:
                if check_password(form.get("password", [""])[0], ADMIN_HASH):
                    self._see_other(session_cookie(make_session(time.time()), SESSION_TTL))
                    return
                # A pause makes guessing slow; 404 confirms nothing about the page.
                time.sleep(1)
            finally:
                _login_slots.release()
            self._send(404, "not found\n")
            return

        if parts == ["ui", "logout"]:
            if not ADMIN_HASH:
                self._send(404, "not found\n")
                return
            self._see_other(session_cookie("", 0))
            return

        if parts[:1] == ["ui"]:
            if parts[:2] == ["ui", "api"]:
                if not self._ui_guard(write=True):
                    return
                self._ui_post(parts)
                return
            self._send(404, "not found\n")
            return

        if not self._authorised(query):
            self._send(404, "not found\n")
            return

        if len(parts) == 2 and parts[0] == "logs":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > ARCHIVE_MAX:
                self._send(413, "too big\n")
                return
            with _lock:
                with open(_path("archive", label), "wb") as handle:
                    handle.write(self.rfile.read(length))
            self._send(200, "ok\n")
            return

        # What a router has to say back about a task it ran.
        if len(parts) == 2 and parts[0] == "reply":
            label = parts[1]
            if not LABEL_RE.match(label):
                self._send(400, "bad label\n")
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > REPLY_MAX:
                self._send(413, "too big\n")
                return
            store_reply(label, self.rfile.read(length).decode("utf-8", "replace"),
                        time.time())
            self._send(200, "ok\n")
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
    if "--hash-password" in sys.argv:
        first = getpass.getpass("Пароль: ")
        if not first:
            raise SystemExit("Пустой пароль не годится")
        if first != getpass.getpass("Ещё раз: "):
            raise SystemExit("Пароли не совпали")
        print(hash_password(first))
        raise SystemExit(0)
    if not KEY:
        raise SystemExit("HUB_KEY is not set; refusing to run without one")
    ensure_state_dir()
    with Server(("0.0.0.0", PORT), Handler) as httpd:
        httpd.serve_forever()
