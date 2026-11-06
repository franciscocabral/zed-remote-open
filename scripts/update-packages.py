#!/usr/bin/env python3
"""Writes SHA256SUMS and updates the Homebrew formula and the Scoop manifest
for the version in the VERSION file. The release job runs it after
scripts/set-version.sh, so the files of the tag and their checksums agree.

--sums-only: writes only SHA256SUMS (to test the installers from a branch).

SHA256SUMS uses the paths of the repository (for example "remote/zed"): the
installers download it from the same tag as the files that they install.
"""

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/franciscocabral/zed-remote-open"
FILES = [
    "remote/zed",
    "remote/remote-linux-installer.sh",
    "local/zed-listener.pyw",
    "local/local-windows-installer.ps1",
    "local/local-unix-installer.sh",
]


def sha256(name: str) -> str:
    return hashlib.sha256((ROOT / name).read_bytes()).hexdigest()


def main() -> None:
    version = (ROOT / "VERSION").read_text().strip()
    sums = {name: sha256(name) for name in FILES}
    (ROOT / "SHA256SUMS").write_text("".join(f"{h}  {n}\n" for n, h in sums.items()))
    if "--sums-only" in sys.argv:
        # For a test from a branch: the formula and the manifest stay on the release.
        print("SHA256SUMS is up to date")
        return
    download = f"{REPO}/releases/download/v{version}"

    formula = ROOT / "Formula" / "zed-remote-open.rb"
    text = formula.read_text()
    text = re.sub(r"releases/download/v[0-9.]+/", f"releases/download/v{version}/", text)
    text = re.sub(r'^(  version ")[0-9.]+(")', rf"\g<1>{version}\2", text, flags=re.M)
    text = re.sub(r'(local-unix-installer\.sh"\n  version "[0-9.]+"\n  sha256 ")[0-9a-f]+(")',
                  rf"\g<1>{sums['local/local-unix-installer.sh']}\2", text)
    text = re.sub(r'(zed-listener\.pyw"\n    sha256 ")[0-9a-f]+(")',
                  rf"\g<1>{sums['local/zed-listener.pyw']}\2", text)
    formula.write_text(text)

    manifest_path = ROOT / "bucket" / "zed-remote-open.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["version"] = version
    manifest["url"] = [f"{download}/local-windows-installer.ps1", f"{download}/zed-listener.pyw"]
    manifest["hash"] = [sums["local/local-windows-installer.ps1"], sums["local/zed-listener.pyw"]]
    manifest_path.write_text(json.dumps(manifest, indent=4) + "\n")

    for name, value in ((formula, sums["local/local-unix-installer.sh"]),
                        (formula, sums["local/zed-listener.pyw"])):
        if value not in name.read_text():
            raise SystemExit(f"cannot update the checksums in {name}")
    print(f"SHA256SUMS, {formula.name} and {manifest_path.name} are for v{version}")


if __name__ == "__main__":
    main()
