#!/usr/bin/env bash
# ship_commit.sh - commit wrapper with enforced gates.
# Usage: ship_commit.sh "message" [file ...]
# Stages given files (or keeps existing index), then enforces, in order:
#   0. gate-script integrity: when a canon_manifest.json sha256 map is
#      deployed, the gate scripts must hash-match it before they run
#   1. precommit re-grounding (mechanical, unconditional): the caller is
#      shown the real staged footprint before any commit happens
#   2. requested-scope gate: explicit file args bound the commit -
#      pre-staged files outside the requested set are rejected
#   3. scope gate: if canon/scope_whitelist.txt exists (worktree,
#      index, or HEAD), every staged file must be inside it (exact
#      path or dir/ prefix entries); the rules evaluated are the ones
#      that will actually be committed (index, else HEAD)
#   4. migration gate: staged migration files are re-verified live via
#      migration_gate.sh --check (paired/embedded/rollforward coverage;
#      the migration_ok stamp is not trusted - it is forgeable)
#   5. hygiene gate: message and staged diff are checked by
#      hygiene_check.sh in SEPARATE passes (message in stdin mode
#      with no path exemptions, diff in --diff mode)
#   6. commit TOCTOU: git runs with --no-verify (hooks are untrusted
#      repo code that could re-stage after the gates pass), then the
#      resulting commit's file list AND message are compared against
#      the gated index/message - any divergence fails hard.
# Exit codes: 1 usage/env, 2 scope or hygiene reject, 3 migration gate.
set -euo pipefail
SHA256_BIN=$(command -v sha256sum || true)
[ -z "$SHA256_BIN" ] && SHA256_BIN="shasum -a 256"
# canon may live outside the git toplevel (nested workspace layout) -
# resolve it from this script's own location BEFORE cd changes CWD.
# pwd -P: physical paths - a symlinked canon ancestor must not break
# the toplevel comparisons below (fail-closed on resolution failure).
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)" || { echo "cannot resolve canon dir" >&2; exit 1; }
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }

MSG="${1:?usage: ship_commit.sh \"message\" [file ...]}"
shift || true

# Temp files for the staged/requested sets (see Gate 1 + TOCTOU).
STAGED_Z=$(mktemp); REQ_Z=$(mktemp)
trap 'rm -f "$STAGED_Z" "$REQ_Z"' EXIT

