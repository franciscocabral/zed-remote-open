#!/usr/bin/env bash
# Makes sure that VERSION, remote/zed and the listener have the same version.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
file=$(tr -d '[:space:]' <VERSION)
zed=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' remote/zed)
listener=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' local/zed-listener.pyw)
echo "VERSION=$file remote/zed=$zed listener=$listener"
[[ $file == "$zed" && $file == "$listener" ]] || { echo "The versions are different." >&2; exit 1; }
