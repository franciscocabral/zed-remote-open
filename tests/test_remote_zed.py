"""End-to-end tests: the remote zed script sends requests to a real listener."""

import os
import re
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import closing
from pathlib import Path

from helpers import (
    TOKEN,
    ZED_SCHEMA,
    ZED_SCRIPT,
    FakeZed,
    RunningListener,
    load_listener,
    zed_close_tab,
    zed_open_tab,
)


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
        def extra(listener):
            cls.browser = FakeZed(listener.dir, "browser")
            cls.notifier = FakeZed(listener.dir, "notifier")
            return {"browser_command": str(cls.browser.path),
                    "notify_command": str(cls.notifier.path)}
        cls.listener = RunningListener(hosts=("testhost", "testhost.ts"), token=TOKEN,
                                       extra=extra)

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

    def new_calls(self, count: int) -> list[list[str]]:
        """The zed calls of this test (one call for each URL, in sequence)."""
        return self.listener.zed.read(self.calls_before + count)[self.calls_before:]

    def last_call(self) -> list[str]:
        return self.new_calls(1)[-1]

    def test_directory(self):
        self.zed()
        self.assertEqual(self.last_call(), [f"ssh://testhost{self.repo}"])

    def test_files_with_positions(self):
        """Only the files, one call each (no Git root), with no duplicates."""
        out = self.zed("a.md:12", "sub/c.md:3:7", "b.md", "a.md:12")
        self.assertIn(f"Opening Zed at {self.repo}/sub/c.md:3:7\n", out.stdout)
        r = f"ssh://testhost{self.repo}"
        self.assertEqual(self.new_calls(3),
                         [[f"{r}/a.md:12"], [f"{r}/sub/c.md:3:7"], [f"{r}/b.md"]])

    def test_file_outside_git(self):
        other = self.home / "notes.txt"
        other.write_text("x")
        self.zed(str(other))
        self.assertEqual(self.last_call(), [f"ssh://testhost{other}"])

    def test_no_window_options(self):
        """-n and -a are gone: Zed selects the window itself."""
        for option in ("-n", "-a"):
            out = self.zed(option, "a.md", check=False)
            self.assertIn(f"unknown option {option}", out.stderr)

    def test_stdin(self):
        out = self.zed("-", stdin="hello\n")
        url = self.last_call()[-1]
        path = Path(re.sub(r"^ssh://testhost", "", url))
        self.assertEqual(path.read_text(), "hello\n")
        self.assertIn(str(path), out.stdout)

    def start_wait(self, name: str) -> subprocess.Popen:
        """Starts "zed -w NAME" with no terminal (no /dev/tty: no Enter key)."""
        proc = subprocess.Popen(["bash", str(ZED_SCRIPT), "-w", name], cwd=self.repo,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, env=self.env,
                                start_new_session=True)
        self.addCleanup(proc.kill)
        return proc

    def test_wait_ends_at_the_save(self):
        proc = self.start_wait("a.md")
        self.assertEqual(self.new_calls(1), [[f"ssh://testhost{self.repo}/a.md"]])
        time.sleep(1)
        self.assertIsNone(proc.poll(), "zed -w returned before the save")
        (self.repo / "a.md").write_text("edited\n")  # The user saves in Zed.
        out, _ = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 0)
        self.assertIn(f"Saved: {self.repo}/a.md", out)

    def test_wait_cancel(self):
        proc = self.start_wait("b.md")
        self.last_call()
        time.sleep(1)
        proc.send_signal(signal.SIGINT)
        _, err = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("cancelled", err)

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
            (["-p", "1", "a.md"], "nothing listens on this port of the server"),
            (["-c", "window:new"], "unknown key 'window'"),
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

    def test_browse(self):
        url = "https://example.com/device?code=AB-12"
        out = self.zed("--browse", url)
        self.assertIn(url, out.stdout)
        self.assertEqual(self.browser.read(1)[-1], [url])
        # "zed-browse URL" through a link, as for BROWSER=zed-browse.
        link = self.home / "zed-browse"
        link.symlink_to(ZED_SCRIPT)
        subprocess.run(["bash", str(link), "http://localhost:8080/"], check=True,
                       capture_output=True, env=self.env, timeout=30)
        self.assertEqual(self.browser.read(2)[-1], ["http://localhost:8080/"])
        bad = self.zed("--browse", "file:///etc/passwd", check=False)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("not an http:// or https:// URL", bad.stderr)

    def test_notify(self):
        self.zed("--notify", "build", "finished")
        self.assertEqual(self.notifier.read(1)[-1], ["zed-remote-open: testhost", "build finished"])
        self.zed("--notify", stdin="line 1\nline 2\tend\n")
        self.assertEqual(self.notifier.read(2)[-1][1], "line 1 line 2 end")
        self.assertIn("needs a message", self.zed("--notify", check=False).stderr)

    def test_completion(self):
        for shell in ("bash", "zsh"):
            with self.subTest(shell):
                out = self.zed("--completion", shell).stdout
                self.assertIn("_zed_remote_open", out)
                if shutil.which(shell):
                    subprocess.run([shell, "-n"], input=out, text=True, check=True)

    @unittest.skipUnless(
        subprocess.run(["script", "--version"], capture_output=True).returncode == 0
        if shutil.which("script") else False, "needs the script command of util-linux")
    def test_uninstall_removes_the_browse_link(self):
        """zed --uninstall (it needs a terminal: "script" gives it one)."""
        bin_dir = self.home / ".local" / "bin"
        bin_dir.mkdir(parents=True)
        installed = bin_dir / "zed"
        installed.write_text(ZED_SCRIPT.read_text())
        installed.chmod(0o755)
        (bin_dir / "zed-browse").symlink_to("zed")
        self.zed("-c", "port:7700")
        out = subprocess.run(["script", "-qec", f"{installed} --uninstall", "/dev/null"],
                             input="y\n", capture_output=True, text=True, env=self.env,
                             timeout=30)
        self.assertIn("Removed.", out.stdout)
        self.assertFalse(installed.exists())
        self.assertFalse((bin_dir / "zed-browse").is_symlink())
        self.assertFalse((self.home / ".config" / "zed-remote-open").exists())

    def test_version(self):
        self.assertEqual(self.zed("--version").stdout.strip(), f"zed-remote-open {VERSION}")


