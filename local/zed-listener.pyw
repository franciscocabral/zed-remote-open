"""zed-remote-open listener: opens Zed remote projects for requests that come
through an SSH reverse tunnel.

Usage: zed-listener.pyw [--config PATH]

Protocol "zro 2". One TCP connection on 127.0.0.1 = one request:

    zro 2
    token <token>                      only if the listener has a token
    host <ssh host>
    mode open|wait|ping|browse|notify  optional, default open
    window current|new                 optional, default current
    path <line> <column> <absolute path>    open, wait: one or more (0 = no position)
    url <http or https URL>            browse: the URL to open in the browser
    title <text>                       notify: optional
    message <text>                     notify: the text of the notification
    end

The listener sends one response line: "OK <version>" or "ERR <message>".
For mode "wait", it then sends "WAIT close" (it reports when the tabs close,
then sends "DONE 0") or "WAIT save" (the client waits for a save).

The Zed CLI opens only one ssh:// URL in each call, so the listener runs zed
one time for each path, in sequence (the project before its files).

With "tunnel_hosts" in the configuration, the listener also keeps an SSH
connection to each of these hosts with the reverse forward of its port, and
reconnects when the connection stops.
"""

import argparse
import atexit
import base64
import hmac
import json
import logging
import logging.handlers
import os
import re
import select
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import webbrowser
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote, urlsplit

__version__ = "1.1.0"

PROTOCOL = "zro 2"
DEFAULT_PORT = 7682
MAX_REQUEST_BYTES = 64 * 1024
REQUEST_TIMEOUT = 5.0  # seconds, for the full request
MAX_CLIENTS = 16
MAX_PATHS = 100
MAX_URL = 4096
MAX_TITLE = 200
MAX_MESSAGE = 1000
ZED_CALL_TIMEOUT = 60.0  # seconds for one zed call before the next one starts
CLOSE_APPEAR_TIMEOUT = 20.0  # seconds for the files to appear in the Zed database
HOST_RE = re.compile(r"[A-Za-z0-9._-]+")
TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{16,256}")
PATH_RE = re.compile(r"(\d{1,9}) (\d{1,9}) (/.*)")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)  # Windows only


class BadRequest(Exception):
    pass


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Config:
    port: int
    hosts: frozenset
    token: str | None
    zed: str
    log: Path
    tunnel_hosts: tuple = ()
    ssh: str | None = None
    wait_close: bool = False
    zed_db: Path | None = None
    browser_command: str | None = None
    notify_command: str | None = None


@dataclass
class Request:
    host: str
    mode: str = "open"
    window: str = "current"
    token: str | None = None
    paths: list = field(default_factory=list)  # (line, column, absolute path)
    url: str = ""
    title: str = ""
    message: str = ""


# --- Configuration ---


def data_dir() -> Path:
    """Directory of the listener files for this operating system."""
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / "zed-remote-open"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "zed-remote-open"
    base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(base) / "zed-remote-open"


def find_command(value: str | None, names: tuple, key: str) -> str:
    if value:
        found = value if Path(value).is_file() else shutil.which(value)
        if not found:
            raise ConfigError(f"{key} {value!r} does not exist")
        return found
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    raise ConfigError(f"the {names[0]} command is not in PATH (set {key})")


def zed_database() -> Path | None:
    """The Zed database with the open tabs (the most recently changed channel)."""
    if sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local") / "Zed"
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support" / "Zed"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "zed"
    found = sorted(base.glob("db/*/db.sqlite"), key=lambda p: p.stat().st_mtime, reverse=True)
    return found[0] if found else None


