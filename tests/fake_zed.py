"""Fake command for the tests (zed, ssh, a browser...): writes its arguments to a file."""

import json
import os
import sys
import time

calls_file, *args = sys.argv[1:]
if "-G" in args:  # "ssh -G host": print the configuration.
    print(os.environ.get("FAKE_SSH_G", "hostname example"))
    sys.exit(0)
with open(calls_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(args) + "\n")
if "-N" in args:  # "ssh -N": a tunnel that stops at once.
    time.sleep(0.2)
    sys.exit(255)