@unittest.skipUnless(bash_ok(), "needs Bash 4 or later")
class WaitCloseTest(unittest.TestCase):
    """zed -w with the experimental close detection of the listener."""

    def test_close_ends_the_wait(self):
        db_dir = tempfile.TemporaryDirectory()
        self.addCleanup(db_dir.cleanup)
        db = Path(db_dir.name) / "db.sqlite"
        with closing(sqlite3.connect(db)) as con, con:
            con.executescript(ZED_SCHEMA)
        listener = RunningListener(extra={"wait_close": True, "zed_db": str(db)})
        self.addCleanup(listener.close)
        home = Path(db_dir.name) / "home"
        home.mkdir()
        target = home / "COMMIT_EDITMSG"
        target.write_text("\n")
        env = {"HOME": str(home), "PATH": os.environ["PATH"], "ZED_SSH_HOST": "testhost",
               "ZED_LISTENER_PORT": str(listener.port)}
        proc = subprocess.Popen(["bash", str(ZED_SCRIPT), "-w", str(target)], env=env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(proc.kill)
        listener.zed.read(1)
        zed_open_tab(db, str(target))  # Zed opens the tab.
        time.sleep(1.5)
        self.assertIsNone(proc.poll(), "zed -w returned before the tab closed")
        zed_close_tab(db)  # The user closes the tab, with no save.
        out, err = proc.communicate(timeout=15)
        self.assertEqual(proc.returncode, 0, err)
        self.assertIn("Close the tab or save the file", out)
        self.assertIn("Closed in Zed.", out)


if __name__ == "__main__":
    unittest.main()
