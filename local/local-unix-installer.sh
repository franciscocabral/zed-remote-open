#!/usr/bin/env bash
# Installs the zed-remote-open listener on macOS or Linux (the local computer,
# where Zed runs). It works with Bash 3.2 (the Bash of macOS).
#
# Usage: local-unix-installer.sh [OPTIONS]
#        local-unix-installer.sh -u [-y]
#
#   -p PORT     Listener port (default 7682).
#   -H HOSTS    SSH hosts that Zed can open, separated by commas.
#   -k TOKEN    Use this token.        -K  Use no token.
#   -P PYTHON   Python 3.10 or later to run the listener.
#   -y          Ask no questions: answer yes and use the default values.
#   -f          Replace a newer version.
#   -A          Do not start the listener at login.
#   -S          Do not change ~/.ssh/config.
#   -u          Uninstall.
set -euo pipefail

BASE_URL="${ZED_REMOTE_OPEN_URL:-https://github.com/franciscocabral/zed-remote-open/raw/main}"
DEFAULT_PORT=7682
LABEL="io.github.franciscocabral.zed-remote-open"
SSH_CONFIG="$HOME/.ssh/config"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
    exit 1
}

case $(uname -s) in
    Darwin)
        OS=macos
        DATA_DIR="$HOME/Library/Application Support/zed-remote-open"
        AUTOSTART="$HOME/Library/LaunchAgents/$LABEL.plist"
        ;;
    Linux)
        OS=linux
        DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zed-remote-open"
        AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/zed-remote-open.desktop"
        ;;
    *) die "this installer supports macOS and Linux. On Windows, use local-windows-installer.ps1." ;;
esac
LISTENER="$DATA_DIR/zed-listener.pyw"
CONFIG="$DATA_DIR/listener.json"
LOG="$DATA_DIR/listener.log"

usage() {
    sed -n '5,17s/^# \{0,1\}//p' "$0" 2>/dev/null ||
        echo "Usage: local-unix-installer.sh [-p PORT] [-H HOSTS] [-k TOKEN|-K] [-P PYTHON] [-y] [-f] [-A] [-S] [-u]"
}

# --- Options ---

opt_port="" opt_hosts="" opt_token="" no_token=0 opt_python=""
yes=0 force=0 no_autostart=0 skip_ssh=0 uninstall=0
while getopts ":p:H:k:KP:yfASu" o; do
    case $o in
        p) opt_port=$OPTARG ;;
        H) opt_hosts=$OPTARG ;;
        k) opt_token=$OPTARG ;;
        K) no_token=1 ;;
        P) opt_python=$OPTARG ;;
        y) yes=1 ;;
        f) force=1 ;;
        A) no_autostart=1 ;;
        S) skip_ssh=1 ;;
        u) uninstall=1 ;;
        :) die "option -$OPTARG needs a value" ;;
        *) usage >&2; exit 1 ;;
    esac
done

interactive=0
if [[ -t 0 && $yes == 0 ]]; then interactive=1; fi

# confirm QUESTION DEFAULT(y|n): returns 0 for yes.
confirm() {
    local answer hint="[y/N]"
    if [[ $2 == y ]]; then hint="[Y/n]"; fi
    if ((yes)); then return 0; fi
    if ((!interactive)); then [[ $2 == y ]]; return; fi
    read -r -p "$1 $hint " answer </dev/tty || answer=""
    answer=${answer:-$2}
    [[ $answer == [yY]* ]]
}

# ask QUESTION DEFAULT: prints the answer.
ask() {
    local answer=""
    if ((interactive)); then read -r -p "$1 [$2]: " answer </dev/tty || answer=""; fi
    echo "${answer:-$2}"
}

# --- Listener processes and autostart ---

listener_pids() {
    pgrep -f 'zed-listener\.pyw --config' 2>/dev/null | grep -v "^$$\$" || true
}

stop_listeners() {
    local pids
    pids=$(listener_pids)
    [[ -n $pids ]] || return 0
    info "A zed listener runs now (PID ${pids//$'\n'/ }). The installer must stop it."
    confirm "Stop it?" y || die "installation stopped"
    if [[ $OS == macos ]]; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    fi
    # shellcheck disable=SC2086 # One PID for each word.
    kill $pids 2>/dev/null || true
    sleep 1
}

