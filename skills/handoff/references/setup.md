# Setup, modes and migration

Read this only when `locate` reports a non-shared mode, a write is refused, or old-format handoffs exist.

## Modes reported by `handoff.sh locate`

- `shared`: the usual case. The folder is `<main checkout>/handoffs/`, or `handoffs/` next to the bare repo in a bare-repo layout. It's shared by every worktree, and `/handoffs/` is added to `.git/info/exclude` automatically.
- `local`: the shared folder isn't writable or reachable (e.g. a container mounting only this worktree), so the handoff is in this worktree's own `handoffs/`. Tell the user in one line that this handoff isn't shared, and that it must be archived or moved before the worktree is removed.
- `nogit`: not a git repo. The handoff goes in `./handoffs/`, and `drift` can only report the handoff's age.

## Write refused by permissions

Claude Code limits edits to the directory a session started in, and the shared folder sits outside a worktree. Don't silently fall back. Give the user the exact `dir` and ask them to allow it once, in `.claude/settings.json`:

```json
{ "permissions": { "additionalDirectories": ["<dir>"] } }
```

Or run `/add-dir <dir>` for a single session. Then retry.

## Migrating old-format handoffs

If `HANDOFF.md` exists at a worktree root, or a worktree-local `handoffs/` exists while `mode=shared`:

1. Move each file into `dir` as `<slug>.md`.
2. Rewrite its header to the current 3-line format, with line 2 from `handoff.sh snapshot <slug>`.
3. Delete the originals.

Headers from earlier versions (a local-time offset like `+11:00`, or a line 2 without `| tree:`) show as malformed. Fix them the same way: run `snapshot` and replace line 2 with its output.

## Tests

`bash tests/run.sh` runs the regression suite for `scripts/handoff.sh`. Run it after any change to the script.
