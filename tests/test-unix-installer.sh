#!/usr/bin/env bash
# Integration test: installs the listener (local-unix-installer.sh) and the
# zed command (remote-linux-installer.sh) in a temporary HOME, uses them
# together, then uninstalls them. Runs on Linux and macOS.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
export HOME="$WORK/home"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
mkdir -p "$HOME" "$WORK/bin"
PY=$(command -v python3)
TOKEN=test-token-0123456789abcdef
PORT=$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
CALLS="$WORK/zed-calls.jsonl"
if [[ $(uname -s) == Darwin ]]; then
    DATA="$HOME/Library/Application Support/zed-remote-open"
else
    DATA="$HOME/.local/share/zed-remote-open"
fi

# A fake "zed" command in PATH: the installer stores its path for the listener.
printf '#!/bin/sh\nexec "%s" "%s" "%s" "$@"\n' "$PY" "$ROOT/tests/fake_zed.py" "$CALLS" >"$WORK/bin/zed"
chmod +x "$WORK/bin/zed"
export PATH="$WORK/bin:$PATH"

step() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
fail() {
    printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2
    exit 1
}
expect() { # FILE TEXT
    grep -qF -- "$2" "$1" || fail "expected '$2' in the output"
}
cleanup() {
    pkill -f "$HOME/.*zed-listener" 2>/dev/null || true
    pkill -f "$HOME/.*zed-remote-open/tunnel-" 2>/dev/null || true
    [[ -z ${HTTP_PID-} ]] || kill "$HTTP_PID" 2>/dev/null || true
    rm -rf -- "$WORK"
}

