#!/usr/bin/env bash
# Installs the zed command of zed-remote-open in ~/.local/bin.
#
# Usage: remote-linux-installer.sh [-h HOST] [-p PORT] [-t TARGET] [-f]
#
# It asks for each value that you do not give. Without a terminal, it uses
# the current setting or the default value.
#
# If zed is already installed, it compares the versions. It updates an older
# version, keeps the same version, and stops for a newer version or for a
# zed command that is not from zed-remote-open. -f replaces it in all cases.
set -euo pipefail

BASE_URL="${ZED_REMOTE_OPEN_URL:-https://github.com/franciscocabral/zed-remote-open/raw/main}"
BIN_DIR="$HOME/.local/bin"
DEST="$BIN_DIR/zed"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/zed-remote-open/settings.json"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
    exit 1
}

usage() {
    echo "Usage: remote-linux-installer.sh [-h HOST] [-p PORT] [-t TARGET] [-f]" >&2
}

# --- Options ---

declare -A given=()
force=0
while getopts ":h:p:t:f" o; do
    case $o in
        h) given[host]=$OPTARG ;;
        p) given[port]=$OPTARG ;;
        t) given[target]=$OPTARG ;;
        f) force=1 ;;
        :) die "option -$OPTARG needs a value" ;;
        *) usage; exit 1 ;;
    esac
done

# --- Requirements ---

((BASH_VERSINFO[0] >= 4)) || die "Bash 4 or later is necessary (you have $BASH_VERSION)"
for cmd in realpath dirname hostname mktemp sort sed grep; do
    command -v "$cmd" >/dev/null || die "the '$cmd' command is necessary"
done
command -v git >/dev/null ||
    warn "git is not installed. zed will not open the Git root of a file."

# --- Versions ---

# Prints the version of a zed file: X.Y.Z, "unknown" (zed-remote-open with
# no version) or "none" (not zed-remote-open).
version_of() {
    local file=$1 v
    v=$(sed -n 's/^VERSION="\([0-9][0-9.]*\)"$/\1/p' -- "$file" 2>/dev/null | head -n 1)
    if [[ -n $v ]]; then
        echo "$v"
    elif grep -qs -e '^# zed-remote-open:' -e '/dev/tcp/' -- "$file"; then
        echo unknown
    else
        echo none
    fi
}

# Prints lt, eq or gt.
compare_versions() {
    if [[ $1 == "$2" ]]; then
        echo eq
    elif [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1) == "$1" ]]; then
        echo lt
    else
        echo gt
    fi
}

# --- New version ---

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
tmp=$(mktemp)
trap 'rm -f -- "$tmp"' EXIT

if [[ -n $script_dir && -f $script_dir/zed ]]; then
    info "Using $script_dir/zed"
    cp -- "$script_dir/zed" "$tmp"
else
    command -v curl >/dev/null || die "the 'curl' command is necessary to download the zed script"
    info "Downloading $BASE_URL/remote/zed"
    curl -fsSL "$BASE_URL/remote/zed" -o "$tmp" || die "cannot download the zed script"
fi
grep -q '^# zed-remote-open:' "$tmp" || die "the zed script is not correct (no zed-remote-open header)"

new_version=$(version_of "$tmp")
[[ $new_version != none && $new_version != unknown ]] || die "the zed script has no version"
info "New version: $new_version"

# --- Installed versions ---

declare -A seen_bin=()
while IFS= read -r bin; do
    [[ -n $bin && -z ${seen_bin[$bin]+set} ]] || continue
    seen_bin[$bin]=1
    [[ $bin == "$DEST" ]] && continue
    v=$(version_of "$bin")
    if [[ $v == none ]]; then
        info "Found a different zed command (not zed-remote-open): $bin"
    elif [[ $v == unknown ]]; then
        info "Found an old zed-remote-open with no version number at $bin (this installer does not change it)"
    else
        info "Found zed-remote-open $v at $bin (this installer does not change it)"
    fi
done < <(type -ap zed 2>/dev/null || true)

