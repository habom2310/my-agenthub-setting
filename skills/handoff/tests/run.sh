#!/usr/bin/env bash
# Regression tests for scripts/handoff.sh. Run: bash tests/run.sh   (exits non-zero on failure)
set -u
H="$(cd "$(dirname "$0")/.." && pwd)/scripts/handoff.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/    /'; }
has()   { case "$2" in *"$3"*) ok;; *) bad "$1 (expected '$3')" "$2";; esac; }
lacks() { case "$2" in *"$3"*) bad "$1 (unexpected '$3')" "$2";; *) ok;; esac; }
get()   { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

write_handoff() { # dir slug status -> writes file using snapshot
  local snap; snap="$(bash "$H" snapshot "$2")"
  printf '# Handoff: %s (branch: %s)\n%s\nStatus: %s | test\n\n## Goal\nx\n' \
    "$2" "$(get "$snap" branch)" "$(get "$snap" line2)" "${3:-in-progress}" > "$1/$2.md"
}

# --- setup: main checkout + worktree ---
cd "$T" && git init -q -b main main && cd main && echo a > a && git add a && git commit -qm init
git worktree add -q ../wt -b feat/alerts
EXCL_BEFORE="$(cat .git/info/exclude 2>/dev/null)"

# 1. read-only commands have no side effects
out="$(cd ../wt && bash "$H" locate)"; D="$(get "$out" dir)"
has "locate: shared dir from worktree" "$out" "dir=$T/main/handoffs"
has "locate: shared mode" "$out" "mode=shared"
(cd ../wt && bash "$H" headers >/dev/null)
[ ! -e "$D" ] && ok || bad "locate/headers created $D"
[ "$(cat .git/info/exclude 2>/dev/null)" = "$EXCL_BEFORE" ] && ok || bad "read-only commands changed .git/info/exclude"

# 2. snapshot: clean vs dirty, ref kept, untracked listed
cd ../wt
out="$(bash "$H" snapshot clean-task)"; has "snapshot clean" "$out" "| tree: clean"
grep -qxF "/handoffs/" "$T/main/.git/info/exclude" && ok || bad "write didn't add exclude"
echo "wip" >> a; echo new > untracked.txt
write_handoff "$D" alerts
line2="$(sed -n 2p "$D/alerts.md")"; lacks "snapshot dirty" "$line2" "tree: clean"
git show-ref --verify --quiet refs/handoffs/alerts && ok || bad "snapshot ref missing"
has "snapshot lists untracked" "$(bash "$H" snapshot tmp-x)" "untracked.txt"
git update-ref -d refs/handoffs/tmp-x

# 3. drift
out="$(bash "$H" drift "$D/alerts.md")"
has "drift: own WIP is CLEAN" "$out" "verdict: CLEAN"
has "drift: WIP still present" "$out" "still present, unchanged"
echo other > b; git add b                      # someone else's change
out="$(bash "$H" drift "$D/alerts.md")"
has "drift: new change -> MOVED" "$out" "verdict: MOVED"; has "drift: lists b" "$out" "  b"
lacks "drift: own WIP not reported as change" "$out" "  a"
git rm -q --cached b; rm b
git commit -qam "commit wip as-is"
out="$(bash "$H" drift "$D/alerts.md")"
has "drift: committed as-is -> identical" "$out" "identical to the handoff's state"
has "drift: committed as-is -> CLEAN" "$out" "verdict: CLEAN"
git reset -q --hard HEAD~1; git commit -q --allow-empty -m rewrite
write_handoff "$D" div; git commit -q --allow-empty -m x; git reset -q --hard HEAD~2
out="$(bash "$H" drift "$D/div.md")"; has "drift: reset past -> DIVERGED" "$out" "verdict: DIVERGED"

# 4. mismatch points at the right worktree
out="$(cd "$T/main" && bash "$H" drift "$D/alerts.md")"
has "mismatch verdict" "$out" "verdict: MISMATCH"; has "mismatch shows worktree" "$out" "checked out at: $T/wt"

# 5. headers: newest first, cap, flags, current-branch mark, validation
cd "$T/main"; git branch -q gone-br; git branch -q old-br
mk() { printf '# Handoff: %s (branch: %s)\nUpdated: %s | commit: none | tree: none\nStatus: in-progress | t\n' "$1" "$2" "$3" > "$D/$1.md"; }
for i in 01 02 03 04 05 06 07 08 09 10 11; do mk "h$i" main "2099-01-${i}T00:00Z"; done
mk gone gone-br 2099-02-01T00:00Z; git branch -q -D gone-br
mk old old-br 2000-01-01T00:00Z
printf 'oops\n' > "$D/broken.md"
seq 1 90 | sed 's/^/x/' >> "$D/h11.md"
out="$(bash "$H" headers)"
first="$(printf '%s\n' "$out" | grep '^== ' | head -1)"; has "headers newest first" "$first" "gone.md"
has "headers cap" "$out" "older; run 'headers --all'"
has "flag branch gone" "$out" "gone.md [branch gone]"
lacks "capped list hides oldest" "$out" "old.md"
has "--all shows stale" "$(bash "$H" headers --all)" "old.md [stale"
has "current branch mark" "$out" "<- current branch"
has "line-count warning" "$out" "lines (limit 80)"
has "malformed warning" "$(bash "$H" headers --all)" "line 1 malformed"
rm "$D"/h*.md "$D/gone.md" "$D/old.md" "$D/broken.md"

# 5b. remote branch deleted after merge -> [remote gone]
cd "$T" && git init -q --bare origin.git && git clone -q origin.git cl 2>/dev/null && cd cl
git commit -q --allow-empty -m i && git push -q origin HEAD:main 2>/dev/null
git switch -q -c feat/merged && git push -q -u origin feat/merged 2>/dev/null
mkdir -p handoffs && printf '# Handoff: m (branch: feat/merged)\nUpdated: 2099-01-01T00:00Z | commit: none | tree: none\nStatus: in-progress | t\n' > handoffs/m.md
git push -q origin --delete feat/merged 2>/dev/null && git fetch -q --prune
has "flag remote gone" "$(bash "$H" headers)" "m.md [remote gone]"
cd "$T/main"

# 6. archive removes file, ref and backup
cd "$T/wt"; bash "$H" backup "$D/alerts.md" >/dev/null
out="$(bash "$H" archive "$D/alerts.md")"; has "archive" "$out" "archived to"
[ ! -e "$D/alerts.md" ] && [ ! -e "$D/archive/.prev/alerts.md" ] && ok || bad "archive left files behind"
git show-ref --verify --quiet refs/handoffs/alerts && bad "archive kept snapshot ref" || ok

# 6b. commands succeed (exit 0) even when their optional output lines don't apply
cd "$T/main"; mkdir -p "$D"; printf '# Handoff: rc (branch: main)\nUpdated: 2099-01-01T00:00Z | commit: none | tree: none\nStatus: in-progress | t\n' > "$D/rc.md"
bash "$H" headers >/dev/null && ok || bad "headers exit code non-zero"
bash "$H" snapshot rc-x >/dev/null && ok || bad "snapshot exit code non-zero (clean tree, no untracked)"
bash "$H" locate >/dev/null && ok || bad "locate exit code non-zero"
git update-ref -d refs/handoffs/rc-x 2>/dev/null; rm "$D/rc.md"

# 7. worktree-local folder is also listed (consistency with SessionStart hook)
mkdir -p "$T/wt/handoffs"; printf '# Handoff: loc (branch: feat/alerts)\nUpdated: 2099-03-01T00:00Z | commit: none | tree: none\nStatus: blocked | t\n' > "$T/wt/handoffs/loc.md"
has "headers include worktree-local" "$(cd "$T/wt" && bash "$H" headers)" "$T/wt/handoffs/loc.md"

# 8. bare-repo layout
cd "$T" && git clone -q --bare main proj/.bare && git --git-dir=proj/.bare worktree add -q proj/feat-x -b feat/x 2>/dev/null
has "bare layout dir" "$(cd proj/feat-x && bash "$H" locate)" "dir=$T/proj/handoffs"

# 9. non-git: read-only, and snapshot works
mkdir "$T/plain" && cd "$T/plain"
has "nogit mode" "$(bash "$H" locate)" "mode=nogit"; [ ! -e handoffs ] && ok || bad "nogit locate created dir"
has "nogit snapshot" "$(bash "$H" snapshot p)" "commit: none | tree: none"

echo "passed: $pass  failed: $fail"; [ "$fail" = 0 ]