# A local web server with the files and SHA256SUMS, as raw.githubusercontent.com.
serve_files() {
    mkdir -p "$WORK/srv/remote" "$WORK/srv/local" "$WORK/alone"
    cp "$ROOT/remote/zed" "$WORK/srv/remote/zed"
    cp "$ROOT/local/zed-listener.pyw" "$WORK/srv/local/zed-listener.pyw"
    (cd "$WORK/srv" && "$PY" -c 'import hashlib, sys
for name in sys.argv[1:]:
    print(hashlib.sha256(open(name, "rb").read()).hexdigest() + "  " + name)' \
        remote/zed local/zed-listener.pyw >SHA256SUMS)
    HTTP_PORT=$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    "$PY" -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK/srv" >/dev/null 2>&1 &
    HTTP_PID=$!
    sleep 1
    # The installers alone, with no files next to them: they download.
    cp "$ROOT/remote/remote-linux-installer.sh" "$ROOT/local/local-unix-installer.sh" "$WORK/alone/"
}
trap cleanup EXIT

LOCAL=(bash "$ROOT/local/local-unix-installer.sh" -y -A)

step "Local installer: new installation"
"${LOCAL[@]}" -p "$PORT" -H testhost,testhost.ts -k "$TOKEN" 2>&1 | tee "$WORK/out"
expect "$WORK/out" "The listener answers on 127.0.0.1:$PORT"
expect "$WORK/out" "Verified: ssh testhost forwards the server port $PORT"
expect "$WORK/out" "Verified: ssh testhost.ts forwards the server port $PORT"
expect "$WORK/out" "remote-linux-installer.sh) -y -h testhost -p $PORT -k $TOKEN"
grep -c '^# BEGIN zed-remote-open' "$HOME/.ssh/config" | grep -qx 1 || fail "one block expected"

step "Local installer: managed SSH tunnel"
"${LOCAL[@]}" -T managed -p "$PORT" -H testhost,testhost.ts 2>&1 | tee "$WORK/out"
grep -q '"tunnel_hosts": \[' "$DATA/listener.json" || fail "no tunnel_hosts in listener.json"
! grep -q '^# BEGIN zed-remote-open' "$HOME/.ssh/config" || fail "the block must go in managed mode"
expect "$WORK/out" "does not work without a password"
sleep 2
expect "$DATA/listener.log" "Tunnel testhost: connecting"

step "Local installer: back to config mode"
"${LOCAL[@]}" -T config -p "$PORT" -H testhost,testhost.ts 2>&1 | tee "$WORK/out"
expect "$WORK/out" "Verified: ssh testhost forwards the server port $PORT"
! grep -q 'tunnel_hosts' "$DATA/listener.json" || fail "tunnel_hosts must go in config mode"

step "Local installer: same version, no SSH change"
"${LOCAL[@]}" -p "$PORT" -H testhost,testhost.ts 2>&1 | tee "$WORK/out"
expect "$WORK/out" "(same version)"
expect "$WORK/out" "The current token stays"
expect "$WORK/out" "No change is necessary."
grep -c '^# BEGIN zed-remote-open' "$HOME/.ssh/config" | grep -qx 1 || fail "one block expected"

if ((BASH_VERSINFO[0] >= 4)) && realpath -m / >/dev/null 2>&1; then
    step "Remote installer with the options from the local installer"
    bash "$ROOT/remote/remote-linux-installer.sh" -y -h testhost -p "$PORT" -k "$TOKEN" 2>&1 | tee "$WORK/out"
    expect "$WORK/out" "accepts host 'testhost'"
    expect "$WORK/out" "Done."

    [[ -L $HOME/.local/bin/zed-browse ]] || fail "no zed-browse link"

    step "Remote installer alone: download with the checksum check"
    serve_files
    ZED_REMOTE_OPEN_URL="http://127.0.0.1:$HTTP_PORT" bash "$WORK/alone/remote-linux-installer.sh" \
        -y -h testhost -p "$PORT" 2>&1 | tee "$WORK/out"
    expect "$WORK/out" "Checksum of remote/zed: correct"
    cp "$WORK/srv/SHA256SUMS" "$WORK/srv/SHA256SUMS.orig"
    awk -v z="$(printf '%064d' 0)" '{ print z "  " $2 }' "$WORK/srv/SHA256SUMS.orig" >"$WORK/srv/SHA256SUMS"
    if ZED_REMOTE_OPEN_URL="http://127.0.0.1:$HTTP_PORT" bash "$WORK/alone/remote-linux-installer.sh" \
        -y -h testhost -p "$PORT" >"$WORK/out" 2>&1; then
        fail "a wrong checksum must stop the installer"
    fi
    expect "$WORK/out" "the checksum of remote/zed is not correct"

    step "Local installer alone: a wrong checksum stops it"
    if ZED_REMOTE_OPEN_URL="http://127.0.0.1:$HTTP_PORT" bash "$WORK/alone/local-unix-installer.sh" \
        -y -A -T config -p "$PORT" -H testhost >"$WORK/out" 2>&1; then
        fail "a wrong checksum must stop the local installer"
    fi
    expect "$WORK/out" "the checksum of the listener is not correct"
    mv "$WORK/srv/SHA256SUMS.orig" "$WORK/srv/SHA256SUMS"

    step "zed opens a file with its Git root and a position"
    mkdir -p "$WORK/repo"
    git -C "$WORK/repo" init -q
    echo x >"$WORK/repo/a.md"
    (cd "$WORK/repo" && "$HOME/.local/bin/zed" a.md:3)
    sleep 1
    real_repo=$(realpath "$WORK/repo")
    tail -n 1 "$CALLS" | grep -qF "\"ssh://testhost$real_repo/a.md:3\"" || fail "zed was not called: $(cat "$CALLS")"

    step "Remote uninstall"
    bash "$ROOT/remote/remote-linux-installer.sh" -u -y
    [[ ! -e $HOME/.local/bin/zed && ! -e $HOME/.config/zed-remote-open ]] || fail "zed is still installed"
    [[ ! -L $HOME/.local/bin/zed-browse ]] || fail "zed-browse is still installed"
else
    step "Remote tests skipped (they need Bash 4 and GNU realpath)"
fi

step "Local uninstall"
"${LOCAL[@]}" -u 2>&1 | tee "$WORK/out"
! grep -q 'zed-remote-open' "$HOME/.ssh/config" || fail "the SSH block is still there"
[[ -z $(pgrep -f "$HOME/.*zed-listener" || true) ]] || fail "the listener still runs"
[[ ! -e $DATA ]] || fail "the listener files are still there"

printf '\n\033[32mAll installer tests passed.\033[0m\n'