remove_autostart() {
    if [[ $OS == macos && -f $AUTOSTART ]]; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    fi
    rm -f -- "$AUTOSTART"
}

# --- SSH configuration ---

# Prints the file without the zed-remote-open block.
strip_block() {
    [[ -f $1 ]] || return 0
    awk '/^# BEGIN zed-remote-open/ { skip = 1; next }
         skip && /^# END zed-remote-open/ { skip = 0; next }
         !skip { print }' "$1"
}

# forward_state HOST PORT CONFIG_FILE: prints ok, conflict, missing or unknown.
forward_state() {
    local out
    if ! out=$(ssh -G -F "$3" "$1" 2>/dev/null); then
        echo unknown
        return
    fi
    printf '%s\n' "$out" | awk -v port="$2" '
        function port_of(s) { sub(/.*:/, "", s); return s }
        function host_of(s) { if (s !~ /^\[/) return ""; sub(/^\[/, "", s); sub(/\]:.*/, "", s); return s }
        $1 == "remoteforward" && port_of($2) == port {
            if (port_of($3) == port && (host_of($3) == "127.0.0.1" || host_of($3) == "localhost")) { state = "ok"; exit }
            state = "conflict"
        }
        END { print (state == "" ? "missing" : state) }'
}

ssh_problems=""
add_problem() { ssh_problems="$ssh_problems- $1"$'\n'; }

update_ssh_config() {
    local base needed="" h state block new
    info "Checking $SSH_CONFIG"
    command -v ssh >/dev/null || { add_problem "ssh is not installed."; return; }

    base=$(mktemp)
    new=$(mktemp)
    strip_block "$SSH_CONFIG" >"$base"
    for h in "${hosts[@]}"; do
        state=$(forward_state "$h" "$port" "$base")
        case $state in
            ok) note "$h: your configuration already has the forward." ;;
            conflict)
                warn "$h: your configuration forwards the server port $port to a different place."
                add_problem "Fix the RemoteForward of '$h': it must be 'RemoteForward 127.0.0.1:$port 127.0.0.1:$port'." ;;
            unknown)
                warn "$h: 'ssh -G $h' failed."
                add_problem "Fix the errors in $SSH_CONFIG (run: ssh -G $h)." ;;
            *) needed="$needed $h" ;;
        esac
    done

    # The user's text without trailing empty lines, then the block at the end
    # (at the start, the global options would become part of the block).
    awk '/^[ \t\r]*$/ { blank = blank $0 "\n"; next } { printf "%s", blank; blank = ""; print }' "$base" >"$new"
    if [[ -n $needed ]]; then
        block="# BEGIN zed-remote-open (managed by local-unix-installer.sh, do not edit)
Host${needed}
    RemoteForward 127.0.0.1:$port 127.0.0.1:$port
# END zed-remote-open"
        if [[ -s $new ]]; then echo >>"$new"; fi
        printf '%s\n' "$block" >>"$new"
    fi

    if [[ -f $SSH_CONFIG ]] && cmp -s "$new" "$SSH_CONFIG"; then
        note "No change is necessary."
    elif [[ ! -f $SSH_CONFIG && -z $needed ]]; then
        note "No change is necessary."
    else
        if [[ -n $needed ]]; then
            echo
            echo "The installer will add this block to the end of $SSH_CONFIG:"
            echo
            echo "$block"
            echo
        else
            note "The installer will remove the old zed-remote-open block."
        fi
        if confirm "Change $SSH_CONFIG?" y; then
            if [[ -f $SSH_CONFIG ]]; then
                cp -p -- "$SSH_CONFIG" "$SSH_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
                note "Backup: $SSH_CONFIG.bak.*"
            else
                mkdir -p -- "$HOME/.ssh"
                chmod 700 "$HOME/.ssh"
                (umask 077 && : >"$SSH_CONFIG")
            fi
            cat "$new" >"$SSH_CONFIG" # In place: the permissions stay.
            note "Changed $SSH_CONFIG"
        else
            add_problem "You did not let the installer change the file."
        fi
    fi
    rm -f -- "$base" "$new"

    if [[ -z $ssh_problems ]]; then
        for h in "${hosts[@]}"; do
            state=$(forward_state "$h" "$port" "$SSH_CONFIG")
            if [[ $state == ok ]]; then
                note "Verified: ssh $h forwards the server port $port to 127.0.0.1:$port."
            else
                add_problem "The verification of '$h' failed (state: $state). Run: ssh -G $h"
            fi
        done
    fi
}

