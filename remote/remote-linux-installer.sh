#!/usr/bin/env bash
# Installs the zed command of zed-remote-open in ~/.local/bin.
#
# Usage: remote-linux-installer.sh [-h HOST] [-p PORT] [-t TARGET] [-k TOKEN] [-y] [-f]
#        remote-linux-installer.sh -u [-y]
#
#   -h HOST    SSH host name that the local computer uses for this server.
#   -p PORT    Port of the RemoteForward on this server (default 7682).
#   -t TARGET  Address of the listener (default 127.0.0.1).
#   -k TOKEN   Token of the listener. Without -k, the current token stays.
#   -y         Ask no questions: use the given, current or default values.
#   -f         Replace a newer version or a zed command of a different program,
#              or install a zed of a different version than the installer.
#   -u         Uninstall.
#
# The local installer shows this command with the correct options.
#
# If zed is already installed, it compares the versions. It updates an older
# version, keeps the same version, and stops for a newer version or for a
# zed command that is not from zed-remote-open.
set -euo pipefail

# The installer installs only the zed of the same version (set by scripts/set-version.sh).
INSTALLER_VERSION="1.2.0"
BASE_URL="${ZED_REMOTE_OPEN_URL:-https://github.com/franciscocabral/zed-remote-open/raw/v1.2.0}"
BIN_DIR="$HOME/.local/bin"
DEST="$BIN_DIR/zed"
BROWSE_LINK="$BIN_DIR/zed-browse"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zed-remote-open"
CONFIG_FILE="$CONFIG_DIR/settings.json"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zed-remote-open"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF2'
Usage: remote-linux-installer.sh [-h HOST] [-p PORT] [-t TARGET] [-k TOKEN] [-y] [-f]
       remote-linux-installer.sh -u [-y]

  -h HOST    SSH host name that the local computer uses for this server.
  -p PORT    Port of the RemoteForward on this server (default 7682).
  -t TARGET  Address of the listener (default 127.0.0.1).
  -k TOKEN   Token of the listener. Without -k, the current token stays.
  -y         Ask no questions: use the given, current or default values.
  -f         Replace a newer version or a zed command of a different program,
             or install a zed of a different version than the installer.
  -u         Uninstall.
EOF2
}

# --- Options ---

declare -A given=()
force=0 yes=0 uninstall=0
while getopts ":h:p:t:k:yfu" o; do
    case $o in
        h) given[host]=$OPTARG ;;
        p) given[port]=$OPTARG ;;
        t) given[target]=$OPTARG ;;
        k) given[token]=$OPTARG ;;
        y) yes=1 ;;
        f) force=1 ;;
        u) uninstall=1 ;;
        :) die "option -$OPTARG needs a value" ;;
        *) usage >&2; exit 1 ;;
    esac
done

interactive=0
[[ -t 0 && $yes == 0 ]] && interactive=1

# confirm QUESTION: returns 0 for yes. With -y, the answer is yes.
confirm() {
    local answer
    ((yes)) && return 0
    ((interactive)) || die "$1 Use -y to answer yes."
    read -r -p "$1 [y/N] " answer </dev/tty || answer=""
    [[ $answer == [yY]* ]]
}

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

# --- Uninstall ---

if ((uninstall)); then
    if [[ -e $DEST && $(version_of "$DEST") == none ]]; then
        warn "$DEST is not from zed-remote-open. It stays."
        targets=()
    else
        targets=("$DEST")
    fi
    if [[ -L $BROWSE_LINK ]]; then targets+=("$BROWSE_LINK"); fi
    targets+=("$CONFIG_DIR" "$CACHE_DIR")
    echo "This removes:"
    printf '  %s\n' "${targets[@]}" "$DEST.bak.* (backup copies)"
    confirm "Continue?" || die "uninstall stopped"
    rm -rf -- "${targets[@]}"
    rm -f -- "$DEST".bak.*
    info "Removed. The listener on the local computer stays installed."
    exit 0
fi

# --- Requirements ---

((BASH_VERSINFO[0] >= 4)) || die "Bash 4 or later is necessary (you have $BASH_VERSION)"
for cmd in realpath dirname hostname mktemp sort sed grep sha256sum; do
    command -v "$cmd" >/dev/null || die "the '$cmd' command is necessary"
done

# --- Checksums ---