# Stage explicit file list if given. Pathspecs are caller-relative,
# but the caller may sit OUTSIDE the target repo (nested workspace
# layout <ws>/code - `git add` run there finds no repo at all).
# Absolutize every pathspec against the caller's physical cwd, then
# add from $TOP: absolute pathspecs (incl. globs) resolve uniformly
# no matter where the caller stood.
ARGS_ABS=()
if [ $# -gt 0 ]; then
  CALLER_PWD=$(pwd -P)
  for a in "$@"; do
    case "$a" in
      /*|:*) ARGS_ABS+=("$a");;
      *)     ARGS_ABS+=("$CALLER_PWD/$a");;
    esac
  done
fi
cd -P "$TOP"
if [ ${#ARGS_ABS[@]} -gt 0 ]; then
  git add -- "${ARGS_ABS[@]}" || { echo "git add failed" >&2; exit 1; }
  # The requested set = staged changes matching the pathspecs, taken
  # from the index diff - NOT git ls-files: a staged DELETION has no
  # index entry, so ls-files would drop the path the caller just
  # asked to delete and Gate 1 would flag it as unrequested.
  # diff.relative=false pins repo-relative output independent of
  # caller config.
  git -c diff.relative=false diff --cached --name-only -z --no-renames -- "${ARGS_ABS[@]}" > "$REQ_Z" \
    || { echo "cannot enumerate requested paths" >&2; exit 1; }
fi

# Shared pattern - single source, do not fork it here.
. "$CANON_DIR/bin/migration_pattern.sh"

# --- Gate 0: gate-script integrity -----------------------------------
# The gate scripts run from the deployed canon control plane, which
# lives inside the agent's writable workspace. When the onboard stamp
# canon_manifest.json carries sha256 digests, the gate scripts must
# match them - a rewritten gate is a rewritten rule. The shared
# implementation lives in assert_canon_integrity.sh (review_15 #5);
# the merge/release/verify paths run the same check.
if [ -f "$CANON_DIR/canon_manifest.json" ]; then
  [ -x "$CANON_DIR/bin/assert_canon_integrity.sh" ] \
    || { echo "GATE_INTEGRITY: assert_canon_integrity.sh missing under a pinned manifest" >&2; exit 1; }
  "$CANON_DIR/bin/assert_canon_integrity.sh" || exit 1
fi

# --- Gate 0b: precommit re-grounding (mechanical, unconditional) -----
# The caller is always confronted with the real staged footprint.
echo "=== RE-GROUNDING: staged footprint ===" >&2
git status --porcelain >&2
git diff --cached --stat >&2
echo "=== END RE-GROUNDING ===" >&2

# Snapshot the staged set for the requested-scope check and the
# post-commit TOCTOU comparison. A file (not process substitution)
# so a failing git cannot silently yield an empty list.
git diff --cached --name-only -z --no-renames > "$STAGED_Z" \
  || { echo "cannot enumerate staged files" >&2; exit 1; }

# Staged entries must be REGULAR files: a staged symlink (120000)
# makes `git show :path` emit the TARGET string - content gates then
# scan the link text, not the payload; a gitlink (160000) hides a
# whole submodule commit. Both are uncommittable payloads here.
non_regular=""
while IFS= read -r -d '' f; do
  [ -z "$f" ] && continue
  mode=$(GIT_LITERAL_PATHSPECS=1 git ls-files -s -- "$f" | awk '{print $1; exit}')
  case "$mode" in
    100644|100755|"") ;;   # regular file, or absent (staged deletion)
    *) non_regular="$non_regular $f(mode=$mode)" ;;
  esac
done < "$STAGED_Z"
if [ -n "$non_regular" ]; then
  echo "SCOPE_GATE: non-regular staged entries:$non_regular" >&2
  echo "(symlink/gitlink - only real files may be committed)" >&2
  exit 2
fi

# --- Gate 1: requested-scope binding ----------------------------------
# Explicit file args bound this commit: anything ELSE already staged
# must not ride along into a commit the caller never asked for.
if [ $# -gt 0 ]; then
  if ! STAGED_Z="$STAGED_Z" REQ_Z="$REQ_Z" python3 -I - <<'PY'
import os, sys
staged = set(open(os.environ["STAGED_Z"], "rb").read().split(b"\0")) - {b""}
req = set(open(os.environ["REQ_Z"], "rb").read().split(b"\0")) - {b""}
extra = sorted(staged - req)
if extra:
    sys.stderr.write("pre-staged files outside the requested file list:\n")
    for e in extra:
        sys.stderr.write("  " + e.decode("utf-8", "replace") + "\n")
    sys.exit(1)
PY
  then
    echo "SCOPE_GATE: index contains files beyond the requested commit scope" >&2
    echo "(unstage them or include them explicitly)" >&2
    exit 2
  fi
fi

# --- Gate 2: whitelist scope ---
# The gate stays active while the whitelist exists in the worktree,
# the index, or HEAD: an unstaged `rm` or a staged `git rm` must not
# silently disable it (the deletion is only effective once committed,
# and the self-edit rule below makes that a standalone commit).
# Per-worktree scope beats the shared canon file: parallel
# item_worktrees must not serialize on one global whitelist. The
# director drops .canon_scope_whitelist.txt at the worktree root
# (info/excluded by item_worktree open); absent that, the shared
# $CANON_DIR whitelist applies.
WL="$TOP/.canon_scope_whitelist.txt"
# Linked-worktree detection must NOT rely on the canon symlink: an
# agent can delete $TOP/canon and then the shared-whitelist fallback
# silently applies. git-dir vs git-common-dir is the real signal -
# a linked worktree's git dir lives under <main>/.git/worktrees/*.
IS_LINKED_WT=0
GD=$(git -C "$TOP" rev-parse --absolute-git-dir 2>/dev/null)
GCD=$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[ -n "$GD" ] && [ -n "$GCD" ] && [ "$GD" != "$GCD" ] && IS_LINKED_WT=1
if [ ! -f "$WL" ] && [ "$IS_LINKED_WT" = "1" ]; then
  # Linked worktree under the shared control plane. The shared
  # $CANON_DIR whitelist is NOT a valid fallback: parallel executors
  # would race on one global file. The director must drop
  # .canon_scope_whitelist.txt at this worktree's root.
  echo "SCOPE: item worktree without .canon_scope_whitelist.txt - refusing shared-canon fallback (parallel executors race on it)" >&2
  exit 1
fi
[ -f "$WL" ] || WL="$CANON_DIR/scope_whitelist.txt"
# Canonicalize only the parent directory, never the leaf: resolving
# the leaf would let an unstaged symlink at the whitelist path push
# REL_WL outside the toplevel and substitute attacker-controlled
# "rules" via the worktree fallback. python3 relpath is the portable
# path - realpath -m does not exist on macOS, and falling back to the
# uncanonicalized string would silently skip the index/HEAD checks.
WL_DIR=$(dirname "$WL"); WL_BASE=$(basename "$WL")
REL_DIR=$(WL_DIR="$WL_DIR" TOP="$TOP" python3 -I -c 'import os,sys; sys.stdout.write(os.path.relpath(os.path.realpath(os.environ["WL_DIR"]), os.path.realpath(os.environ["TOP"])))' 2>/dev/null) \
  || REL_DIR=""
case "$REL_DIR" in
  ../*|"") REL_WL="" ;;
  .)       REL_WL="$WL_BASE" ;;
  *)       REL_WL="$REL_DIR/$WL_BASE" ;;
esac
wl_in_index=0; wl_in_head=0
if [ -n "$REL_WL" ]; then
  git cat-file -e ":$REL_WL" 2>/dev/null && wl_in_index=1
  git cat-file -e "HEAD:$REL_WL" 2>/dev/null && wl_in_head=1
fi
# Branch binding: a live on-disk whitelist may carry a `# branch:
# <name>` header pinning it to the branch it was written for. A
# whitelist left over from a previous item must not silently widen
# (or silently restrict) the scope of the next task on a different
# branch. Index/HEAD versions are exempt - their owning commit is
# already history.
if [ -f "$WL" ]; then
  WL_BRANCH=$(grep -m1 -E '^# *branch:' "$WL" | sed -E 's/^# *branch: *//; s/[[:space:]]+$//' || true)
  CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -n "$WL_BRANCH" ] && [ -n "$CUR_BRANCH" ] && [ "$WL_BRANCH" != "$CUR_BRANCH" ]; then
    echo "SCOPE_GATE: whitelist belongs to branch '$WL_BRANCH', current branch is '$CUR_BRANCH'" >&2
    echo "(regenerate or remove $WL - a stale whitelist must not gate a different item)" >&2
    exit 2
  fi
