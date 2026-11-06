#!/usr/bin/env bash
# Makes sure that VERSION, remote/zed and the listener have the same version.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
file=$(tr -d '[:space:]' <VERSION)
zed=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' remote/zed)
listener=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' local/zed-listener.pyw)
remote_inst=$(sed -n 's/^INSTALLER_VERSION="\(.*\)"$/\1/p' remote/remote-linux-installer.sh)
unix_inst=$(sed -n 's/^INSTALLER_VERSION="\(.*\)"$/\1/p' local/local-unix-installer.sh)
win_inst=$(sed -n "s/^[$]InstallerVersion = '\(.*\)'$/\1/p" local/local-windows-installer.ps1)
echo "VERSION=$file remote/zed=$zed listener=$listener remote-installer=$remote_inst" \
    "unix-installer=$unix_inst windows-installer=$win_inst"
for v in "$zed" "$listener" "$remote_inst" "$unix_inst" "$win_inst"; do
    [[ $v == "$file" ]] || { echo "The versions are different." >&2; exit 1; }
done