# verify_checksum FILE NAME: compares the SHA-256 of FILE with the line of NAME
# in SHA256SUMS of the same version. It finds a damaged or changed download.
verify_checksum() {
    local file=$1 name=$2 sums expected actual
    sums=$(curl -fsSL "$BASE_URL/SHA256SUMS" 2>/dev/null) || sums=""
    expected=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' <<<"$sums" | head -n 1)
    actual=$(sha256sum <"$file" | cut -d' ' -f1)
    if [[ -z $expected ]]; then
        ((force)) || die "cannot get the checksum of $name from $BASE_URL/SHA256SUMS (use -f to install without the check)"
        warn "no checksum for $name: installed without the check (-f)"
    elif [[ $expected != "$actual" ]]; then
        ((force)) || die "the checksum of $name is not correct: the download is damaged or changed (use -f to install it anyway)"
        warn "the checksum of $name is not correct: installed anyway (-f)"
    else
        info "Checksum of $name: correct"
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
    verify_checksum "$tmp" remote/zed
fi
grep -q '^# zed-remote-open:' "$tmp" || die "the zed script is not correct (no zed-remote-open header)"

new_version=$(version_of "$tmp")
[[ $new_version != none && $new_version != unknown ]] || die "the zed script has no version"
if [[ $new_version != "$INSTALLER_VERSION" ]] && ((!force)); then
    die "this installer is version $INSTALLER_VERSION, but the zed script is $new_version.
       Use the installer and zed of the same version: set ZED_REMOTE_OPEN_URL to
       https://github.com/franciscocabral/zed-remote-open/raw/v$INSTALLER_VERSION (or use -f)."
fi
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
            ((force)) || confirm "Replace it? (a backup copy is kept)" || die "installation stopped"
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
        token) [[ $2 =~ ^[A-Za-z0-9_-]+$ ]] && ((${#2} >= 16 && ${#2} <= 256)) ;;
    esac
}

# Current value from an earlier installation, if there is one.
current() {
    [[ -f $CONFIG_FILE ]] || return 0
    local re="\"$1\"[[:space:]]*:[[:space:]]*(\"([^\"]*)\"|([0-9]+))"
    [[ $(<"$CONFIG_FILE") =~ $re ]] && echo "${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    return 0
}

# ask KEY DEFAULT QUESTION EXPLANATION
ask() {
    local key=$1 default=$2 question=$3 value
    if [[ -n ${given[$key]-} ]]; then
        value=${given[$key]}
        valid "$key" "$value" || die "'$value' is not a valid $key"
        echo "$value"
        return
    fi
    if ((interactive)); then
        printf '\n%s\n' "$4" >&2
    fi
    while true; do
        value=""
        if ((interactive)); then
            read -r -p "$question [$default]: " value </dev/tty || value=""
        fi
        value=${value:-$default}
        if valid "$key" "$value"; then
            echo "$value"
            return
        fi
        ((interactive)) || die "'$value' is not a valid $key"
        warn "'$value' is not a valid $key. Try again."
    done
}

default_host=$(current host)
[[ -n $default_host ]] || default_host=$(hostname -s)
default_port=$(current port)
default_target=$(current target)

host=$(ask host "$default_host" "SSH host name of this server" \
    "The host is the SSH host name that your local computer uses for this server
(the 'Host' line in its ~/.ssh/config). The listener must allow this name.")
port=$(ask port "${default_port:-7682}" "Listener port" \
    "The port is the port on this server where the SSH RemoteForward listens.")
target=$(ask target "${default_target:-127.0.0.1}" "Listener address" \
    "The target is the address of the listener. Use 127.0.0.1 with the SSH RemoteForward.")

token=${given[token]-}
if [[ -n $token ]]; then
    valid token "$token" || die "the token is not valid (16 to 256 letters, digits, '_' or '-')"
elif ((interactive)); then
    printf '\n%s\n' "If the listener uses a token, paste it here. Press Enter to keep the current value." >&2
    read -r -s -p "Token [$(if [[ -n $(current token) ]]; then echo "keep current"; else echo "none"; fi)]: " token </dev/tty || token=""
    echo >&2
    if [[ -n $token ]] && ! valid token "$token"; then
        die "the token is not valid (16 to 256 letters, digits, '_' or '-')"
    fi
fi
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
# "zed-browse URL" opens a URL in the local browser (for BROWSER=zed-browse).
if [[ ! -e $BROWSE_LINK || -L $BROWSE_LINK ]]; then
    ln -sfn -- zed "$BROWSE_LINK"
else
    warn "$BROWSE_LINK exists and is not a link to zed: it stays"
fi

settings=(-c "host:$host" -c "port:$port" -c "target:$target")
[[ -z $token ]] || settings+=(-c "token:$token")
"$DEST" "${settings[@]}" >/dev/null
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

echo
if "$DEST" --doctor; then
    echo
    info "Done. Try: zed .     (help: zed --help)"
    echo
    echo "Optional, in your shell startup file:"
    echo "  export BROWSER=zed-browse                 # server URLs open in the local browser"
    echo "  eval \"\$(zed --completion zsh)\"           # zsh (after compinit); bash: --completion bash"
    echo "  git config --global core.editor \"zed -w\"  # Git opens files in Zed"
else
    echo
    warn "zed is installed, but it cannot use the listener now. Read the [fail] line above."
fi