fi
# Fail-closed on task branches: an item branch exists only to ship
# scoped work, so 'no whitelist anywhere' is not "gate off" there -
# it is evidence the whitelist was deleted (a live whitelist in the
# worktree/index/HEAD, or the shared canon one, is mandatory). On
# non-task branches the gate stays optional as before.
CUR_BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
# Detached HEAD has no branch identity at all: the task-branch
# whitelist check below cannot bind a scope (the regex never
# matches 'HEAD'), so a commit here would run gate-free. The git
# agent works on named branches only - refuse outright.
if [ "$CUR_BR" = "HEAD" ]; then
  echo "SCOPE_GATE: refusing to commit on detached HEAD" >&2
  echo "(no branch name to bind a scope whitelist to - check out the item branch first)" >&2
  exit 2
fi
if [[ "$CUR_BR" =~ ^(epic_)?issue_[0-9]+- ]] \
    && [ ! -f "$WL" ] && [ "$wl_in_index" -eq 0 ] && [ "$wl_in_head" -eq 0 ]; then
  echo "SCOPE_GATE: task branch '$CUR_BR' has no active scope whitelist" >&2
  echo "($WL and $CANON_DIR/scope_whitelist.txt both absent - a deleted whitelist does not disarm the gate)" >&2
  exit 2
