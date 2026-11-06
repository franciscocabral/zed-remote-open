#!/usr/bin/env bash
# Writes VERSION in all the files, and points the download URLs to the tag vVERSION.
# Usage: scripts/set-version.sh 2.1.0
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

v=${1:?usage: set-version.sh VERSION}
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid version: $v" >&2; exit 1; }

echo "$v" >VERSION
sed -i.bak -E "s/^VERSION=\"[0-9.]+\"/VERSION=\"$v\"/" remote/zed
sed -i.bak -E "s/^__version__ = \"[0-9.]+\"/__version__ = \"$v\"/" local/zed-listener.pyw
for f in remote/remote-linux-installer.sh local/local-unix-installer.sh; do
    sed -i.bak -E "s/^INSTALLER_VERSION=\"[0-9.]+\"/INSTALLER_VERSION=\"$v\"/" "$f"
done
sed -i.bak -E "s/^[$]InstallerVersion = '[0-9.]+'/\$InstallerVersion = '$v'/" local/local-windows-installer.ps1
for f in README.md local/local-windows-installer.ps1 local/local-unix-installer.sh remote/remote-linux-installer.sh; do
    sed -i.bak -E \
        -e "s#(zed-remote-open/raw/)[A-Za-z0-9._-]+/#\1v$v/#g" \
        -e "s#(zed-remote-open/raw/)[A-Za-z0-9._-]+(['\"}])#\1v$v\2#g" \
        -e "s#(zed-remote-open/releases/download/)v[0-9.]+#\1v$v#g" \
        -e "s#(<!-- version -->)[^<]*(<!-- /version -->)#\1v$v\2#g" \
        "$f"
    rm -f -- "$f.bak"
done
rm -f -- remote/zed.bak local/zed-listener.pyw.bak
