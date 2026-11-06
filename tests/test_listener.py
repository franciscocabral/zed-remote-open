"""Tests of the listener: configuration, protocol and zed command line."""

import json
import socket
import tempfile
import unittest
from pathlib import Path

from helpers import TOKEN, RunningListener, load_listener, request, send

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
        self.assertEqual(req.window, "current")
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
            "invalid window": ["zro 2", "host srv", "window x", "path 0 0 /a"],
            "no path": ["zro 2", "host srv"],
        }
        for message, lines in cases.items():
            with self.subTest(message), self.assertRaisesRegex(zl.BadRequest, message):
                self.parse(lines)

    def test_token(self):
        cfg = config(token=TOKEN)
        self.parse(["zro 2", f"token {TOKEN}", "host srv", "path 0 0 /a"], cfg)
        for lines in (["zro 2", "host srv", "path 0 0 /a"],
                      ["zro 2", "token wrong-token-123456", "host srv", "path 0 0 /a"]):
            with self.assertRaisesRegex(zl.BadRequest, "invalid token"):
                self.parse(lines, cfg)


class BuildCommandTest(unittest.TestCase):
    def test_urls_and_options(self):
        req = zl.Request("srv", "wait", "new", None,
                         [(0, 0, "/r"), (5, 0, "/r/a b.ts"), (5, 2, "/r/x:1")])
        self.assertEqual(zl.build_command(config(), req), [
            "zed", "--wait", "--new", "ssh://srv/r", "ssh://srv/r/a%20b.ts:5",
            "ssh://srv/r/x%3A1:5:2",
        ])

    def test_current_window(self):
        req = zl.Request("srv", "open", "current", None, [(0, 0, "/r")])
        self.assertEqual(zl.build_command(config(), req), ["zed", "--add", "ssh://srv/r"])


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
                     {"hosts": ["a"], "zed_command": "/does/not/exist"}):
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

    def test_open_and_wait(self):
        port = self.listener.port
        out = send(port, request("testhost", "wait", TOKEN, [(3, 0, "/tmp/a")]), wait_done=True)
        self.assertEqual(out, [f"OK {zl.__version__}", "DONE 0"])
        calls = self.listener.zed.read(1)
        self.assertEqual(calls[-1], ["--wait", "--add", "ssh://testhost/tmp/a:3"])

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


if __name__ == "__main__":
    unittest.main()