remove_ssh_block() {
    [[ -f $SSH_CONFIG ]] && grep -q '^# BEGIN zed-remote-open' "$SSH_CONFIG" || return 0
    if confirm "Remove the zed-remote-open block from $SSH_CONFIG?" y; then
        local tmp
        tmp=$(mktemp)
        strip_block "$SSH_CONFIG" >"$tmp"
        cp -p -- "$SSH_CONFIG" "$SSH_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
        cat "$tmp" >"$SSH_CONFIG"
        rm -f -- "$tmp"
        note "Removed the block (backup: $SSH_CONFIG.bak.*)"
    fi
}

# --- Uninstall ---

if ((uninstall)); then
    info "Uninstalling the zed-remote-open listener"
    echo "This removes: $DATA_DIR, $AUTOSTART and the block in $SSH_CONFIG."
    confirm "Continue?" n || die "uninstall stopped"
    stop_listeners
    remove_autostart
    remove_ssh_block
    rm -rf -- "$DATA_DIR"
    info "Removed. To remove zed on the server, run there: zed --uninstall"
    exit 0
fi

# --- 1. Python ---

info "Looking for Python 3.10 or later"
PY=""
for c in ${opt_python:+"$opt_python"} python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    c=$(command -v "$c" 2>/dev/null) || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
        PY=$c
        break
    fi
done
[[ -n $PY ]] || die "Python 3.10 or later is not installed. Install it, or give its path with -P."
note "Found $PY ($("$PY" -c 'import platform; print(platform.python_version())'))"

# Small helpers in Python: JSON, versions, ports and the ping.
py() { "$PY" -c "$@"; }
json_get() { # FILE KEY: prints the value (lists separated by commas)
    py 'import json, sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8-sig")).get(sys.argv[2])
except Exception:
    v = None
print(",".join(v) if isinstance(v, list) else ("" if v is None else v))' "$1" "$2"
}
compare_versions() { # prints lt, eq or gt
    py 'import sys
a, b = (tuple(int(x) for x in v.split(".")) for v in sys.argv[1:])
print("lt" if a < b else "eq" if a == b else "gt")' "$1" "$2"
}
port_free() { # Same socket options as the listener, so TIME_WAIT is not "in use".
    py 'import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)' "$1"
}
ping_listener() { # PORT HOST (token in ZRO_TOKEN): prints the response line
    py 'import os, socket, sys
lines = ["zro 2"] + (["token " + os.environ["ZRO_TOKEN"]] if os.environ.get("ZRO_TOKEN") else [])
lines += ["host " + sys.argv[2], "mode ping", "end"]
try:
    with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5) as s:
        s.sendall(("\n".join(lines) + "\n").encode())
        print(s.makefile().readline().strip())
except OSError as e:
    print("ERR " + str(e))' "$1" "$2"
}
listener_version() { # FILE: prints X.Y.Z, unknown or nothing
    [[ -f $1 ]] || return 0
    sed -n 's/^__version__ = "\([0-9][0-9.]*\)"$/\1/p' "$1" | head -n 1 | grep . ||
        { grep -q 'Opens Zed remote projects' "$1" && echo unknown; } || true
}

# --- 2. Zed ---

ZED=""
for c in zed zeditor; do
    ZED=$(command -v "$c" 2>/dev/null) && break
done
if [[ -z $ZED && $OS == macos && -x /usr/local/bin/zed ]]; then ZED=/usr/local/bin/zed; fi
if [[ -n $ZED ]]; then
    note "Found Zed: $ZED"
else
    warn "The 'zed' command is not in PATH. In Zed, run 'zed: install cli', then run this installer again."
fi

# --- 3. Versions ---