def load_config(path: Path) -> Config:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        raise ConfigError(f"{path} does not exist") from None
    except (OSError, ValueError) as e:
        raise ConfigError(f"cannot read {path}: {e}") from None
    if not isinstance(data, dict):
        raise ConfigError("the configuration must be a JSON object")

    port = data.get("port", DEFAULT_PORT)
    if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
        raise ConfigError(f"invalid port: {port!r}")

    def host_list(key: str, required: bool) -> list:
        value = data.get(key, None if required else [])
        if (
            not isinstance(value, list)
            or (required and not value)
            or not all(isinstance(h, str) and HOST_RE.fullmatch(h) for h in value)
        ):
            raise ConfigError(f"invalid {key}: {value!r}")
        return value

    hosts = host_list("hosts", True)
    tunnel_hosts = host_list("tunnel_hosts", False)

    token = data.get("token") or None
    if token is not None and not (isinstance(token, str) and TOKEN_RE.fullmatch(token)):
        raise ConfigError("invalid token (use 16 to 256 letters, digits, '_' or '-')")

    wait_close = data.get("wait_close", False)
    if not isinstance(wait_close, bool):
        raise ConfigError(f"invalid wait_close: {wait_close!r}")

    log = Path(data["log"]) if data.get("log") else data_dir() / "listener.log"
    ssh = find_command(data.get("ssh_command"), ("ssh",), "ssh_command") if tunnel_hosts else None
    optional = {}
    for key in ("browser_command", "notify_command"):
        if data.get(key):
            optional[key] = find_command(data[key], (data[key],), key)
    return Config(
        port, frozenset(hosts), token,
        find_command(data.get("zed_command"), ("zed", "zeditor"), "zed_command"),
        log, tuple(tunnel_hosts), ssh, wait_close,
        Path(data["zed_db"]) if data.get("zed_db") else None,
        **optional,
    )


# --- Requests ---


def read_request(conn: socket.socket) -> list[str]:
    """Reads the lines before the "end" line. Stops at the size limit or at the deadline."""
    deadline = time.monotonic() + REQUEST_TIMEOUT
    data = bytearray()
    while True:
        end = (b"\n" + data).find(b"\nend\n")
        if end >= 0:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise BadRequest("timeout")
        conn.settimeout(remaining)
        try:
            chunk = conn.recv(4096)
        except TimeoutError:
            raise BadRequest("timeout") from None
        if not chunk:
            raise BadRequest("incomplete request (no 'end' line)")
        data += chunk
        if len(data) > MAX_REQUEST_BYTES:
            raise BadRequest(f"request is larger than {MAX_REQUEST_BYTES} bytes")
    try:
        text = bytes(data[:end]).decode("utf-8")
    except UnicodeDecodeError:
        raise BadRequest("request is not valid UTF-8") from None
    return [line.rstrip("\r") for line in text.split("\n")]


def valid_url(url: str) -> bool:
    if not url or len(url) > MAX_URL or CONTROL_RE.search(url) or " " in url:
        return False
    parts = urlsplit(url)
    return parts.scheme in ("http", "https") and bool(parts.netloc)


def parse_request(lines: list[str], cfg: Config) -> Request:
    """Validates the request. Rejects the full request if one line is not valid."""
    if not lines or lines[0] != PROTOCOL:
        raise BadRequest("unsupported protocol: install the same version on both computers")
    values: dict[str, str] = {}
    paths = []
    for line in lines[1:]:
        if not line:
            continue
        key, _, value = line.partition(" ")
        if key == "path":
            m = PATH_RE.fullmatch(value)
            if not m:
                raise BadRequest(f"invalid path line {line!r}")
            paths.append((int(m[1]), int(m[2]), m[3]))
        elif key in ("token", "host", "mode", "window", "url", "title", "message"):
            if key in values:
                raise BadRequest(f"more than one {key!r} line")
            values[key] = value
        else:
            raise BadRequest(f"unknown line {line!r}")

    if cfg.token and not hmac.compare_digest(
        values.get("token", "").encode(), cfg.token.encode()
    ):
        raise BadRequest("invalid token")
    host = values.get("host", "")
    if host not in cfg.hosts:
        raise BadRequest(f"host {host!r} is not allowed")
    req = Request(host, values.get("mode", "open"), values.get("window", "current"), None,
                  paths, values.get("url", ""), values.get("title", ""),
                  values.get("message", ""))
    if req.mode not in ("open", "wait", "ping", "browse", "notify"):
        raise BadRequest(f"invalid mode {req.mode!r}: update the listener")
    if req.window not in ("current", "new"):
        raise BadRequest(f"invalid window {req.window!r}")
    if req.mode in ("open", "wait"):
        if not paths:
            raise BadRequest("no path")
        if len(paths) > MAX_PATHS:
            raise BadRequest(f"more than {MAX_PATHS} paths")
    elif paths:
        raise BadRequest(f"mode {req.mode!r} takes no path")
    if req.mode == "browse" and not valid_url(req.url):
        raise BadRequest("invalid URL (only http:// and https://)")
    if req.mode == "notify":
        if not req.message or len(req.message) > MAX_MESSAGE or CONTROL_RE.search(req.message):
            raise BadRequest(f"invalid message (1 to {MAX_MESSAGE} characters)")
        if len(req.title) > MAX_TITLE or CONTROL_RE.search(req.title):
            raise BadRequest(f"invalid title (at most {MAX_TITLE} characters)")
    return req


