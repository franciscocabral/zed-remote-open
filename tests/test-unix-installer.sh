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
    rm -rf -- "$WORK"
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
else
    step "Remote tests skipped (they need Bash 4 and GNU realpath)"
fi

step "Local uninstall"
"${LOCAL[@]}" -u 2>&1 | tee "$WORK/out"
! grep -q 'zed-remote-open' "$HOME/.ssh/config" || fail "the SSH block is still there"
[[ -z $(pgrep -f "$HOME/.*zed-listener" || true) ]] || fail "the listener still runs"
ls "$HOME"/.local/share/zed-remote-open "$HOME/Library/Application Support/zed-remote-open" 2>/dev/null &&
    fail "the listener files are still there"

printf '\n\033[32mAll installer tests passed.\033[0m\n'
