"""End-to-end tests: the remote zed script sends requests to a real listener."""

import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from helpers import TOKEN, ZED_SCRIPT, RunningListener, load_listener


def bash_ok() -> bool:
    bash = shutil.which("bash")
    if sys.platform == "win32" or not bash:
        return False
    out = subprocess.run([bash, "-c", "echo ${BASH_VERSINFO[0]}"], capture_output=True, text=True)
    return out.stdout.strip().isdigit() and int(out.stdout) >= 4


VERSION = load_listener().__version__


@unittest.skipUnless(bash_ok(), "needs Bash 4 or later")
class RemoteZedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.listener = RunningListener(hosts=("testhost", "testhost.ts"), token=TOKEN)

    @classmethod
    def tearDownClass(cls):
        cls.listener.close()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.repo = self.home / "repo"
        (self.repo / "sub").mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        for name in ("a.md", "b.md", "sub/c.md"):
            (self.repo / name).write_text("x\n")
        self.env = {
            "HOME": str(self.home), "PATH": os.environ["PATH"],
            "ZED_SSH_HOST": "testhost", "ZED_LISTENER_PORT": str(self.listener.port),
            "ZED_LISTENER_TOKEN": TOKEN,
        }
        self.calls_before = self.count_calls()

    def tearDown(self):
        self.tmp.cleanup()

    def count_calls(self) -> int:
        calls = self.listener.zed.calls
        return len(calls.read_text().splitlines()) if calls.exists() else 0

    def zed(self, *args, stdin="", env=None, check=True):
        out = subprocess.run(["bash", str(ZED_SCRIPT), *args], cwd=self.repo, input=stdin,
                             capture_output=True, text=True, env={**self.env, **(env or {})},
                             timeout=30)
        if check and out.returncode != 0:
            self.fail(f"zed {args} failed: {out.stderr}")
        return out

    def last_call(self) -> list[str]:
        return self.listener.zed.read(self.calls_before + 1)[-1]

    def test_directory(self):
        self.zed()
        self.assertEqual(self.last_call(), ["--add", f"ssh://testhost{self.repo}"])

    def test_files_with_git_root_and_positions(self):
        self.zed("a.md:12", "sub/c.md:3:7", "b.md", "a.md:12")
        r = f"ssh://testhost{self.repo}"
        self.assertEqual(self.last_call(),
                         ["--add", r, f"{r}/a.md:12", f"{r}/sub/c.md:3:7", f"{r}/b.md"])

    def test_file_outside_git(self):
        other = self.home / "notes.txt"
        other.write_text("x")
        self.zed("-n", str(other))
        self.assertEqual(self.last_call(), ["--new", f"ssh://testhost{other}"])

    def test_stdin(self):
        out = self.zed("-", stdin="hello\n")
        url = self.last_call()[-1]
        path = Path(re.sub(r"^ssh://testhost", "", url))
        self.assertEqual(path.read_text(), "hello\n")
        self.assertIn(str(path), out.stdout)

    def test_wait_has_no_git_root(self):
        out = self.zed("-w", "a.md")
        self.assertEqual(self.last_call(), ["--wait", "--add", f"ssh://testhost{self.repo}/a.md"])
        self.assertIn("Waiting", out.stdout)

    def test_window_setting(self):
        self.zed("-c", "window:new")
        self.zed("a.md")
        self.assertEqual(self.last_call()[0], "--new")
        self.zed("-a", "a.md")
        self.assertEqual(self.listener.zed.read(self.calls_before + 2)[-1][0], "--add")

    def test_settings_file_is_private(self):
        self.zed("-c", f"token:{TOKEN}", "-c", "port:7700", "-c", "host:testhost")
        settings = self.home / ".config" / "zed-remote-open" / "settings.json"
        self.assertEqual(stat.S_IMODE(settings.stat().st_mode), 0o600)
        self.assertIn('"port": 7700', settings.read_text())
        self.zed("-c", "token:")
        self.assertNotIn("token", settings.read_text())

    def test_errors(self):
        cases = [
            (["-h", "evil", "a.md"], "host 'evil' is not allowed"),
            (["a.md"], "invalid token", {"ZED_LISTENER_TOKEN": "wrong-token-123456"}),
            (["-p", "1", "a.md"], "cannot connect to the listener"),
            (["-c", "window:big"], "'big' is not a valid window"),
            (["-x"], "unknown option -x"),
            (["--nope"], "unknown option --nope"),
            (["missing.md"], "no path to open"),
        ]
        for args, message, *env in cases:
            with self.subTest(args):
                out = self.zed(*args, env=env[0] if env else None, check=False)
                self.assertNotEqual(out.returncode, 0)
                self.assertIn(message, out.stderr)

    def test_doctor(self):
        out = self.zed("--doctor", env={"PATH": f"{ZED_SCRIPT.parent}:{os.environ['PATH']}"})
        self.assertIn(f"accepts host 'testhost' (version {VERSION})", out.stdout)
        self.assertIn("token   set", out.stdout)
        self.assertNotIn(TOKEN, out.stdout)
        bad = self.zed("--doctor", "-p", "1", check=False)
        self.assertEqual(bad.returncode, 1)
        self.assertIn("[fail]", bad.stdout)

    def test_version(self):
        self.assertEqual(self.zed("--version").stdout.strip(), f"zed-remote-open {VERSION}")


if __name__ == "__main__":
    unittest.main()