info "Getting the new listener"
new_file=$(mktemp)
trap 'rm -f -- "$new_file"' EXIT
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
if [[ -n $script_dir && -f $script_dir/zed-listener.pyw ]]; then
    cp -- "$script_dir/zed-listener.pyw" "$new_file"
    note "Using $script_dir/zed-listener.pyw"
else
    command -v curl >/dev/null || die "the 'curl' command is necessary"
    note "Downloading $BASE_URL/local/zed-listener.pyw"
    curl -fsSL "$BASE_URL/local/zed-listener.pyw" -o "$new_file" || die "cannot download the listener"
fi
new_version=$(listener_version "$new_file")
[[ -n $new_version && $new_version != unknown ]] || die "the new listener file is not correct (no version)"
note "New version: $new_version"

replace=1
old_version=$(listener_version "$LISTENER")
if [[ $old_version == unknown ]]; then
    note "Installed: an old version with no version number. It will be updated."
elif [[ -n $old_version ]]; then
    case $(compare_versions "$old_version" "$new_version") in
        lt) note "Installed: $old_version. It will be updated to $new_version." ;;
        eq)
            if ((force)); then
                note "Installed: $old_version (same version). -f: it will be installed again."
            else
                note "Installed: $old_version (same version). The file stays; only the settings change."
                replace=0
            fi
            ;;
        gt)
            ((force)) || die "the installed version $old_version is newer than $new_version. Use -f to install $new_version."
            warn "Installed: $old_version (newer). -f: it will be replaced by $new_version."
            ;;
    esac
fi

# --- 4. Stop the listener ---

stop_listeners

# --- 5. Port ---

