#!/usr/bin/env python3
"""UserPromptSubmit: remind once each time context usage crosses 50/60/70/80%.

Where the numbers come from, best first:
  1. Claude Code's own figures, cached per session by a status line that writes
     $TMPDIR/claude-ctx-<session>.json (setup-project installs one). Exact, no config.
     Plugins can't set a status line, so this part stays in setup-project.
  2. Fallback (no status line yet, headless runs): the transcript's last main-thread turn
     (input + cache tokens) over the window: HANDOFF_CONTEXT_WINDOW if set, else the window
     last seen by the status line in any session, else 200k (1M once usage passes 200k).
Optional settings.json "env": HANDOFF_CONTEXT_WINDOW, HANDOFF_CONTEXT_THRESHOLDS ("50,60,70,80").
"""
import time
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import disabled  # noqa: E402

TAIL_BYTES = 512 * 1024
TMP = Path(tempfile.gettempdir())
FRESH_SECONDS = 15 * 60


def from_statusline(sid):
    """(percent, window) from the status-line cache for this session, if fresh."""
    try:
        c = json.loads((TMP / f"claude-ctx-{sid}.json").read_text())
        if time.time() - c["ts"] < FRESH_SECONDS and c.get("used_percentage") is not None:
            return int(c["used_percentage"]), int(c["context_window_size"])
    except Exception:
        pass
    return None


def last_known_window():
    """Window size from the most recent status-line cache of any session."""
    try:
        latest = max(TMP.glob("claude-ctx-*.json"), key=lambda p: p.stat().st_mtime)
        return int(json.loads(latest.read_text())["context_window_size"])
    except Exception:
        return None


def used_tokens(transcript):
    """Context size at the most recent main-thread assistant turn, or None."""
    p = Path(transcript)
    if not p.is_file():
        return None
    with p.open("rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - TAIL_BYTES))
        chunk = f.read().decode("utf-8", errors="ignore")
    for line in reversed(chunk.splitlines()):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") != "assistant" or e.get("isSidechain"):
            continue
        u = (e.get("message") or {}).get("usage") or {}
        total = sum(int(u.get(k) or 0) for k in
                    ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
        if total:
            return total
    return None


def main():
    data = json.load(sys.stdin)
    if disabled(data):
        return
    sid = data.get("session_id") or "unknown"
    exact = None if os.environ.get("HANDOFF_CONTEXT_WINDOW") else from_statusline(sid)
    if exact:
        pct, window = exact
        used = pct * window // 100
    else:
        used = used_tokens(data.get("transcript_path") or "")
        if used is None:
            return
        window = int(os.environ.get("HANDOFF_CONTEXT_WINDOW") or last_known_window() or 0)
        if not window:
            window = 1000000 if used > 200000 else 200000
        pct = used * 100 // window
    thresholds = sorted(int(x) for x in
                        (os.environ.get("HANDOFF_CONTEXT_THRESHOLDS") or "50,60,70,80").split(",") if x.strip())

    state_file = Path(tempfile.gettempdir()) / f"claude-handoff-ctx-{sid}.json"
    try:
        fired = set(json.loads(state_file.read_text()))
    except Exception:
        fired = set()
    # Context dropped (compaction or /clear): re-arm thresholds above the current level.
    fired = {t for t in fired if t <= pct}

    crossed = [t for t in thresholds if t <= pct and t not in fired]
    state_file.write_text(json.dumps(sorted(fired | set(crossed))))
    if not crossed:
        return

    top = max(crossed)
    msg = f"Context is about {pct}% full (~{used // 1000}k of {window // 1000}k tokens)."
    # Auto-compaction may fire before 80%, so the firm offer starts at 70%.
    if top >= 70:
        hint = ("Before answering, tell the user in one line and offer to write a handoff now "
                "(handoff skill) so the work survives compaction. Don't write it unless they agree.")
    elif top >= 60:
        hint = "Mention it in one line at the end of your reply and suggest a handoff at the next natural stopping point."
    else:
        hint = "Mention it in one short line at the end of your reply. No action needed yet."
    print(json.dumps({
        "systemMessage": f"Handoff reminder: {msg}",
        "hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                               "additionalContext": f"{msg} {hint}"},
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never block a prompt
