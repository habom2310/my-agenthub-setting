#!/usr/bin/env bash
# Handoff helper. Portable: bash 3.2+ (macOS default), GNU or BSD userland, git 2.22+.
#
# Read-only (never create files or change git config):
#   handoff.sh locate              -> dir, branch, mode
#   handoff.sh headers [--all]     -> newest-first headers (max 10) with flags
#   handoff.sh drift   <file>      -> what changed since the handoff, plus a verdict
# Writes:
#   handoff.sh snapshot <slug>     -> record HEAD + uncommitted state; prints header line 2
#   handoff.sh backup   <file>     -> keep the previous version in archive/.prev/
#   handoff.sh archive  <file>     -> move to archive/<UTC-date>-<slug>.md, drop its snapshot ref
set -u

die() { echo "error: $*" >&2; exit 1; }
in_git() { git rev-parse --git-dir >/dev/null 2>&1; }
now_utc() { date -u +%Y-%m-%dT%H:%MZ; }
MAX_HEADERS=10
MAX_LINES=80
STALE_DAYS=14

# ---------- location (no side effects) ----------
locate() { # sets DIR, BRANCH, MODE, COMMON, LOCAL_DIR
  LOCAL_DIR=""
  if ! in_git; then
    DIR="$PWD/handoffs"; BRANCH="none"; MODE="nogit"; COMMON=""; return
  fi
  BRANCH="$(git branch --show-current 2>/dev/null)"; [ -z "$BRANCH" ] && BRANCH="detached"
  COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  local shared top
  shared="$(dirname "$COMMON")/handoffs"
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && LOCAL_DIR="$top/handoffs"
  [ "$LOCAL_DIR" = "$shared" ] && LOCAL_DIR=""
  if [ -d "$shared" ] && [ -w "$shared" ] || { [ ! -e "$shared" ] && [ -w "$(dirname "$shared")" ]; }; then
    DIR="$shared"; MODE="shared"
  else
    DIR="${LOCAL_DIR:-$PWD/handoffs}"; MODE="local"
  fi
}

ensure_dir() { # only called by write commands
  mkdir -p "$DIR/archive/.prev" || die "cannot create $DIR"
  if [ -n "$COMMON" ] && [ "$(git --git-dir="$COMMON" rev-parse --is-bare-repository)" = "false" ]; then
    mkdir -p "$COMMON/info" 2>/dev/null
    grep -qxF "/handoffs/" "$COMMON/info/exclude" 2>/dev/null \
      || echo "/handoffs/" >> "$COMMON/info/exclude" 2>/dev/null
  fi
}

# ---------- header ----------
#   # Handoff: <slug> (branch: <branch>)
#   Updated: <YYYY-MM-DDTHH:MMZ> | commit: <sha|none> | tree: <sha|clean|none>
#   Status: <in-progress|blocked|complete> | <summary>
RE1='^# Handoff: [a-z0-9][a-z0-9-]* \(branch: [^)]+\)$'
RE2='^Updated: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z \| commit: ([0-9a-f]{7,40}|none) \| tree: ([0-9a-f]{7,40}|clean|none)$'
RE3='^Status: (in-progress|blocked|complete) \| .+$'

check_header() { # file -> prints problems, returns 1 if any
  local f="$1" bad=0 n
  sed -n 1p "$f" | grep -Eq "$RE1" || { echo "  ! line 1 malformed"; bad=1; }
  sed -n 2p "$f" | grep -Eq "$RE2" || { echo "  ! line 2 malformed"; bad=1; }
  sed -n 3p "$f" | grep -Eq "$RE3" || { echo "  ! line 3 malformed"; bad=1; }
  n="$(wc -l < "$f" | tr -d ' ')"
  [ "$n" -gt "$MAX_LINES" ] && echo "  ! $n lines (limit $MAX_LINES): trim resolved detail"
  return $bad
}
hdr_branch() { sed -n 1p "$1" | sed -nE 's/.*\(branch: ([^)]+)\)$/\1/p'; }
hdr_ts()     { sed -n 2p "$1" | sed -nE 's/^Updated: ([^ ]+) .*/\1/p'; }
hdr_commit() { sed -n 2p "$1" | sed -nE 's/.*commit: ([0-9a-f]+|none).*/\1/p'; }
hdr_tree()   { sed -n 2p "$1" | sed -nE 's/.*tree: ([0-9a-f]+|clean|none)$/\1/p'; }
slug_of()    { basename "$1" .md; }