def build_commands(cfg: Config, req: Request) -> list[list[str]]:
    """Returns one zed command line for each path. The Zed CLI opens only one
    ssh:// URL in each call: with two, it stops with "cannot open both local
    and ssh paths". The user cannot add other options."""
    commands = []
    for i, (line, column, path) in enumerate(req.paths):
        url = f"ssh://{req.host}{quote(path)}"
        if line:
            url += f":{line}" + (f":{column}" if column else "")
        args = [cfg.zed]
        # "new" only on the first call: the next calls go to the window of the
        # project. "current" adds no option, and Zed uses the window of the
        # project if it is open.
        if req.window == "new" and i == 0:
            args.append("--new")
        args.append(url)
        commands.append(args)
    return commands


def redact(lines: list[str]) -> list[str]:
    return ["token ***" if line.startswith("token ") else line for line in lines]


def send(conn: socket.socket, text: str) -> None:
    try:
        conn.sendall(f"{text}\n".encode())
    except OSError:
        pass  # The client went away.


def handle(conn: socket.socket, cfg: Config) -> None:
    lines: list[str] = []
    try:
        lines = read_request(conn)
        req = parse_request(lines, cfg)
    except BadRequest as e:
        logging.warning("Rejected request (%s): %r", e, redact(lines)[:20])
        send(conn, f"ERR {e}")
        return

    if req.mode == "ping":
        logging.info("Ping from host %s", req.host)
        send(conn, f"OK {__version__}")
    elif req.mode == "browse":
        handle_browse(conn, cfg, req)
    elif req.mode == "notify":
        handle_notify(conn, cfg, req)
    else:
        handle_open(conn, cfg, req)


# --- Open and wait ---


def handle_open(conn: socket.socket, cfg: Config, req: Request) -> None:
    commands = build_commands(cfg, req)
    try:
        first = ZedProcess(commands[0])
    except OSError as e:
        logging.error("Cannot run %s: %s", cfg.zed, e)
        send(conn, f"ERR cannot run zed: {e}")
        return
    send(conn, f"OK {__version__}")
    if req.mode == "wait":
        # The Zed CLI cannot wait for remote files (--wait ends at once for
        # ssh:// URLs). The client waits for a save; the listener can also
        # report when the tabs close (experimental: "wait_close").
        db = (cfg.zed_db or zed_database()) if cfg.wait_close else None
        send(conn, "WAIT close" if db else "WAIT save")
        run_in_sequence(first, commands[1:])
        if db is None:
            return
        conn.settimeout(None)
        if wait_for_close(conn, db, [path for _, _, path in req.paths]):
            send(conn, "DONE 0")
        else:
            send(conn, "WAIT save")
    else:
        threading.Thread(target=run_in_sequence, args=(first, commands[1:]),
                         daemon=True).start()


def run_in_sequence(first: "ZedProcess", rest: list[list[str]]) -> None:
    """Runs the next zed command after the one before it ends, so that the
    project window exists before its files open."""
    first.wait(ZED_CALL_TIMEOUT)
    for args in rest:
        try:
            ZedProcess(args).wait(ZED_CALL_TIMEOUT)
        except OSError as e:
            logging.error("Cannot run %s: %s", args[0], e)
            return


