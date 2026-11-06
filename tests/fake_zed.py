"""Fake "zed" command for the tests: writes its arguments to a file."""

import json
import sys
import time

calls_file, *args = sys.argv[1:]
with open(calls_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(args) + "\n")
if "--wait" in args:
    time.sleep(0.5)  # The user edits the file.