epoch() { # UTC stamp -> epoch seconds, empty on failure
  date -u -d "${1%Z}" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%MZ" "$1" +%s 2>/dev/null
}
age_days() { local e; e="$(epoch "$1")"; [ -n "$e" ] && echo $(( ($(date -u +%s) - e) / 86400 )); }

worktree_for() { # branch -> path of the worktree that has it checked out
  git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$1" '
    /^worktree /{p=substr($0,10)} $0=="branch " b {print p; exit}'
}

flags_for() { # file -> space-separated flags
  local f="$1" b ts d track out=""
  b="$(hdr_branch "$f")"; ts="$(hdr_ts "$f")"
  if in_git && [ -n "$b" ] && [ "$b" != "detached" ] && [ "$b" != "none" ]; then
    if ! git show-ref --verify --quiet "refs/heads/$b"; then
      out="$out[branch gone] "
    else
      # Upstream deleted (e.g. GitLab "delete source branch" on merge, seen after fetch --prune).
      track="$(git for-each-ref --format='%(upstream:track)' "refs/heads/$b" 2>/dev/null)"
      [ "$track" = "[gone]" ] && out="$out[remote gone] "
    fi
  fi
  d="$(age_days "$ts")"; [ -n "$d" ] && [ "$d" -ge "$STALE_DAYS" ] && out="$out[stale ${d}d] "
  echo "$out"
}

# ---------- working-state snapshot ----------
current_state() { # sha of the current tracked state: stash-like commit if dirty, else HEAD
  local s; s="$(git stash create 2>/dev/null)"
  [ -n "$s" ] && echo "$s" || git rev-parse HEAD 2>/dev/null
}