class ZedProcess:
    """A running command. Its output goes to a temporary file, not to a pipe:
    the Zed application that the CLI starts can keep a pipe open, and the
    listener would wait for it."""

    def __init__(self, args: list[str], env: dict | None = None):
        logging.info("Running %s", " ".join(args))
        self.output = tempfile.TemporaryFile()
        try:
            self.proc = subprocess.Popen(
                args,
                stdin=subprocess.DEVNULL,
                stdout=self.output,
                stderr=subprocess.STDOUT,
                creationflags=NO_WINDOW,
                env=env,
            )
        except OSError:
            self.output.close()
            raise

    def wait(self, timeout: float | None = None) -> int:
        """Waits for the command and writes its exit code and output to the log."""
        try:
            code = self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            logging.warning("The command did not end in %d seconds; the next one starts", timeout)
            threading.Thread(target=self.wait, daemon=True).start()
            return 0
        try:
            self.output.seek(0)
            text = self.output.read(4000).decode("utf-8", errors="replace").strip()
        except OSError:
            text = ""
        finally:
            self.output.close()
        if code:
            logging.warning("Exit code %d. Output: %s", code, text or "(none)")
        else:
            logging.info("Exit code 0%s", f". Output: {text}" if text else "")
        return code


class ZedTabs:
    """Experimental: finds the open tabs of a file in the Zed database.

    The tables of this database are internal to Zed and can change. So the
    search is general: it counts the rows of each "path" column that contain
    the path of the file."""

    def __init__(self, db: Path):
        self.uri = f"{db.resolve().as_uri()}?mode=ro"
        self.columns: list[tuple[str, str]] | None = None

    def count(self, paths: list[str]) -> int | None:
        try:
            with sqlite3.connect(self.uri, uri=True, timeout=2) as con:
                if self.columns is None:
                    tables = [t for (t,) in con.execute(
                        "SELECT name FROM sqlite_master WHERE type = 'table'")]
                    self.columns = [
                        (table, col)
                        for table in tables
                        for (_, col, *_rest) in con.execute(f'PRAGMA table_info("{table}")')
                        if "path" in col.lower()
                    ]
                total = 0
                for table, col in self.columns:
                    for path in paths:
                        total += con.execute(
                            f'SELECT COUNT(*) FROM "{table}" '
                            f'WHERE instr(CAST("{col}" AS TEXT), ?) > 0', (path,)
                        ).fetchone()[0]
                return total
        except sqlite3.Error as e:
            logging.warning("Cannot read the Zed database: %s", e)
            return None


def client_gone(conn: socket.socket) -> bool:
    try:
        readable, _, _ = select.select([conn], [], [], 0)
        return bool(readable) and conn.recv(1, socket.MSG_PEEK) == b""
    except OSError:
        return True


def wait_for_close(conn: socket.socket, db: Path, paths: list[str]) -> bool:
    """Returns True when the tabs of the files close. Returns False if the
    files do not appear in the Zed database (then the client waits for a save)."""
    tabs = ZedTabs(db)
    deadline = time.monotonic() + CLOSE_APPEAR_TIMEOUT
    while True:
        count = tabs.count(paths)
        if count:
            break
        if count is None or time.monotonic() > deadline or client_gone(conn):
            logging.info("Wait: the files are not in the Zed database; the client waits for a save")
            return False
        time.sleep(0.5)
    logging.info("Wait: the files are open in Zed (database %s)", db)
    closed = 0
    while closed < 2:  # Two checks, so a short change does not end the wait.
        if client_gone(conn):
            return False
        time.sleep(0.5)
        closed = closed + 1 if tabs.count(paths) == 0 else 0
    logging.info("Wait: the tabs are closed")
    return True


# --- Browse and notify ---


def handle_browse(conn: socket.socket, cfg: Config, req: Request) -> None:
    logging.info("Opening the URL %s (from host %s)", req.url, req.host)
    try:
        if cfg.browser_command:
            proc = ZedProcess([cfg.browser_command, req.url])
            threading.Thread(target=proc.wait, args=(30,), daemon=True).start()
            ok = True
        else:
            ok = webbrowser.open(req.url)
    except OSError as e:
        logging.error("Cannot open the browser: %s", e)
        ok = False
    send(conn, f"OK {__version__}" if ok else "ERR cannot open a browser on the local computer")


