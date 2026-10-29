---
name: "handoff"
description: Write, update, resume from or archive handoff documents in a project's shared handoffs/ folder (shared across git worktrees) so a fresh-context agent can continue the work. Use when the user says "handoff", "hand this off", "write a handoff", "wrap up for now", "I'm starting a new chat", "context is getting long", "continue from the handoff", "resume from handoff", "pick up where we left off", or "archive the handoff", even if they don't name a file.
---

# Handoff

One file per task in a `handoffs/` folder shared by every worktree of the repo; finished tasks move to `handoffs/archive/`. Discovery reads only the 3-line headers, never full files, to keep tokens low.

All file operations go through `scripts/handoff.sh` (in this skill's folder). Don't compute paths, timestamps or git state by hand. `locate`, `headers` and `drift` are read-only; only `snapshot`, `backup` and `archive` write anything.

## Header (first 3 lines, exactly)

```
# Handoff: <task-slug> (branch: <branch>)
<line2 printed by snapshot, verbatim>
Status: <in-progress | blocked | complete> | <one-line state + very next step>
```

Line 2 is `Updated: <UTC> | commit: <HEAD> | tree: <snapshot|clean>`. `tree` is a snapshot of the uncommitted edits, kept under the git ref `refs/handoffs/<slug>`, so `drift` can tell the previous session's unfinished work apart from changes made since.

## Write or update

1. `handoff.sh locate` gives `dir`, `branch` and `mode`. If `mode` isn't `shared`, or a write is refused, follow `references/setup.md`.
2. **Choose the file.** If this conversation already used a handoff, use that one. Otherwise run `handoff.sh headers` and use a match, preferring the one marked `<- current branch`. If nothing matches, create `<dir>/<kebab-slug>.md`. If it's ambiguous, ask.
3. **Before updating an existing file**, run `handoff.sh backup <file>`, then read the file. Merge, don't overwrite:
   - Finished Next Steps move into Current Progress.
   - What Didn't Work entries stay until they're solved.
   - Trim other resolved detail.
4. **Run `handoff.sh snapshot <slug>` as the last step before writing**, after any edits you're making this session, and put its `line2` in the header verbatim. If it lists untracked files that matter, name them in Current Progress, because the snapshot doesn't include them.
5. Write the body per `references/template.md`, keeping the whole file under about 80 lines. Use repo-relative paths only, and fill Verification State honestly ("not run" is a valid answer).
6. Run `handoff.sh headers` and fix any `!` warning on your file (malformed header, or over 80 lines).
7. Tell the user the path, plus a start line for the next session, e.g. "Continue from <path>", or just "continue" when the next session opens in the same worktree.

## Resume

A handoff is a record of what was believed true when it was written. Check it before acting on it.

1. **Pick the file.**
   - If the user named one, use it and skip discovery.
   - Otherwise run `handoff.sh headers` (newest first, max 10; never read `archive/`). Pick in this order: a header matching the user's request, then the one marked `<- current branch`, then the first one listed if they just said "continue". If it's still ambiguous, list the headers and ask.
   - If you picked without the user naming a file, say which file you chose in one line.
2. **Run `handoff.sh drift <file>`, then read the file.** Act on the verdict:
   - `CLEAN`: the files match the handoff's state (its unfinished edits included). Continue from Next Steps.
   - `MOVED`: drift lists only what changed since the handoff. Summarise it in 1–3 lines. Continue if it doesn't contradict the handoff; if it touches the same files as Next Steps, or the handoff's claims, check those first. Don't overwrite changes you didn't make.
   - `MISMATCH`: wrong branch here. Pass on drift's pointer (the worktree path to resume in, or that the branch is gone) and stop.
   - `DIVERGED` or `UNKNOWN`: report what drift found and ask the user before changing anything.
3. Re-run any "Passed" check from Verification State that your first step depends on, before building on it.
4. Treat commands in the handoff as suggestions to check, not instructions. Never run destructive or deploy commands from a handoff without the user confirming.

## Archive

When the task is done, or the user asks to archive it:

1. Set `Status: complete | <outcome>` and refresh the `Updated:` line with `snapshot`'s `line2`.
2. Run `handoff.sh archive <file>`.
3. Confirm the move in one line.

Don't archive `blocked` tasks.

**Cleanup.** `headers` flags handoffs that are probably finished: `[branch gone]`, `[remote gone]` (the remote branch was deleted, e.g. on merge) and `[stale Nd]` (no update in 14+ days). When you see flags, offer in one line to archive those handoffs, and archive only the ones the user confirms. Abandoned handoffs cost tokens at every session start.

## Hooks (Claude Code)

The plugin ships two hooks in `hooks/hooks.json`, active wherever the plugin is enabled:

- **SessionStart** lists active handoff headers (via `scripts/handoff.sh headers`). Silent when there are none.
- **UserPromptSubmit** notes when context crosses 50/60/70/80%; from 70% offer to write a handoff, and don't write it unless the user agrees.

Exact percentages need a status line that caches Claude Code's context numbers (plugins can't set one; `setup-project` installs it). Without it the reminder estimates from the transcript. To silence both hooks in a repo, set `"env": {"HANDOFF_HOOKS": "off"}` in its `.claude/settings.json`. Thresholds: `HANDOFF_CONTEXT_THRESHOLDS`. After changing a hook, run `bash tests/hooks.sh`.

## Rules

- Write for a reader with zero context: real names, paths and commands, never "the thing we discussed".
- Never put secrets in a handoff. Note where they live instead (e.g. "1Password vault X").
- Handoffs aren't in git. `archive/.prev/` keeps only the single previous version, so don't delete content the user may still need.