current_port=$(json_get "$CONFIG" port 2>/dev/null || true)
port=${opt_port:-$(ask "Listener port" "${current_port:-$DEFAULT_PORT}")}
while true; do
    if ! [[ $port =~ ^[0-9]{1,5}$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
        warn "'$port' is not a port number (1 to 65535)."
    elif ! port_free "$port"; then
        warn "Port $port is in use on 127.0.0.1. Select a different port."
    else
        break
    fi
    ((interactive)) && [[ -z $opt_port ]] || exit 1
    port=$(ask "Listener port" "$DEFAULT_PORT")
done
note "Port $port is available."

# --- 6. Hosts ---

current_hosts=$(json_get "$CONFIG" hosts 2>/dev/null || true)
if [[ -z $opt_hosts && -z $current_hosts && -f $SSH_CONFIG ]]; then
    known=$(awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' "$SSH_CONFIG" |
        awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g')
    [[ -z $known ]] || note "Hosts in $SSH_CONFIG: $known"
fi
while true; do
    value=${opt_hosts:-$(ask "SSH hosts that Zed can open (separate with commas)" "$current_hosts")}
    hosts=()
    bad=""
    IFS=, read -r -a parts <<<"$value"
    for h in ${parts[@]+"${parts[@]}"}; do
        h=$(echo "$h" | tr -d '[:space:]')
        [[ -n $h ]] || continue
        if [[ $h =~ ^[A-Za-z0-9._-]+$ ]]; then
            case " ${hosts[*]-} " in *" $h "*) ;; *) hosts+=("$h") ;; esac
        else
            bad="$bad $h"
        fi
    done
    if [[ -z $bad && ${#hosts[@]} -gt 0 ]]; then break; fi
    if [[ -n $bad ]]; then warn "Not valid:$bad. Use only letters, digits, '.', '_' and '-'."; else warn "Give one host or more."; fi
    ((interactive)) && [[ -z $opt_hosts ]] || exit 1
done

# --- 7. Token ---

current_token=$(json_get "$CONFIG" token 2>/dev/null || true)
if [[ -n $opt_token ]]; then
    # No {16,256} in the regex: macOS allows at most 255 repeats (RE_DUP_MAX).
    if ! [[ $opt_token =~ ^[A-Za-z0-9_-]+$ ]] || ((${#opt_token} < 16 || ${#opt_token} > 256)); then
        die "the token is not valid (16 to 256 letters, digits, '_' or '-')"
    fi
    token=$opt_token
elif ((no_token)); then
    token=""
elif [[ -n $current_token ]]; then
    token=$current_token
    note "The current token stays (use -K for no token)."
elif confirm "Use a token? Only the zed commands with the token can open files." y; then
    token=$(py 'import secrets; print(secrets.token_hex(32))')
    note "Made a new token."
else
    token=""
fi

# --- 8. Install ---

mkdir -p -- "$DATA_DIR"
chmod 700 "$DATA_DIR"
if ((replace)); then
    info "Installing listener $new_version in $DATA_DIR"
    cp -- "$new_file" "$LISTENER"
fi
(umask 077 && py 'import json, sys
port, hosts, token, zed, path = sys.argv[1:]
data = {"port": int(port), "hosts": hosts.split(",")}
if token:
    data["token"] = token
if zed:
    data["zed_command"] = zed
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")' "$port" "$(IFS=,; echo "${hosts[*]}")" "$token" "$ZED" "$CONFIG")
note "Saved the settings in $CONFIG"

# --- 9. Autostart and start ---

started=0
if ((no_autostart)); then
    remove_autostart
elif [[ $OS == macos ]]; then
    info "Creating the launch agent $AUTOSTART"
    mkdir -p -- "$(dirname -- "$AUTOSTART")"
    py 'import plistlib, sys
label, python, listener, config, log, path = sys.argv[1:]
with open(path, "wb") as f:
    plistlib.dump({
        "Label": label,
        "ProgramArguments": [python, listener, "--config", config],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "StandardErrorPath": log,
    }, f)' "$LABEL" "$PY" "$LISTENER" "$CONFIG" "$LOG" "$AUTOSTART"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$AUTOSTART" 2>/dev/null; then
        started=1
    else
        warn "launchctl cannot start the agent now. It starts at the next login."
    fi
else
    info "Creating the autostart entry $AUTOSTART"
    mkdir -p -- "$(dirname -- "$AUTOSTART")"
    cat >"$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=zed-remote-open listener
Comment=Opens Zed remote projects for the zed command on your servers
Exec="$PY" "$LISTENER" --config "$CONFIG"
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
fi

if ((!started)); then
    info "Starting the listener"
    nohup "$PY" "$LISTENER" --config "$CONFIG" >/dev/null 2>&1 &
fi
sleep 1
response=$(ZRO_TOKEN=$token ping_listener "$port" "${hosts[0]}")
if [[ $response == "OK "* ]]; then
    note "The listener answers on 127.0.0.1:$port (version ${response#OK }). Log: $LOG"
else
    warn "The listener does not answer on port $port ($response). Read $LOG."
fi

# --- 10. SSH configuration ---

ssh_ok=0
if ((skip_ssh)); then
    add_problem "You used -S."
else
    update_ssh_config
fi
[[ -n $ssh_problems ]] || ssh_ok=1

echo
if ((ssh_ok)); then
    printf '\033[1;32m%s\033[0m\n' "The SSH configuration is correct."
    echo "- Close the SSH sessions to the server and connect again. The forward starts"
    echo "  only with a new connection."
else
    printf '\033[1;31m%s\033[0m\n' "REQUIRED: change your SSH configuration. WITHOUT IT, IT WILL NOT WORK."
    printf '\033[1;33m%s\033[0m' "$ssh_problems"
    echo
    echo "Add the RemoteForward line to each host in $SSH_CONFIG:"
    echo
    echo "Host ${hosts[*]}"
    echo "    RemoteForward 127.0.0.1:$port 127.0.0.1:$port"
    echo
    echo "Then close the SSH sessions to the server and connect again."
fi
echo "- Only one SSH session at a time can forward the port. The other sessions show"
echo "  the warning \"remote port forwarding failed\". This is normal."

remote_cmd="bash <(curl -fsSL $BASE_URL/remote/remote-linux-installer.sh) -y -h ${hosts[0]} -p $port"
[[ -z $token ]] || remote_cmd="$remote_cmd -k $token"
echo
echo "Then install the zed command on the server. Run this command there:"
echo
echo "    $remote_cmd"
echo
if [[ -n $token ]]; then
    echo "The command contains the token. Your shell can save it in its history on the server."
fi
if ((${#hosts[@]} > 1)); then
    echo "The command uses the host '${hosts[0]}'. Use -h to select a different one."
fi
