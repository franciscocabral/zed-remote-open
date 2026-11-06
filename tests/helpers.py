"""Shared test helpers: load the listener module, run a listener, send requests."""

import importlib.machinery
import importlib.util
import json
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LISTENER = ROOT / "local" / "zed-listener.pyw"
ZED_SCRIPT = ROOT / "remote" / "zed"
TOKEN = "test-token-0123456789abcdef"


def load_listener():
    loader = importlib.machinery.SourceFileLoader("zed_listener", str(LISTENER))
    spec = importlib.util.spec_from_loader("zed_listener", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def send(port: int, lines: list[str], count: int = 1, timeout: float = 5,
         during=None) -> list[str]:
    """Sends a request and returns the first COUNT response lines (fewer if
    the connection closes). DURING(sock) runs after the first line."""
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
        s.sendall(("\n".join(lines) + "\n").encode())
        reader = s.makefile(encoding="utf-8")
        out = []
        while len(out) < count:
            line = reader.readline()
            if not line:
                break
            out.append(line.rstrip("\n"))
            if len(out) == 1 and during:
                during(s)
        return out


def request(host: str, mode: str = "ping", token: str | None = None, paths=(), window=None,
            extra=()):
    lines = ["zro 2"]
    if token:
        lines.append(f"token {token}")
    lines += [f"host {host}", f"mode {mode}"]
    if window:
        lines.append(f"window {window}")
    lines += [f"path {line} {col} {path}" for line, col, path in paths]
    lines += list(extra)
    lines.append("end")
    return lines


class FakeZed:
    """A command (zed, ssh, a browser...) that writes its arguments to a file,
    one JSON list per call."""

    def __init__(self, directory: Path, name: str = "zed"):
        self.calls = directory / f"{name}-calls.jsonl"
        fake = Path(__file__).with_name("fake_zed.py")
        if sys.platform == "win32":
            self.path = directory / f"{name}.cmd"
            self.path.write_text(f'@"{sys.executable}" "{fake}" "{self.calls}" %*\r\n')
        else:
            self.path = directory / name
            command = f'exec "{sys.executable}" "{fake}" "{self.calls}" "$@"'
            self.path.write_text(f"#!/bin/sh\n{command}\n")
            self.path.chmod(0o755)

    def read(self, count: int, timeout: float = 5) -> list[list[str]]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.calls.exists():
                lines = self.calls.read_text().splitlines()
                if len(lines) >= count:
                    return [json.loads(line) for line in lines]
            time.sleep(0.05)
        raise AssertionError(f"{self.path.name} was not called {count} time(s)")


class RunningListener:
    """Starts the listener in a subprocess with a temporary configuration."""

    def __init__(self, hosts=("testhost",), token=None, extra=None):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.zed = FakeZed(self.dir)
        self.port = free_port()
        self.log = self.dir / "listener.log"
        config = {"port": self.port, "hosts": list(hosts), "zed_command": str(self.zed.path),
                  "log": str(self.log)}
        if token:
            config["token"] = token
        config.update(extra(self) if callable(extra) else extra or {})
        self.config = self.dir / "listener.json"
        self.config.write_text(json.dumps(config))
        self.proc = subprocess.Popen([sys.executable, str(LISTENER), "--config", str(self.config)])
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
                return
            except OSError:
                if self.proc.poll() is not None:
                    break
                time.sleep(0.1)
        self.close()
        raise RuntimeError(f"the listener did not start: {self.log_text()}")

    def log_text(self) -> str:
        return self.log.read_text() if self.log.exists() else ""

    def close(self):
        self.proc.kill()
        self.proc.wait()
        self.tmp.cleanup()