# Windows: a toast notification with Windows PowerShell. The text comes from
# environment variables, so it is never part of the command.
WINDOWS_TOAST = "\n".join([
    "$ErrorActionPreference = 'Stop'",
    "$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications,"
    " ContentType = WindowsRuntime]",
    "$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument,"
    " ContentType = WindowsRuntime]",
    "$title = [Security.SecurityElement]::Escape($env:ZRO_TITLE)",
    "$message = [Security.SecurityElement]::Escape($env:ZRO_MESSAGE)",
    "$xml = New-Object Windows.Data.Xml.Dom.XmlDocument",
    "$xml.LoadXml(\"<toast><visual><binding template='ToastGeneric'>\" +"
    " \"<text>$title</text><text>$message</text></binding></visual></toast>\")",
    r"$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'",
    "$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)",
    "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show($toast)",
])


def notify_command(cfg: Config, title: str, message: str) -> list[str] | None:
    if cfg.notify_command:
        return [cfg.notify_command, title, message]
    if sys.platform == "win32":
        script = base64.b64encode(WINDOWS_TOAST.encode("utf-16-le")).decode()
        return ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-EncodedCommand", script]
    if sys.platform == "darwin":
        return ["osascript", "-e", "on run argv", "-e",
                "display notification (item 2 of argv) with title (item 1 of argv)",
                "-e", "end run", title, message]
    notify_send = shutil.which("notify-send")
    return [notify_send, "--app-name=zed-remote-open", title, message] if notify_send else None


def handle_notify(conn: socket.socket, cfg: Config, req: Request) -> None:
    title = req.title or f"zed-remote-open: {req.host}"
    args = notify_command(cfg, title, req.message)
    if args is None:
        send(conn, "ERR no notification command on the local computer (install notify-send)")
        return
    logging.info("Notification from host %s: %s", req.host, req.message)
    env = {**os.environ, "ZRO_TITLE": title, "ZRO_MESSAGE": req.message}
    try:
        proc = ZedProcess(args, env=env)
    except OSError as e:
        logging.error("Cannot show the notification: %s", e)
        send(conn, f"ERR cannot show the notification: {e}")
        return
    threading.Thread(target=proc.wait, args=(30,), daemon=True).start()
    send(conn, f"OK {__version__}")


# --- Managed SSH tunnel ---


