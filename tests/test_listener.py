"""Tests of the listener: configuration, protocol and zed command line."""

import json
import socket
import sqlite3
import tempfile
import threading
import time
import unittest
from contextlib import closing
from pathlib import Path

from helpers import (
    TOKEN,
    ZED_SCHEMA,
    FakeZed,
    RunningListener,
    load_listener,
    request,
    send,
    zed_close_tab,
    zed_open_tab,
)

zl = load_listener()


def config(**changes):
    values = dict(port=7682, hosts=frozenset({"srv", "srv.ts"}), token=None, zed="zed",
                  log=Path("x.log"))
    values.update(changes)
    return zl.Config(**values)


class ParseRequestTest(unittest.TestCase):
    def parse(self, lines, cfg=None):
        return zl.parse_request(lines, cfg or config())

    def test_open_with_positions(self):
        req = self.parse(["zro 2", "host srv", "path 0 0 /a", "path 12 3 /a/b c.txt", ""])
        self.assertEqual(req.mode, "open")
        self.assertEqual(req.paths, [(0, 0, "/a"), (12, 3, "/a/b c.txt")])

    def test_ping_needs_no_path(self):
        self.assertEqual(self.parse(["zro 2", "host srv", "mode ping"]).mode, "ping")

    def test_rejects(self):
        cases = {
            "unsupported protocol": ["zro 1", "host srv", "path 0 0 /a"],
            "host 'evil' is not allowed": ["zro 2", "host evil", "path 0 0 /a"],
            "invalid path line": ["zro 2", "host srv", "path 0 0 relative"],
            "unknown line": ["zro 2", "host srv", "option --foo", "path 0 0 /a"],
            "more than one 'host'": ["zro 2", "host srv", "host srv", "path 0 0 /a"],
            "invalid mode": ["zro 2", "host srv", "mode exec", "path 0 0 /a"],
            "no path": ["zro 2", "host srv"],
        }
        for message, lines in cases.items():
            with self.subTest(message), self.assertRaisesRegex(zl.BadRequest, message):
                self.parse(lines)

    def test_browse(self):
        req = self.parse(["zro 2", "host srv", "mode browse", "url https://example.com/a?b=1"])
        self.assertEqual(req.url, "https://example.com/a?b=1")
        for url in ("file:///etc/passwd", "javascript:alert(1)", "https://", "http://a b",
                    "https://x/\x07", "ftp://x"):
            with self.subTest(url), self.assertRaisesRegex(zl.BadRequest, "invalid URL"):
                self.parse(["zro 2", "host srv", "mode browse", f"url {url}"])
        with self.assertRaisesRegex(zl.BadRequest, "takes no path"):
            self.parse(["zro 2", "host srv", "mode browse", "url https://x", "path 0 0 /a"])

    def test_notify(self):
        req = self.parse(["zro 2", "host srv", "mode notify", "message build done"])
        self.assertEqual(req.message, "build done")
        for lines, message in ((["message "], "invalid message"),
                               ([f"message {'x' * 1001}"], "invalid message"),
                               (["message a\x1bb"], "invalid message"),
                               (["message a", f"title {'t' * 201}"], "invalid title")):
            with self.subTest(lines), self.assertRaisesRegex(zl.BadRequest, message):
                self.parse(["zro 2", "host srv", "mode notify", *lines])

    def test_token(self):
        cfg = config(token=TOKEN)
        self.parse(["zro 2", f"token {TOKEN}", "host srv", "path 0 0 /a"], cfg)
        for lines in (["zro 2", "host srv", "path 0 0 /a"],
                      ["zro 2", "token wrong-token-123456", "host srv", "path 0 0 /a"]):
            with self.assertRaisesRegex(zl.BadRequest, "invalid token"):
                self.parse(lines, cfg)


class BuildCommandTest(unittest.TestCase):
    def test_urls_and_options(self):
        req = zl.Request("srv", "wait", None,
                         [(0, 0, "/r"), (5, 0, "/r/a b.ts"), (5, 2, "/r/x:1")])
        # One call for each URL, with no option: Zed selects the window itself.
        self.assertEqual(zl.build_commands(config(), req), [
            ["zed", "ssh://srv/r"],
            ["zed", "ssh://srv/r/a%20b.ts:5"],
            ["zed", "ssh://srv/r/x%3A1:5:2"],
        ])

    def test_window_line_is_ignored(self):
        """zed 1.1.0 sends "window current"; the listener accepts it."""
        req = zl.parse_request(["zro 2", "host srv", "window new", "path 0 0 /r"], config())
        self.assertEqual(zl.build_commands(config(), req), [["zed", "ssh://srv/r"]])

    def test_too_many_paths(self):
        lines = ["zro 2", "host srv"] + [f"path 0 0 /p{i}" for i in range(101)]
        with self.assertRaisesRegex(zl.BadRequest, "more than 100 paths"):
            zl.parse_request(lines, config())


