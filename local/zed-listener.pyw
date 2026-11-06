"""Opens Zed remote projects from requests sent through an SSH reverse tunnel.

Usage: pythonw zed-listener.pyw --hosts myserver,myserver.ts [--port 7682]

Protocol: one TCP connection on 127.0.0.1 = one request = one zed call.
A request has one or more lines "host:/absolute/path\\n". The client closes
the connection after the last line. All lines must use the same host.
A connection with no data is a connection test. The listener ignores it.
"""

import argparse
import logging
import re
import shutil
import socket
import subprocess
import time
from pathlib import Path
from urllib.parse import quote

__version__ = "1.0.0"

DEFAULT_PORT = 7682
MAX_REQUEST_BYTES = 64 * 1024
REQUEST_TIMEOUT = 5.0  # seconds, for the full request
HOST_RE = re.compile(r"[A-Za-z0-9._-]+")

logging.basicConfig(
    filename=Path.home() / "zed-listener.log",
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

ZED = shutil.which("zed")


class BadRequest(Exception):
    pass


def read_request(conn: socket.socket) -> str:
    """Reads until EOF. Stops at the size limit or at the deadline."""
    deadline = time.monotonic() + REQUEST_TIMEOUT
    data = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise BadRequest("timeout")
        conn.settimeout(remaining)
        try:
            chunk = conn.recv(4096)
        except TimeoutError:
            raise BadRequest("timeout") from None
        if not chunk:
            break
        data += chunk
        if len(data) > MAX_REQUEST_BYTES:
            raise BadRequest(f"request is larger than {MAX_REQUEST_BYTES} bytes")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise BadRequest("request is not valid UTF-8") from None


def parse(request: str, allowed_hosts: set[str]) -> list[str]:
    """Returns one ssh:// URL for each line. Rejects the full request if a line is bad."""
    urls = []
    hosts = set()
    for line in request.splitlines():
        if not line.strip():
            continue
        host, sep, path = line.partition(":")
        if not sep or host not in allowed_hosts or not path.startswith("/"):
            raise BadRequest(f"invalid line {line!r}")
        hosts.add(host)
        urls.append(f"ssh://{host}{quote(path)}")
    if not urls:
        raise BadRequest("empty request")
    if len(hosts) > 1:
        raise BadRequest(f"more than one host: {sorted(hosts)}")
    return urls


def handle(conn: socket.socket, allowed_hosts: set[str]) -> None:
    request = ""
    try:
        request = read_request(conn)
        if not request:
            logging.info("Connection test")
            return
        urls = parse(request, allowed_hosts)
    except BadRequest as e:
        logging.warning("Rejected request (%s): %r", e, request[:500])
        return
    logging.info("Opening %s", " ".join(urls))
    subprocess.Popen([ZED, *urls])


def parse_args() -> tuple[int, set[str]]:
    """Returns (port, allowed hosts). pythonw has no console, so errors go to the log."""
    parser = argparse.ArgumentParser(description="Opens Zed remote projects.")
    parser.add_argument("--version", action="version", version=f"zed-remote-open {__version__}")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--hosts", required=True, help="SSH host names that Zed can open, separated by commas"
    )
    try:
        args = parser.parse_args()
    except SystemExit as e:
        if e.code:  # 0 = --help or --version
            logging.error("Invalid arguments. Usage: %s", parser.format_usage().strip())
        raise

    hosts = {h.strip() for h in args.hosts.split(",") if h.strip()}
    if not hosts or not all(HOST_RE.fullmatch(h) for h in hosts):
        logging.error("Invalid --hosts value: %r", args.hosts)
        raise SystemExit(2)
    if not 1 <= args.port <= 65535:
        logging.error("Invalid --port value: %r", args.port)
        raise SystemExit(2)
    return args.port, hosts


def main() -> None:
    port, allowed_hosts = parse_args()

    if ZED is None:
        logging.error("The zed command is not in PATH")
        raise SystemExit(1)

    with socket.create_server(("127.0.0.1", port)) as server:
        logging.info(
            "Version %s listening on 127.0.0.1:%d for hosts %s",
            __version__, port, sorted(allowed_hosts),
        )
        while True:
            conn, _ = server.accept()
            with conn:
                try:
                    handle(conn, allowed_hosts)
                except Exception:
                    logging.exception("Request failed")


if __name__ == "__main__":
    main()
