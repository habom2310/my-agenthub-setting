"""Shared checks for the handoff plugin's hooks."""
import os
from pathlib import Path

LEGACY = "handoff_context_reminder.py"  # setup-project's old project-level copy


def disabled(data):
    """True when these hooks should stay silent in this session.

    - HANDOFF_HOOKS=off in a settings "env" block opts a repo (or everything) out.
    - A repo still carrying setup-project's old project-level handoff hooks keeps those
      until setup-project is re-run there, so the reminder never fires twice.
    """
    if (os.environ.get("HANDOFF_HOOKS") or "").lower() in ("off", "0", "false"):
        return True
    root = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or ""
    return bool(root) and (Path(root) / ".claude" / "hooks" / LEGACY).exists()