fi
if [ -f "$WL" ] || [ "$wl_in_index" -eq 1 ] || [ "$wl_in_head" -eq 1 ]; then
  # When the staged set touches the whitelist path itself (edit,
  # rename, delete - --name-only shows the old path too), every OTHER
  # staged file is evaluated against the PRE-CHANGE rules in HEAD:
  # a payload cannot ride in under a scope widening it ships in the
  # same commit. Pure whitelist moves (rename-away/back, standalone
  # edit or removal) pass on their own - each is its own reviewable
  # commit. Only applies when canon/ lives inside the repo (a
  # whitelist outside the toplevel cannot appear in the diff).
  wl_changed=0
  if [ -n "$REL_WL" ]; then
    STAGED_Z="$STAGED_Z" REL_WL="$REL_WL" python3 -I -c 'import os,sys; sys.exit(0 if os.environ["REL_WL"].encode() in open(os.environ["STAGED_Z"],"rb").read().split(b"\0") else 1)' \
      && wl_changed=1
  fi
  # Evaluate the whitelist content that will actually be committed:
  # the index version, then HEAD (a staged deletion still owes the
  # pre-deletion rules to the payload it rides with). When the
  # whitelist itself is being changed in this commit the PAYLOAD
  # files are judged by the pre-change HEAD rules instead. Reading
  # the worktree file would let an unstaged edit, deletion, or
  # symlink change scope invisibly.
  wl_rules=""; payload_rules=""
  if [ "$wl_in_index" -eq 1 ]; then
    wl_rules=$(git show ":$REL_WL" 2>/dev/null || true)
  elif [ "$wl_in_head" -eq 1 ]; then
    wl_rules=$(git show "HEAD:$REL_WL" 2>/dev/null || true)
  elif [ -f "$WL" ]; then
    wl_rules=$(cat "$WL")
  fi
  payload_rules="$wl_rules"
  if [ "$wl_changed" -eq 1 ] && [ "$wl_in_head" -eq 1 ]; then
    payload_rules=$(git show "HEAD:$REL_WL" 2>/dev/null || true)
  fi
  # Whitelist self-poison check: the rules judging this commit must
  # be a NON-EMPTY, non-wildcard-everything list. Committing an empty
  # whitelist (or "*" / "/") would silently disarm the gate for every
  # later commit.
  RULE_CHECK=$(WL_RULES="$wl_rules" python3 -I - <<'PY' 2>/dev/null
import os, sys
ok = 0
for ln in os.environ["WL_RULES"].splitlines():
    s = ln.strip().rstrip("\r").rstrip("/")
    if not s or s.startswith("#"):
        continue
    if s in ("*", "/", ".", "./"):
        sys.stdout.write("wildcard")
        raise SystemExit(0)
    ok = 1
sys.stdout.write("ok" if ok else "empty")
PY
)
  if [ "$RULE_CHECK" != "ok" ]; then
    echo "SCOPE_GATE: committed whitelist rules are ${RULE_CHECK:-unreadable} - the gate would disarm" >&2
    exit 2
  fi
  bad=""
  # --no-renames expands a rename into delete+add so BOTH the source
  # and destination paths are scope-checked (renaming an out-of-scope
  # file into an allowed path cannot smuggle it); the staged list was
  # already snapshotted NUL-separated above.
  while IFS= read -r -d '' f; do
    [ -z "$f" ] && continue
    # The whitelist file itself is always in-scope: the self-edit
    # check above already forces it to be the only staged file.
    [ -n "$REL_WL" ] && [ "$f" = "$REL_WL" ] && continue
    # docs/impl_specs/* is NOT a blanket exemption: the designer's
    # impl spec is a contract-bound artifact committed by the calling
    # instance before the writer's whitelist is installed - letting an
    # executor edit it freely would let it retro-fit the designer's
    # decisions to its own code. It is in scope only when the
    # whitelist names it explicitly (handled by the normal rules).
    ok=0
    while IFS= read -r line; do
      line="${line%$'\r'}"
      case "$line" in ''|'#'*) continue ;; esac
      line="${line%/}"
      if [ "$f" = "$line" ]; then ok=1; break; fi
      case "$f" in "$line"/*) ok=1; break ;; esac
    done <<< "$payload_rules"
    [ "$ok" -eq 0 ] && bad="$bad$f"$'\n'
  done < "$STAGED_Z"
  if [ -n "$bad" ]; then
    echo "SCOPE_GATE: staged files outside $WL:" >&2
    printf '%s' "$bad" >&2
    exit 2
  fi
fi

# --- Gate 3: migration gate ---
# Deletions are in scope (D): dropping an applied migration needs
# coverage just like adding one.
migs=$(git diff --cached --name-only -z --no-renames --diff-filter=AMTCD | grep -zE "$MIG_PAT" | tr '\0' '\n' || true)
if [ -n "$migs" ]; then
  # The coverage check runs synchronously on every commit instead of
  # trusting canon/migration_ok: the stamp is a self-attested value
  # the same actor can forge from public index data. Live --check
  # verifies the staged blobs themselves each time.
  if ! "$CANON_DIR/bin/migration_gate.sh" --check; then
    echo "MIGRATION_GATE: staged migration files failed coverage" >&2
    echo "verification. Each needs a paired rollback file, an embedded" >&2
    echo "rollback section, or canon/migration_rollforward.md." >&2
    echo "$migs" >&2
    exit 3
  fi
fi

# --- Gate 4: hygiene. Message and diff are checked SEPARATELY: a
# multi-line MSG could forge a fake "diff --git"/"+++" header (or any
# framing line) and smuggle unscanned content under an exempt path
# into `git commit -m`. Stdin mode scans the whole message with no
# path context (no exemptions); the raw diff gets path tracking for
# per-file language exemptions. --text unfolds staged binary payloads
# into scannable text; diff.external= kills driver overrides.
printf '%s\n' "$MSG" | "$CANON_DIR/bin/hygiene_check.sh" || {
  echo "HYGIENE_GATE: commit message rejected" >&2; exit 2; }
# numstat marks staged binary rows with '-' - those paths are exempt
# from the language class inside the scan (secrets still scan).
export HYGIENE_BINARY_PATHS
HYGIENE_BINARY_PATHS=$(git -c diff.external= diff --cached --numstat --no-ext-diff \
  | awk -F'\t' '$1=="-"{print $3}')
git -c diff.external= diff --cached --text --no-ext-diff | "$CANON_DIR/bin/hygiene_check.sh" --diff || {
  echo "HYGIENE_GATE: staged content rejected" >&2; exit 2; }

# --- Commit: hooks are untrusted repo code. --no-verify keeps a
# commit-msg/pre-commit hook from mutating the index or message after
# the gates passed; the post-checks below detect any residual drift.
STAGED_LIST=$(tr '\0' '\n' < "$STAGED_Z" | LC_ALL=C sort | $SHA256_BIN | cut -d' ' -f1)
PRE_COMMIT_HEAD=$(git rev-parse --verify -q HEAD || echo "")
git commit --no-verify -m "$MSG" || { echo "git commit failed" >&2; exit 1; }

# TOCTOU verification: the committed file set and message must equal
# exactly what the gates evaluated. A hook that re-staged files or
# rewrote the message is caught here, never silently shipped. On
# mismatch the compromised commit is rolled back FIRST - exit 1 with
# it still on HEAD would let a later ship_push publish it anyway.
_toctou_rollback() {
  if [ -n "$PRE_COMMIT_HEAD" ]; then
    # --soft keeps the (mutated) index contents for forensics while
    # moving HEAD back; the caller re-stages cleanly on retry.
    git reset --soft "$PRE_COMMIT_HEAD" >/dev/null 2>&1 || \
      git update-ref -d HEAD >/dev/null 2>&1 || true
  else
    git update-ref -d HEAD >/dev/null 2>&1 || true
  fi
}
COMMIT_LIST=$(git diff-tree --no-commit-id --name-only -z -r --no-renames HEAD | tr '\0' '\n' | LC_ALL=C sort | $SHA256_BIN | cut -d' ' -f1)
if [ "$COMMIT_LIST" != "$STAGED_LIST" ]; then
  echo "TOCTOU: committed file set differs from the gated index" >&2
  git diff-tree --no-commit-id --name-status -r --no-renames HEAD >&2
  echo "(a commit hook mutated the index - inspect .git/hooks; rolling back)" >&2
  _toctou_rollback
  exit 1
fi
# git log %B keeps the message's own trailing newline while -m does
# not add one - and `git commit` normalizes the message internally
# (collapses blank-line runs, trims leading/trailing blank lines)
# via stripspace. Compare stripspace-normalized forms or any
# multi-paragraph message reads as drift.
COMMITTED_MSG=$(git log -1 --format=%B | git stripspace)
NORM_MSG=$(printf '%s\n' "$MSG" | git stripspace)
if [ "$COMMITTED_MSG" != "$NORM_MSG" ]; then
  echo "TOCTOU: committed message differs from the gated message" >&2
  _toctou_rollback
  exit 1
fi