cmd="${1:-}"; shift || true
case "$cmd" in
  locate)
    locate
    echo "dir=$DIR"; echo "branch=$BRANCH"; echo "mode=$MODE"
    ;;

  snapshot)
    slug="${1:-}"; echo "$slug" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || die "usage: snapshot <kebab-slug>"
    locate; ensure_dir
    if ! in_git; then
      echo "branch=none"; echo "line2=Updated: $(now_utc) | commit: none | tree: none"; exit 0
    fi
    head="$(git rev-parse --short=12 HEAD 2>/dev/null || echo none)"
    stash="$(git stash create 2>/dev/null)"
    if [ -n "$stash" ]; then
      git update-ref "refs/handoffs/$slug" "$stash" || die "could not save snapshot ref"
      tree="$(git rev-parse --short=12 "$stash")"
    else
      tree="clean"; git update-ref -d "refs/handoffs/$slug" 2>/dev/null
    fi
    echo "branch=$BRANCH"
    echo "line2=Updated: $(now_utc) | commit: $head | tree: $tree"
    un="$(git ls-files --others --exclude-standard | head -n 20)"
    [ -n "$un" ] && { echo "untracked (not in snapshot; list the ones that matter in the handoff):"; echo "$un" | sed 's/^/  /'; }
    ;;

  headers)
    locate
    all=0; [ "${1:-}" = "--all" ] && all=1
    list=""
    for d in "$DIR" ${LOCAL_DIR:+"$LOCAL_DIR"}; do
      [ -d "$d" ] || continue
      for f in "$d"/*.md; do
        [ -e "$f" ] || continue
        ts="$(hdr_ts "$f")"; list="$list${ts:-0000}	$f
"
      done
    done
    [ -n "$list" ] || { echo "(no active handoffs)"; exit 0; }
    sorted="$(printf '%s' "$list" | sort -r | cut -f2-)"
    total="$(printf '%s\n' "$sorted" | grep -c .)"
    i=0
    printf '%s\n' "$sorted" | while IFS= read -r f; do
      i=$((i + 1)); [ $all = 0 ] && [ $i -gt $MAX_HEADERS ] && break
      fl="$(flags_for "$f")"; mark=""
      [ "$(hdr_branch "$f")" = "$BRANCH" ] && mark=" <- current branch"
      echo "== $f $fl$mark"
      sed -n 1,3p "$f"
      check_header "$f"
    done
    [ $all = 0 ] && [ "$total" -gt $MAX_HEADERS ] && echo "(+$((total - MAX_HEADERS)) older; run 'headers --all' to see them)"
    ;;

  backup)
    f="${1:-}"; [ -f "$f" ] || die "no such file: $f"
    prev="$(dirname "$f")/archive/.prev"; mkdir -p "$prev"
    cp "$f" "$prev/$(basename "$f")" && echo "backed up to $prev/$(basename "$f")"
    ;;

  drift)
    f="${1:-}"; [ -f "$f" ] || die "no such file: $f"
    check_header "$f" || echo "warning: header malformed; drift check may be incomplete"
    hb="$(hdr_branch "$f")"; ts="$(hdr_ts "$f")"; sha="$(hdr_commit "$f")"; tree="$(hdr_tree "$f")"
    echo "handoff: branch=$hb commit=$sha tree=$tree written=$ts ($(age_days "$ts")d ago)"
    in_git || { echo "verdict: NO-GIT (verify claims manually)"; exit 0; }
    cur="$(git branch --show-current)"; [ -z "$cur" ] && cur="detached"
    verdict="CLEAN"
    if [ "$cur" != "$hb" ]; then
      echo "! current branch is '$cur', handoff is for '$hb'"; verdict="MISMATCH"
      wt="$(worktree_for "$hb")"
      if [ -n "$wt" ]; then echo "  '$hb' is checked out at: $wt  (resume there)"
      elif git show-ref --verify --quiet "refs/heads/$hb"; then echo "  '$hb' exists but isn't checked out anywhere: git switch $hb, or git worktree add <path> $hb"
      else echo "  branch '$hb' no longer exists (merged and deleted?): consider archiving this handoff"; fi
      echo "verdict: $verdict"; exit 0
    fi
    if [ -z "$sha" ] || [ "$sha" = "none" ]; then
      echo "! no commit recorded; cannot diff"; echo "verdict: UNKNOWN"; exit 0
    fi
    if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
      echo "! recorded commit $sha no longer exists (rebased, reset or gc'd)"; echo "verdict: DIVERGED"; exit 0
    fi
    if ! git merge-base --is-ancestor "$sha" HEAD; then
      echo "! HEAD no longer contains $sha (rebase or reset)"; echo "verdict: DIVERGED"; exit 0
    fi
    # The state the handoff described: its uncommitted snapshot, or the commit if it was clean.
    then_state="$sha"
    if [ -n "$tree" ] && [ "$tree" != clean ] && [ "$tree" != none ]; then
      if git cat-file -e "$tree^{commit}" 2>/dev/null; then then_state="$tree"
      else echo "! uncommitted-work snapshot $tree is missing; comparing against the commit only"; fi
    fi
    now_state="$(current_state)"
    n="$(git rev-list --count "$sha"..HEAD)"
    if [ "$n" -gt 0 ]; then echo "commits since handoff: $n"; git log --oneline -n 20 "$sha"..HEAD; fi
    changed="$(git diff --name-only "$then_state" "$now_state" -- 2>/dev/null)"
    if [ -n "$changed" ]; then
      echo "tracked files that differ from the handoff's state (max 30):"
      echo "$changed" | head -n 30 | sed 's/^/  /'
      verdict="MOVED"
    elif [ "$n" -gt 0 ]; then
      echo "files are identical to the handoff's state (its uncommitted work was committed as-is)"
    else
      [ "$then_state" != "$sha" ] && echo "the handoff's uncommitted work is still present, unchanged"
    fi
    un="$(git ls-files --others --exclude-standard | head -n 20)"
    [ -n "$un" ] && { echo "untracked files now (not covered by the snapshot):"; echo "$un" | sed 's/^/  /'; }
    echo "verdict: $verdict"
    ;;

  archive)
    f="${1:-}"; [ -f "$f" ] || die "no such file: $f"
    locate
    d="$(dirname "$f")/archive"; mkdir -p "$d"
    dest="$d/$(date -u +%Y-%m-%d)-$(basename "$f")"
    [ -e "$dest" ] && die "already exists: $dest"
    mv "$f" "$dest" || die "move failed"
    rm -f "$d/.prev/$(basename "$f")"
    in_git && git update-ref -d "refs/handoffs/$(slug_of "$f")" 2>/dev/null
    echo "archived to $dest"
    ;;

  *)
    sed -n '2,13p' "$0"; exit 2 ;;
esac
exit 0