class LoadConfigTest(unittest.TestCase):
    def load(self, data):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "c.json"
            path.write_text(json.dumps(data), encoding="utf-8-sig")  # A BOM is accepted.
            return zl.load_config(path)

    def test_valid(self):
        cfg = self.load({"hosts": ["srv"], "token": TOKEN, "zed_command": zl.__file__})
        self.assertEqual((cfg.port, cfg.hosts, cfg.token), (7682, frozenset({"srv"}), TOKEN))

    def test_invalid(self):
        for data in ({"hosts": []}, {"hosts": ["a b"]}, {"hosts": ["a"], "port": 0},
                     {"hosts": ["a"], "port": True}, {"hosts": ["a"], "token": "short"},
                     {"hosts": ["a"], "zed_command": "/does/not/exist"},
                     {"hosts": ["a"], "tunnel_hosts": "a"}, {"hosts": ["a"], "wait_close": 1}):
            with self.subTest(data), self.assertRaises(zl.ConfigError):
                self.load(data)


class ListenerProcessTest(unittest.TestCase):
    """Runs the listener in a subprocess and sends real requests."""

    @classmethod
    def setUpClass(cls):
        cls.listener = RunningListener(hosts=("testhost",), token=TOKEN)

    @classmethod
    def tearDownClass(cls):
        cls.listener.close()

    def test_ping(self):
        out = send(self.listener.port, request("testhost", token=TOKEN))
        self.assertEqual(out, [f"OK {zl.__version__}"])

    def test_wait_without_close_detection(self):
        port = self.listener.port
        out = send(port, request("testhost", "wait", TOKEN, [(3, 0, "/tmp/a")]), count=3)
        self.assertEqual(out, [f"OK {zl.__version__}", "WAIT save"])
        calls = self.listener.zed.read(1)
        self.assertEqual(calls[-1], ["ssh://testhost/tmp/a:3"])

    def test_rejected(self):
        out = send(self.listener.port, request("testhost", token="wrong-token-123456"))
        self.assertEqual(out, ["ERR invalid token"])
        self.assertNotIn("wrong-token", self.listener.log_text())

    def test_too_large(self):
        out = send(self.listener.port, ["zro 2", "x" * 70_000])
        self.assertEqual(out[0], "ERR request is larger than 65536 bytes")

    def test_timeout(self):
        with socket.create_connection(("127.0.0.1", self.listener.port)) as s:
            s.sendall(b"zro 2\n")
            s.settimeout(10)
            self.assertEqual(s.makefile().readline().strip(), "ERR timeout")


class ListenerFeaturesTest(unittest.TestCase):
    """Browse, notify, the experimental close detection and the managed tunnel."""

    @classmethod
    def setUpClass(cls):
        def extra(listener):
            cls.browser = FakeZed(listener.dir, "browser")
            cls.notifier = FakeZed(listener.dir, "notifier")
            cls.ssh = FakeZed(listener.dir, "ssh")
            cls.db = listener.dir / "zed-db.sqlite"
            with closing(sqlite3.connect(cls.db)) as con, con:
                con.executescript(ZED_SCHEMA)
            return {"browser_command": str(cls.browser.path),
                    "notify_command": str(cls.notifier.path),
                    "ssh_command": str(cls.ssh.path), "tunnel_hosts": ["testhost"],
                    "wait_close": True, "zed_db": str(cls.db)}
        cls.listener = RunningListener(hosts=("testhost",), extra=extra)

    @classmethod
    def tearDownClass(cls):
        cls.listener.close()

    def test_browse(self):
        out = send(self.listener.port, request(
            "testhost", "browse", extra=["url https://example.com/login?x=1"]))
        self.assertEqual(out, [f"OK {zl.__version__}"])
        self.assertEqual(self.browser.read(1)[-1], ["https://example.com/login?x=1"])

    def test_notify(self):
        out = send(self.listener.port, request("testhost", "notify", extra=["message done: 0"]))
        self.assertEqual(out, [f"OK {zl.__version__}"])
        self.assertEqual(self.notifier.read(1)[-1], ["zed-remote-open: testhost", "done: 0"])

    def test_wait_close(self):
        """The tab of the file opens (a row in the database), then closes."""
        def edit(_sock):
            time.sleep(1)
            zed_open_tab(self.db, "/srv/repo/COMMIT_EDITMSG")
            time.sleep(1.5)
            zed_close_tab(self.db)

        started = time.monotonic()
        out = send(self.listener.port, request(
            "testhost", "wait", paths=[(0, 0, "/srv/repo/COMMIT_EDITMSG")]),
            count=3, timeout=20, during=lambda s: threading.Thread(target=edit, args=(s,)).start())
        self.assertEqual(out, [f"OK {zl.__version__}", "WAIT close", "DONE 0"])
        self.assertGreater(time.monotonic() - started, 2.5)

    def test_tunnel_reconnects(self):
        """The fake ssh stops at once: the listener starts it again."""
        calls = self.ssh.read(2, timeout=15)
        port = self.listener.port
        self.assertIn("-N", calls[0])
        self.assertIn(f"127.0.0.1:{port}:127.0.0.1:{port}", calls[0])
        self.assertEqual(calls[0][-1], "testhost")
        self.assertIn("Tunnel testhost: ended", self.listener.log_text())


if __name__ == "__main__":
    unittest.main()
