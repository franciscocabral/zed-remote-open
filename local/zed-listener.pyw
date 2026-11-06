"""zed-remote-open listener: opens Zed remote projects for requests that come
through an SSH reverse tunnel.

Usage: zed-listener.pyw [--config PATH]

Protocol "zro 2". One TCP connection on 127.0.0.1 = one request:

    zro 2
    token <token>                      only if the listener has a token
    host <ssh host>
    mode open|wait|ping                optional, default open
    window current|new                 optional, default current
    path <line> <column> <absolute path>    zero or more (0 = no position)
    end

The listener sends one response line: "OK <version>" or "ERR <message>".
For mode "wait", it sends "DONE <exit code>" when Zed closes the files.
"""

import argparse
import hmac
import json
import logging
import logging.handlers
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote

__version__ = "1.1.0"

PROTOCOL = "zro 2"
DEFAULT_PORT = 7682
MAX_REQUEST_BYTES = 64 * 1024
REQUEST_TIMEOUT = 5.0  # seconds, for the full request
MAX_CLIENTS = 16
HOST_RE = re.compile(r"[A-Za-z0-9._-]+")
TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{16,256}")
PATH_RE = re.compile(r"(\d{1,9}) (\d{1,9}) (/.*)")
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


@dataclass
class Request:
    host: str
    mode: str = "open"
    window: str = "current"
    token: str | None = None
    paths: list = field(default_factory=list)  # (line, column, absolute path)


def data_dir() -> Path:
    """Directory of the listener files for this operating system."""
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / "zed-remote-open"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "zed-remote-open"
    base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(base) / "zed-remote-open"


def find_zed(value: str | None) -> str:
    if value:
        found = value if Path(value).is_file() else shutil.which(value)
        if not found:
            raise ConfigError(f"zed_command {value!r} does not exist")
        return found
    for name in ("zed", "zeditor"):
        found = shutil.which(name)
        if found:
            return found
    raise ConfigError("the zed command is not in PATH (set zed_command)")


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

    hosts = data.get("hosts")
    if (
        not isinstance(hosts, list)
        or not hosts
        or not all(isinstance(h, str) and HOST_RE.fullmatch(h) for h in hosts)
    ):
        raise ConfigError(f"invalid hosts: {hosts!r}")

    token = data.get("token") or None
    if token is not None and not (isinstance(token, str) and TOKEN_RE.fullmatch(token)):
        raise ConfigError("invalid token (use 16 to 256 letters, digits, '_' or '-')")

    log = Path(data["log"]) if data.get("log") else data_dir() / "listener.log"
    return Config(port, frozenset(hosts), token, find_zed(data.get("zed_command")), log)


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
        elif key in ("token", "host", "mode", "window"):
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
    req = Request(host, values.get("mode", "open"), values.get("window", "current"), None, paths)
    if req.mode not in ("open", "wait", "ping"):
        raise BadRequest(f"invalid mode {req.mode!r}")
    if req.window not in ("current", "new"):
        raise BadRequest(f"invalid window {req.window!r}")
    if req.mode != "ping" and not paths:
        raise BadRequest("no path")
    return req


def build_command(cfg: Config, req: Request) -> list[str]:
    """Returns the zed command line. The user cannot add other options."""
    args = [cfg.zed]
    if req.mode == "wait":
        args.append("--wait")
    args.append("--new" if req.window == "new" else "--add")
    for line, column, path in req.paths:
        url = f"ssh://{req.host}{quote(path)}"
        if line:
            url += f":{line}" + (f":{column}" if column else "")
        args.append(url)
    return args


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
        return

    args = build_command(cfg, req)
    logging.info("Running %s", " ".join(args))
    try:
        proc = subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=NO_WINDOW,
        )
    except OSError as e:
        logging.error("Cannot run %s: %s", cfg.zed, e)
        send(conn, f"ERR cannot run zed: {e}")
        return
    send(conn, f"OK {__version__}")
    if req.mode == "wait":
        conn.settimeout(None)
        code = proc.wait()
        logging.info("Zed closed the files (exit code %d)", code)
        send(conn, f"DONE {code}")
    else:
        threading.Thread(target=proc.wait, daemon=True).start()  # No zombie process.


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
            "Version %s listening on 127.0.0.1:%d for hosts %s (token: %s, zed: %s)",
            __version__, cfg.port, sorted(cfg.hosts), "yes" if cfg.token else "no", cfg.zed,
        )
        while True:
            conn, _ = server.accept()
            if not slots.acquire(blocking=False):
                logging.warning("Too many connections; closed one")
                conn.close()
                continue
            threading.Thread(target=serve, args=(conn, cfg, slots), daemon=True).start()


if __name__ == "__main__":
    main()
