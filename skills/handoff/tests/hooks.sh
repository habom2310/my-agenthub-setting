#!/usr/bin/env bash
# Tests for the plugin hooks in hooks/. Run: bash tests/hooks.sh   (exits non-zero on failure)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HANDOFF_HOOKS HANDOFF_CONTEXT_WINDOW HANDOFF_CONTEXT_THRESHOLDS
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/    /'; }
has()   { case "$2" in *"$3"*) ok;; *) bad "$1 (expected '$3')" "$2";; esac; }
empty() { [ -z "$2" ] && ok || bad "$1 (expected no output)" "$2"; }

turn() { # tokens -> one assistant transcript line
  printf '{"type":"assistant","message":{"usage":{"input_tokens":%s}}}\n' "$1"; }
remind() { # session transcript -> hook output
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$1" "$2" "$P" \
    | CLAUDE_PROJECT_DIR="$P" python3 "$ROOT/hooks/context_reminder.py"; }
start() { printf '{"cwd":"%s"}' "$P" | CLAUDE_PROJECT_DIR="$P" python3 "$ROOT/hooks/session_start.py"; }

P="$T/repo"; mkdir -p "$P" && cd "$P" && git init -q -b main && echo a > a && git add a && git commit -qm init
TR="$T/tr.jsonl"

# reminder: thresholds from transcript fallback (200k window)
turn 50000 > "$TR";  empty "below 50%" "$(remind s1 "$TR")"
turn 110000 > "$TR"; has "crosses 50%" "$(remind s1 "$TR")" "about 55% full"
empty "50% fires once" "$(remind s1 "$TR")"
turn 150000 > "$TR"; out="$(remind s1 "$TR")"; has "crosses 70%" "$out" "offer to write a handoff"
turn 20000 > "$TR";  empty "after compaction" "$(remind s1 "$TR")"
turn 110000 > "$TR"; has "re-armed after compaction" "$(remind s1 "$TR")" "about 55% full"

# reminder: exact numbers from a status-line cache win over the transcript
printf '{"used_percentage": 81, "context_window_size": 1000000, "ts": %s}' "$(date +%s)" > "$TMPDIR/claude-ctx-s2.json"
turn 10000 > "$TR";  has "status-line cache used" "$(remind s2 "$TR")" "about 81% full (~810k of 1000k"

# opt-out and legacy defer
turn 190000 > "$TR"
empty "HANDOFF_HOOKS=off" "$(HANDOFF_HOOKS=off remind s3 "$TR")"
mkdir -p .claude/hooks && touch .claude/hooks/handoff_context_reminder.py
empty "defers to legacy project hook" "$(remind s4 "$TR")"
empty "session start defers too" "$(start)"
rm -rf .claude

# session start: silent with none, lists headers when present
empty "no handoffs" "$(start)"
snap="$(bash "$ROOT/scripts/handoff.sh" snapshot demo)"
printf '# Handoff: demo (branch: main)\n%s\nStatus: in-progress | test\n' "$(printf '%s\n' "$snap" | sed -n 's/^line2=//p')" > handoffs/demo.md
has "lists headers" "$(start)" "# Handoff: demo (branch: main)"

echo "hooks: $pass passed, $fail failed"; [ "$fail" = 0 ]