replace=1
if [[ -e $DEST ]]; then
    old_version=$(version_of "$DEST")
    case $old_version in
        none)
            warn "$DEST is not from zed-remote-open."
            if ((!force)); then
                [[ -t 0 ]] || die "use -f to replace it"
                read -r -p "Replace it? (a backup copy is kept) [y/N] " answer </dev/tty || answer=""
                [[ $answer == [yY]* ]] || die "installation stopped"
            fi
            ;;
        unknown)
            info "Installed: an old version with no version number. It will be updated." ;;
        *)
            case $(compare_versions "$old_version" "$new_version") in
                lt) info "Installed: $old_version. It will be updated to $new_version." ;;
                eq)
                    if ((force)); then
                        info "Installed: $old_version (same version). -f: it will be installed again."
                    else
                        info "Installed: $old_version (same version). The file stays; only the settings change."
                        replace=0
                    fi
                    ;;
                gt)
                    ((force)) || die "the installed version $old_version is newer than $new_version. Use -f to install $new_version."
                    warn "Installed: $old_version (newer). -f: it will be replaced by $new_version."
                    ;;
            esac
            ;;
    esac
fi

# --- Values ---

valid() {
    case $1 in
        host) [[ $2 =~ ^[A-Za-z0-9._-]+$ ]] ;;
        port) [[ $2 =~ ^[0-9]{1,5}$ ]] && ((10#$2 >= 1 && 10#$2 <= 65535)) ;;
        target) [[ $2 =~ ^[A-Za-z0-9.-]+$ ]] ;;
    esac
}

# Current value from an earlier installation, if there is one.
current() {
    [[ -f $CONFIG_FILE ]] || return 0
    local re="\"$1\"[[:space:]]*:[[:space:]]*(\"([^\"]*)\"|([0-9]+))"
    [[ $(<"$CONFIG_FILE") =~ $re ]] && echo "${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    return 0
}

# ask KEY DEFAULT QUESTION
ask() {
    local key=$1 default=$2 question=$3 value
    if [[ -n ${given[$key]-} ]]; then
        value=${given[$key]}
        valid "$key" "$value" || die "'$value' is not a valid $key"
        echo "$value"
        return
    fi
    while true; do
        if [[ -t 0 ]]; then
            read -r -p "$question [$default]: " value </dev/tty || value=""
        else
            value=""
        fi
        value=${value:-$default}
        if valid "$key" "$value"; then
            echo "$value"
            return
        fi
        [[ -t 0 ]] || die "'$value' is not a valid $key"
        warn "'$value' is not a valid $key. Try again."
    done
}

host_default=$(current host)
port_default=$(current port)
target_default=$(current target)

echo
echo "The host is the SSH host name that your Windows computer uses for this"
echo "server (the 'Host' line in its ~/.ssh/config). The Windows listener must"
echo "allow this name (--hosts)."
host=$(ask host "${host_default:-$(hostname -s)}" "SSH host name of this server")

echo
echo "The port is the port on this server where the SSH RemoteForward listens."
port=$(ask port "${port_default:-7682}" "Listener port")

echo
echo "The target is the address of the listener. Use 127.0.0.1 with the SSH"
echo "RemoteForward."
target=$(ask target "${target_default:-127.0.0.1}" "Listener address")
echo

# --- Install ---

if ((replace)); then
    mkdir -p -- "$BIN_DIR"
    if [[ -e $DEST ]] && ! cmp -s -- "$tmp" "$DEST"; then
        backup="$DEST.bak.$(date +%Y%m%d%H%M%S)"
        [[ ! -e $backup ]] || backup="$backup.$$"
        cp -p -- "$DEST" "$backup"
        info "Saved the old $DEST as $backup"
    fi
    install -m 755 -- "$tmp" "$DEST"
    info "Installed zed-remote-open $new_version in $DEST"
fi

"$DEST" -c "host:$host" -c "port:$port" -c "target:$target" >/dev/null
info "Saved the settings in $CONFIG_FILE"

# --- Checks ---

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not in PATH. Add this line to your shell startup file (~/.zshrc or ~/.bashrc):
    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

found=$(command -v zed || true)
if [[ -n $found && $found != "$DEST" ]]; then
    warn "'zed' in PATH is $found, not $DEST. Put $BIN_DIR before $(dirname -- "$found") in PATH."
fi

if timeout 3 bash -c "exec 3<>/dev/tcp/$target/$port" 2>/dev/null; then
    info "The listener at $target:$port is available."
else
    warn "Cannot connect to $target:$port now. To fix this:
    1. Install the listener on Windows (local/local-windows-installer.ps1) and allow the host '$host'.
    2. Add 'RemoteForward 127.0.0.1:$port 127.0.0.1:<Windows port>' to the '$host' entry of
       ~/.ssh/config on Windows.
    3. Close this SSH session and connect again."
fi

echo
info "Done. Try: zed .     (help: zed --help)"
