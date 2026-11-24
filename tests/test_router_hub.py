#!/usr/bin/env python3
"""Live requests against router-hub.py on a random port."""

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request

KEY = "test-key-0123456789"
STATE = tempfile.mkdtemp()
os.environ["HUB_KEY"] = KEY
os.environ["HUB_STATE"] = STATE

_src = pathlib.Path(__file__).resolve().parent.parent / "server" / "router-hub.py"
UI_PAGE = _src.with_name("hub-ui.html")
_spec = importlib.util.spec_from_file_location("router_hub", _src)
hub = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hub)


class HubTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        hub.ADMIN_HASH = hub.hash_password("pw-test", iterations=1000)
        cls.httpd = hub.Server(("127.0.0.1", 0), hub.Handler)
        cls.base = "http://127.0.0.1:%d" % cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def get(self, path, **query):
        query.setdefault("key", KEY)
        url = self.base + path + "?" + urllib.parse.urlencode(query)
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                return resp.status, resp.read().decode()
        except urllib.error.HTTPError as err:
            with err:
                return err.code, err.read().decode()

    def ui(self, method, path, body=None, cookie=None, headers=None):
        """A request without the router key, and without following redirects."""
        class Stay(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None

        data = body.encode() if isinstance(body, str) else body
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
        if cookie:
            req.add_header("Cookie", cookie)
        for name, value in (headers or {}).items():
            req.add_header(name, value)
        opener = urllib.request.build_opener(Stay)
        try:
            with opener.open(req, timeout=5) as resp:
                return resp.status, resp.headers, resp.read().decode()
        except urllib.error.HTTPError as err:
            with err:
                return err.code, err.headers, err.read().decode()

    def test_password_hash_round_trip(self):
        stored = hub.hash_password("pw-test", iterations=1000)
        self.assertTrue(hub.check_password("pw-test", stored))
        self.assertFalse(hub.check_password("wrong", stored))
        self.assertFalse(hub.check_password("pw-test", "garbage"))

    def test_login_sets_strict_cookie(self):
        code, headers, _ = self.ui("POST", "/ui/login", "password=pw-test")
        self.assertEqual(code, 303)
        self.assertTrue(headers["Location"].endswith("/"))
        cookie = headers["Set-Cookie"]
        for part in ("hub_session=", "HttpOnly", "Secure", "SameSite=Strict",
                     "Path=/hub/"):
            self.assertIn(part, cookie)

    def test_session_cookie_opens_the_api_guard(self):
        _, headers, _ = self.ui("POST", "/ui/login", "password=pw-test")
        cookie = headers["Set-Cookie"].split(";")[0]
        self.assertEqual(self.ui("GET", "/ui/api/x", cookie=cookie)[0], 404)

    def test_wrong_password_is_not_found(self):
        self.assertEqual(self.ui("POST", "/ui/login", "password=nope")[0], 404)

    def test_logout_clears_cookie(self):
        code, headers, _ = self.ui("POST", "/ui/logout", "")
        self.assertEqual(code, 303)
        self.assertIn("Max-Age=0", headers["Set-Cookie"])

    def test_api_without_session_is_401(self):
        self.assertEqual(self.ui("GET", "/ui/api/routers")[0], 401)
        self.assertEqual(self.ui("GET", "/ui/api/x")[0], 401)

    def test_forged_and_expired_sessions_are_refused(self):
        now = time.time()
        self.assertFalse(hub.session_ok("9999999999.00", now))
        self.assertFalse(hub.session_ok(hub.make_session(now - hub.SESSION_TTL - 1), now))
        self.assertTrue(hub.session_ok(hub.make_session(now), now))

    def test_password_change_drops_sessions(self):
        old = hub.ADMIN_HASH
        try:
            value = hub.make_session(time.time())
            hub.ADMIN_HASH = hub.hash_password("other", iterations=1000)
            self.assertFalse(hub.session_ok(value, time.time()))
        finally:
            hub.ADMIN_HASH = old

    def test_ui_is_off_without_password(self):
        old = hub.ADMIN_HASH
        try:
            hub.ADMIN_HASH = ""
            self.assertEqual(self.ui("POST", "/ui/login", "password=pw-test")[0], 404)
            self.assertEqual(self.ui("GET", "/ui/api/x")[0], 404)
            self.assertEqual(self.ui("POST", "/ui/logout", "")[0], 404)
        finally:
            hub.ADMIN_HASH = old

    def test_malformed_session_cookie_is_401(self):
        for value in ("\u00b2.00", "9" * 5000 + ".00", "x", ""):
            with self.subTest(value=value[:10]):
                code = self.ui("GET", "/ui/api/x",
                               headers={"Cookie": "hub_session=" + value})[0]
                self.assertEqual(code, 401)

    def test_empty_password_never_logs_in(self):
        self.assertFalse(hub.check_password("", hub.hash_password("", iterations=1000)))
        old = hub.ADMIN_HASH
        try:
            hub.ADMIN_HASH = hub.hash_password("", iterations=1000)
            self.assertEqual(self.ui("POST", "/ui/login", "password=")[0], 404)
        finally:
            hub.ADMIN_HASH = old

    def test_dns_google_is_delivered_once_to_selected_router(self):
        self.assertEqual(self.get("/set/client/dns-google")[0], 200)
        self.assertEqual(self.get("/task/other"), (200, "none\n"))
        self.assertEqual(self.get("/task/client"), (200, "dns-google\n"))
        self.assertEqual(self.get("/task/client"), (200, "none\n"))

    def test_wrong_key_is_not_found(self):
        self.assertEqual(self.get("/move/r1", key="nope")[0], 404)

    def test_move_round_trip(self):
        code, _ = self.get("/setmove/r1", url="https://anfisson.duckdns.org/hub",
                           ip="1.2.3.4")
        self.assertEqual(code, 200)
        self.assertEqual(self.get("/move/r1"),
                         (200, "https://anfisson.duckdns.org/hub 1.2.3.4\n"))
        self.assertEqual(self.get("/task/r1"), (200, "move\n"))

    def test_move_without_target_is_empty(self):
        self.assertEqual(self.get("/move/never-set"), (200, "\n"))

    def test_foreign_targets_are_refused(self):
        bad = [
            ("https://evil.example/hub", "1.2.3.4"),
            ("http://anfisson.duckdns.org/hub", "1.2.3.4"),
            ("https://anfisson.duckdns.org.evil.example/hub", "1.2.3.4"),
            ("https://anfisson.duckdns.org@evil.example/hub", "1.2.3.4"),
            ("https://anfisson.duckdns.org/hub;rm", "1.2.3.4"),
            ("https://anfisson.duckdns.org/hub", "10.66.78.10"),
            ("https://anfisson.duckdns.org/hub", "not-an-ip"),
        ]
        for url, ip in bad:
            with self.subTest(url=url, ip=ip):
                self.assertEqual(self.get("/setmove/r2", url=url, ip=ip)[0], 400)

    def test_key_is_compared_in_constant_time(self):
        self.assertIn("compare_digest", _src.read_text(encoding="utf-8"))

    def post(self, path, body=b"", key=KEY):
        req = urllib.request.Request(
            self.base + path + "?" + urllib.parse.urlencode({"key": key}),
            data=body, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, resp.read().decode()
        except urllib.error.HTTPError as err:
            with err:
                return err.code, err.read().decode()

    def session_cookie(self):
        _, headers, _ = self.ui("POST", "/ui/login", "password=pw-test")
        return headers["Set-Cookie"].split(";")[0]

    def routers(self):
        code, headers, body = self.ui("GET", "/ui/api/routers",
                                      cookie=self.session_cookie())
        self.assertEqual(code, 200)
        self.assertEqual(headers["Content-Type"], "application/json; charset=utf-8")
        self.assertEqual(headers["Cache-Control"], "no-store")
        return {row["label"]: row for row in json.loads(body)["routers"]}

    def test_reply_is_stored_and_capped(self):
        hub.write_meta("r5", "", "", False)  # the list shows labels with metrics or meta
        for i in range(12):
            self.assertEqual(self.post("/reply/r5", b"m%d" % i)[0], 200)
        self.assertEqual([r["text"] for r in hub.read_replies("r5")],
                         ["m%d" % i for i in range(2, 12)])
        self.assertEqual(self.routers()["r5"]["replies"][0]["text"], "m11")
        self.assertEqual(self.post("/reply/r5", b"x" * 5000)[0], 413)
        self.assertEqual(self.post("/reply/r5", b"hi", key="nope")[0], 404)

    def test_task_pickup_is_recorded(self):
        self.get("/set/r6/logs")
        self.get("/task/r6")
        self.assertEqual(hub.read_taken("r6")["action"], "logs")
        self.get("/task/r6")
        self.assertEqual(hub.read_taken("r6")["action"], "logs")

    def test_task_survives_failed_bookkeeping(self):
        self.get("/set/r9/status")
        real = hub.mark_taken
        def boom(*args):
            raise OSError("disk full")
        hub.mark_taken = boom
        try:
            self.assertEqual(self.get("/task/r9"), (200, "status\n"))
        finally:
            hub.mark_taken = real

    def test_routers_list_survives_garbage_files(self):
        def put(name, data):
            with open(os.path.join(STATE, name), "wb") as handle:
                handle.write(data)
        put("metrics-g1", b"\xff\xfe\x80 bad")
        put("meta-g2", b"not json")
        put("meta-g3", b"[1, 2]")
        put("taken-g2", b"\xff garbage")
        put("reply-g2", b"\xff\n{not json}\n")
        rows = self.routers()
        for label in ("g1", "g2", "g3"):
            self.assertIn(label, rows)

    def test_routers_list_tells_silent_api_from_missing_data(self):
        body = ('router_singbox_running{router="r9"} 1\n'
                'router_clash_api_up{router="r9"} 0\n')
        self.assertEqual(self.post("/metrics/r9", body.encode())[0], 200)
        r9 = self.routers()["r9"]
        self.assertIs(r9["clash_api"], False)
        self.assertIsNone(r9["nodes_total"])

    def test_meta_text_is_cleaned(self):
        self.assertEqual(hub.clean_text("Анфиса"), "Анфиса")
        self.assertIsNone(hub.clean_text("a\x07b"))
        self.assertIsNone(hub.clean_text("x" * 65))

    def test_routers_list_merges_metrics_and_meta(self):
        body = (
            'router_singbox_running{router="r7"} 1\n'
            'router_nodes_alive{router="r7"} 41\n'
            'router_nodes_total{router="r7"} 73\n'
            'router_component_version{router="r7",name="router-provisioner",'
            'version="2.31.0"} 1\n')
        self.assertEqual(self.post("/metrics/r7", body.encode())[0], 200)
        hub.write_meta("r8", "Мама", "Анфиса", True)
        rows = self.routers()
        r7, r8 = rows["r7"], rows["r8"]
        self.assertIs(r7["singbox"], True)
        self.assertEqual((r7["nodes_alive"], r7["nodes_total"]), (41, 73))
        self.assertEqual(r7["version"], "2.31.0")
        self.assertIsNone(r7["clash_api"])  # a report from before the flag
        self.assertIs(r7["waiting"], False)
        self.assertIs(r8["waiting"], True)
        self.assertIsNone(r8["last_seen"])
        self.assertEqual((r8["name"], r8["owner"], r8["most"]), ("Мама", "Анфиса", True))

    def test_routers_list_reports_archive_time(self):
        self.post("/metrics/r7", b"x 1\n")
        try:
            os.remove(os.path.join(STATE, "archive-r7"))
        except OSError:
            pass
        self.assertIsNone(self.routers()["r7"]["archive_ts"])
        self.assertEqual(self.post("/logs/r7", b"data")[0], 200)
        self.assertIsInstance(self.routers()["r7"]["archive_ts"], float)

    def test_stale_router_is_marked(self):
        self.post("/metrics/r7", b"x 1\n")
        t = time.time()
        os.utime(os.path.join(STATE, "metrics-r7"), (t - 3601, t - 3601))
        self.assertIs(self.routers()["r7"]["stale"], True)

    def ui_json(self, path, payload, cookie="", ui_header=True, method="POST"):
        headers = {"Content-Type": "application/json"}
        if ui_header:
            headers["X-Hub-UI"] = "1"
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        return self.ui(method, path, body, cookie=cookie or None, headers=headers)

    def test_ui_task_only_from_short_list(self):
        cookie = self.session_cookie()
        code, headers, _ = self.ui_json("/ui/api/task", {"label": "r14", "action": "logs"}, cookie)
        self.assertEqual(code, 200)
        self.assertEqual(headers["Content-Type"], "application/json; charset=utf-8")
        self.assertEqual(self.get("/task/r14"), (200, "logs\n"))
        for action in ("move", "route", "setconfig", "dns-google", "none", 5):
            with self.subTest(action=action):
                self.assertEqual(self.ui_json(
                    "/ui/api/task", {"label": "r14", "action": action}, cookie)[0], 400)
        self.assertEqual(self.ui_json(
            "/ui/api/task", {"label": "bad label!", "action": "logs"}, cookie)[0], 400)
        self.assertEqual(self.ui_json(
            "/ui/api/task", {"label": "r14", "action": "logs"}, cookie, ui_header=False)[0], 403)
        self.assertEqual(self.ui_json(
            "/ui/api/task", {"label": "r14", "action": "logs"})[0], 401)

    def test_ui_bulk_task_writes_every_label_or_none(self):
        cookie = self.session_cookie()
        code, _, body = self.ui_json(
            "/ui/api/tasks", {"labels": ["r20", "r21", "r20"], "action": "status"}, cookie)
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body), {"ok": True, "count": 2})
        self.assertEqual(self.get("/task/r20"), (200, "status\n"))
        self.assertEqual(self.get("/task/r21"), (200, "status\n"))
        # One bad label refuses the whole batch: r22 must stay without a task.
        for labels in (["r22", "bad label!"], ["r22", "r23\n"], ["r22", 5], [],
                       "r22", ["r%d" % n for n in range(hub.UI_BULK_MAX + 1)]):
            with self.subTest(labels=str(labels)[:40]):
                self.assertEqual(self.ui_json(
                    "/ui/api/tasks", {"labels": labels, "action": "logs"}, cookie)[0], 400)
        self.assertEqual(self.get("/task/r22"), (200, "none\n"))
        for action in ("move", "dns-google", None):
            with self.subTest(action=action):
                self.assertEqual(self.ui_json(
                    "/ui/api/tasks", {"labels": ["r22"], "action": action}, cookie)[0], 400)
        self.assertEqual(self.ui_json(
            "/ui/api/tasks", {"labels": ["r22"], "action": "logs"}, cookie,
            ui_header=False)[0], 403)
        self.assertEqual(self.ui_json(
            "/ui/api/tasks", {"labels": ["r22"], "action": "logs"})[0], 401)

    def test_ui_json_body_is_limited_and_checked(self):
        cookie = self.session_cookie()
        self.assertEqual(self.ui_json("/ui/api/task", b"not json", cookie)[0], 400)
        self.assertEqual(self.ui_json("/ui/api/task", b"[1]", cookie)[0], 400)
        big = {"label": "r14", "action": "logs", "pad": "x" * 20000}
        code, headers, body = self.ui_json("/ui/api/task", big, cookie)
        self.assertEqual(code, 400)
        self.assertIn("error", json.loads(body))
        ok = {"label": "r14", "action": "logs", "pad": "x" * 15000}
        self.assertEqual(self.ui_json("/ui/api/task", ok, cookie)[0], 200)
        # Deep nesting raises RecursionError, not ValueError.
        self.assertEqual(self.ui_json("/ui/api/task", b"[" * 10000, cookie)[0], 400)

    def test_ui_label_with_trailing_newline_is_refused(self):
        cookie = self.session_cookie()
        for path, extra in (("task", {"action": "logs"}),
                            ("meta", {"name": "", "owner": "", "most": False}),
                            ("enroll", {"name": "", "owner": "", "most": False})):
            with self.subTest(path=path):
                self.assertEqual(self.ui_json(
                    "/ui/api/" + path, {"label": "r1\n", **extra}, cookie)[0], 400)
        self.assertFalse(os.path.exists(os.path.join(STATE, "meta-r1\n")))

    def test_reinstall_with_metrics_only_writes_meta(self):
        self.post("/metrics/r18", b"x 1\n")
        code, _ = self.enroll(self.session_cookie(), label="r18", name="Дача", reinstall=True)
        self.assertEqual(code, 200)
        self.assertEqual(hub.read_meta("r18")["name"], "Дача")

    def test_ui_meta_round_trip(self):
        cookie = self.session_cookie()
        meta = {"label": "r10", "name": "Камаловы", "owner": "друзья Анфисы", "most": False}
        self.assertEqual(self.ui_json("/ui/api/meta", meta, cookie)[0], 200)
        self.assertEqual(hub.read_meta("r10"),
                         {"name": "Камаловы", "owner": "друзья Анфисы", "most": False})
        for bad in ({**meta, "name": "a\x00b"}, {**meta, "most": "yes"},
                    {**meta, "owner": 5}):
            with self.subTest(bad=bad):
                code, _, body = self.ui_json("/ui/api/meta", bad, cookie)
                self.assertEqual(code, 400)
                self.assertIn("error", json.loads(body))

    def test_ui_logs_download_by_session(self):
        self.assertEqual(self.post("/logs/r15", b"archive-bytes")[0], 200)
        code, headers, body = self.ui("GET", "/ui/api/logs/r15", cookie=self.session_cookie())
        self.assertEqual((code, body), (200, "archive-bytes"))
        self.assertEqual(headers["Content-Type"], "application/gzip")
        self.assertIn("r15.tar.gz", headers["Content-Disposition"])
        self.assertEqual(self.ui("GET", "/ui/api/logs/none-yet",
                                 cookie=self.session_cookie())[0], 404)
        self.assertEqual(self.ui("GET", "/ui/api/logs/r15")[0], 401)

    def enroll(self, cookie, **fields):
        payload = {"label": "r11", "name": "", "owner": "", "most": True, "reinstall": False}
        payload.update(fields)
        code, _, body = self.ui_json("/ui/api/enroll", payload, cookie)
        return code, json.loads(body)

    def test_enroll_from_page_writes_meta_and_token(self):
        code, data = self.enroll(self.session_cookie(), name="Мама")
        self.assertEqual(code, 200)
        self.assertTrue(hub.TOKEN_RE.match(data["code"]))
        self.assertTrue(data["command"].endswith("/enroll/%s | sh" % data["code"]))
        self.assertTrue(data["command"].startswith("uclient-fetch -4 -q -O- "))
        self.assertIs(hub.read_meta("r11")["most"], True)
        self.assertEqual(hub.read_meta("r11")["name"], "Мама")
        code, body = self.get("/enroll/" + data["code"], key="")
        self.assertEqual(code, 200)
        self.assertIn("LABEL='r11'", body)
        self.assertEqual(self.get("/enroll/" + data["code"], key="")[0], 404)

    def test_enroll_refuses_taken_label(self):
        cookie = self.session_cookie()
        hub.write_meta("r12", "Старое имя", "", False)
        code, data = self.enroll(cookie, label="r12", name="Новое")
        self.assertEqual(code, 409)
        self.assertEqual(data["error"],
                         "Метка уже занята. Если это переустановка того же роутера, отметьте галочку.")
        self.assertEqual(hub.read_meta("r12")["name"], "Старое имя")
        code, data = self.enroll(cookie, label="r12", name="", most=True, reinstall=True)
        self.assertEqual(code, 200)
        self.assertEqual(hub.read_meta("r12")["name"], "Старое имя")
        self.assertIs(hub.read_meta("r12")["most"], True)

    def test_enroll_refuses_taken_label_with_metrics_only(self):
        self.post("/metrics/r16", b"x 1\n")
        self.assertEqual(self.enroll(self.session_cookie(), label="r16")[0], 409)

    def test_enroll_rejects_bad_input(self):
        cookie = self.session_cookie()
        self.assertEqual(self.enroll(cookie, label="bad label")[0], 400)
        self.assertEqual(self.enroll(cookie, label="r17", name="a\x00")[0], 400)
        self.assertEqual(self.enroll(cookie, label="r17", most="yes")[0], 400)
        self.assertFalse(os.path.exists(os.path.join(STATE, "meta-r17")))

    def test_mkenroll_unchanged(self):
        code, body = self.get("/mkenroll/r13")
        self.assertEqual(code, 200)
        self.assertTrue(body.startswith("uclient-fetch -4 -q -O- "))
        self.assertTrue(body.endswith("| sh\n"))

    def test_page_is_served_with_strict_headers(self):
        code, headers, body = self.ui("GET", "/")
        self.assertEqual(code, 200)
        self.assertEqual(headers["Content-Type"], "text/html; charset=utf-8")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        self.assertIn("ui/api/routers", body)

    def test_page_never_uses_innerhtml(self):
        text = UI_PAGE.read_text(encoding="utf-8")
        for banned in ("innerHTML", "outerHTML", "insertAdjacentHTML",
                       "document.write", "http://", "https://"):
            with self.subTest(banned=banned):
                self.assertNotIn(banned, text)

    def test_page_stops_polling_on_401(self):
        text = UI_PAGE.read_text(encoding="utf-8")
        for needed in ("stopPolling", "401", "archive_ts", "403", "404", "response.json()"):
            with self.subTest(needed=needed):
                self.assertIn(needed, text)

    def test_metrics_open_only_at_exact_path(self):
        self.assertEqual(self.get("/metrics", key="")[0], 200)
        self.assertEqual(self.get("/metrics/", key="")[0], 404)

    def test_login_is_capped_by_slots(self):
        for _ in range(2):
            self.assertTrue(hub._login_slots.acquire(blocking=False))
        try:
            code = self.ui("POST", "/ui/login", "password=pw-test")[0]
        finally:
            hub._login_slots.release()
            hub._login_slots.release()
        self.assertEqual(code, 404)
        self.assertEqual(self.ui("POST", "/ui/login", "password=pw-test")[0], 303)

    def test_import_does_not_create_state_dir(self):
        src = "import os; os.environ['HUB_STATE']='/nonexistent-x/y'; " \
              "import importlib.util as u; s=u.spec_from_file_location('h', %r); " \
              "m=u.module_from_spec(s); s.loader.exec_module(m); " \
              "print(os.path.exists('/nonexistent-x'))" % str(_src)
        out = subprocess.run([sys.executable, "-I", "-c", src], capture_output=True, text=True)
        self.assertEqual(out.stdout.strip(), "False", out.stderr)

    def test_page_is_off_without_password(self):
        old = hub.ADMIN_HASH
        try:
            hub.ADMIN_HASH = ""
            self.assertEqual(self.ui("GET", "/")[0], 404)
        finally:
            hub.ADMIN_HASH = old


if __name__ == "__main__":
    unittest.main()