class Tunnel(threading.Thread):
    """Keeps an SSH connection to a host with the reverse forward of the
    listener port. Reconnects after 2 seconds, then after longer times (at
    most 60 seconds), when the connection stops."""

    def __init__(self, cfg: Config, host: str, stop: threading.Event):
        super().__init__(name=f"tunnel-{host}", daemon=True)
        self.cfg, self.host, self.stop = cfg, host, stop
        # The "-E" log path also marks the process: the installers find the
        # tunnels by "zed-remote-open" and "tunnel-" in the command line.
        self.ssh_log = cfg.log.parent / f"tunnel-{host}.log"
        self.proc: subprocess.Popen | None = None

    def forward_in_config(self) -> bool:
        """True if ~/.ssh/config already forwards the port for this host."""
        try:
            out = subprocess.run([self.cfg.ssh, "-G", self.host], capture_output=True,
                                 text=True, timeout=15, creationflags=NO_WINDOW).stdout
        except (OSError, subprocess.TimeoutExpired):
            return False
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[0] == "remoteforward":
                if parts[1].rsplit(":", 1)[-1] == str(self.cfg.port):
                    return True
        return False

    def command(self) -> list[str]:
        port = self.cfg.port
        args = [self.cfg.ssh, "-N", "-T",
                "-o", "BatchMode=yes",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "ConnectTimeout=15",
                "-E", str(self.ssh_log)]
        if self.forward_in_config():
            logging.info("Tunnel %s: ~/.ssh/config forwards port %d; the tunnel uses it. "
                         "Remove that RemoteForward to stop the 'remote port forwarding "
                         "failed' warnings in your SSH sessions.", self.host, port)
        else:
            args += ["-R", f"127.0.0.1:{port}:127.0.0.1:{port}"]
        return args + [self.host]

    def run(self) -> None:
        delay = 2.0
        while not self.stop.is_set():
            started = time.monotonic()
            try:
                self.ssh_log.write_text("")
                args = self.command()
                logging.info("Tunnel %s: connecting (%s)", self.host, " ".join(args))
                self.proc = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                                             stdout=subprocess.DEVNULL,
                                             stderr=subprocess.DEVNULL, creationflags=NO_WINDOW)
                code = self.proc.wait()
            except OSError as e:
                code, self.proc = -1, None
                logging.error("Tunnel %s: cannot run ssh: %s", self.host, e)
            if self.stop.is_set():
                break
            ran = time.monotonic() - started
            delay = 2.0 if ran > 60 else min(delay * 2, 60.0)
            try:
                detail = self.ssh_log.read_text(errors="replace").strip()[-500:]
            except OSError:
                detail = ""
            logging.warning("Tunnel %s: ended after %d seconds (exit code %d). %s "
                            "Next try in %d seconds.", self.host, ran, code,
                            detail or "(no output)", delay)
            self.stop.wait(delay)

    def close(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


# --- Server ---


def close_gracefully(conn: socket.socket) -> None:
    """Closes without a TCP reset. If unread data stays in the receive buffer
    (for example after "request is too large"), close() sends a reset, and on
    Windows the client can lose the response line before it reads it."""
    try:
        conn.shutdown(socket.SHUT_WR)
        conn.settimeout(0.5)
        drained = 0
        while drained < 4 * MAX_REQUEST_BYTES:
            chunk = conn.recv(65536)
            if not chunk:
                break
            drained += len(chunk)
    except OSError:
        pass


def serve(conn: socket.socket, cfg: Config, slots: threading.BoundedSemaphore) -> None:
    try:
        with conn:
            handle(conn, cfg)
            close_gracefully(conn)
    except Exception:
        logging.exception("Request failed")
    finally:
        slots.release()


def setup_logging(log: Path) -> None:
    try:
        log.parent.mkdir(parents=True, exist_ok=True)
        handler: logging.Handler = logging.handlers.RotatingFileHandler(
            log, maxBytes=1_000_000, backupCount=1, encoding="utf-8"
        )
    except OSError:
        handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(logging.INFO)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Opens Zed remote projects.")
    parser.add_argument("--version", action="version", version=f"zed-remote-open {__version__}")
    parser.add_argument("--config", type=Path, default=data_dir() / "listener.json")
    try:
        args = parser.parse_args(argv)
    except SystemExit as e:
        if e.code:  # pythonw has no console: write the error to the log.
            setup_logging(data_dir() / "listener.log")
            logging.error("Invalid arguments. Usage: %s", parser.format_usage().strip())
        raise

    try:
        cfg = load_config(args.config)
    except ConfigError as e:
        setup_logging(data_dir() / "listener.log")
        logging.error("Invalid configuration: %s", e)
        raise SystemExit(2) from None

    setup_logging(cfg.log)
    slots = threading.BoundedSemaphore(MAX_CLIENTS)
    with socket.create_server(("127.0.0.1", cfg.port)) as server:
        logging.info(
            "Version %s listening on 127.0.0.1:%d for hosts %s (token: %s, zed: %s, "
            "tunnels: %s, wait_close: %s)",
            __version__, cfg.port, sorted(cfg.hosts), "yes" if cfg.token else "no", cfg.zed,
            list(cfg.tunnel_hosts) or "none", cfg.wait_close,
        )
        stop = threading.Event()
        tunnels = [Tunnel(cfg, host, stop) for host in cfg.tunnel_hosts]

        def stop_tunnels() -> None:
            stop.set()
            for tunnel in tunnels:
                tunnel.close()

        atexit.register(stop_tunnels)
        if hasattr(signal, "SIGTERM"):
            signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        for tunnel in tunnels:
            tunnel.start()

        while True:
            conn, _ = server.accept()
            if not slots.acquire(blocking=False):
                logging.warning("Too many connections; closed one")
                conn.close()
                continue
            threading.Thread(target=serve, args=(conn, cfg, slots), daemon=True).start()


if __name__ == "__main__":
    main()
