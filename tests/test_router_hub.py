#!/usr/bin/env python3
"""Live requests against router-hub.py on a random port."""

import importlib.util
import os
import pathlib
import tempfile
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
_spec = importlib.util.spec_from_file_location("router_hub", _src)
hub = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hub)


class HubTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
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
            return err.code, err.read().decode()

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


if __name__ == "__main__":
    unittest.main()
