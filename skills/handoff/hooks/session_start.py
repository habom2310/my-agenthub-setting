#!/usr/bin/env python3
"""SessionStart: inject active handoff headers (newest first, max 10, with cleanup flags).

Calls the skill's own scripts/handoff.sh, so there is no copy to keep in sync.
Prints nothing when there are no handoffs. Read-only.
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import disabled  # noqa: E402

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "handoff.sh"


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    if disabled(data):
        return
    r = subprocess.run(["bash", str(SCRIPT), "headers"], cwd=data.get("cwd") or None,
                       capture_output=True, text=True, timeout=8)
    out = r.stdout.strip()
    if r.returncode != 0 or not out or out.startswith("(no active handoffs"):
        return
    ctx = (
        "Active handoffs in this repo (headers only, newest first):\n" + out + "\n"
        "Mention this in one line if relevant to the user's first message. Don't read a handoff "
        "in full unless the user wants to continue that work; then follow the handoff skill's "
        "resume steps (drift check first). If any are flagged [branch gone], [remote gone] or "
        "[stale], offer once to archive them."
    )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never block a session start
