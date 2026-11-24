#!/usr/bin/env bash
# migration_gate.sh - isolated verification for staged schema/data
# migrations. ship_commit.sh invokes it with --check on every commit
# that touches migration-pattern files; verification always runs live
# on the staged index - the canon/migration_ok stamp this script also
# writes is an informational audit record, not the enforcement path
# (a self-attested stamp could be forged from public index data).
#
# The gate NEVER applies a migration and never touches any live or
# production database. It only verifies that for every staged
# migration file one of these holds:
#   a) a paired rollback path is staged: same directory, same stem
#      modulo one trailing rollback-marker segment, a non-empty
#      staged blob and a regular-file mode, or
#   b) the file itself contains a rollback/downgrade MARKER: a
#      rollback keyword acting as a directive (line-anchored, followed
#      by ':'/'('/'='), or a down-word inside a --/#/// comment line
#      (goose "-- +goose Down"). A keyword mid-expression
#      ("tx.rollback()") or a column named 'countdown' does NOT
#      qualify, or
#   c) an approved roll-forward note exists at
#      canon/migration_rollforward.md, is already tracked in HEAD
#      (i.e. passed review in an earlier commit - an ad-hoc note
#      written alongside the migration proves nothing), and lists
#      this migration's exact repo-relative path on its own line.
#      A blanket note, a substring (.bak name), or a bare basename
#      covers nothing. When canon/ lives outside the repo toplevel
#      the note cannot be tracked and coverage (c) is unavailable
#      by design.
# A staged DELETION of a migration file is covered only by (c): a
# deleted file can carry no embedded section and no staged pair.
#
# Note on strength: this gate verifies that a rollback path EXISTS for
# every staged migration; it does not verify the rollback is correct.
# It is a tripwire for a hasty-but-honest caller, not a cryptographic
# control - the caller can already run arbitrary commands.
#
# Optional: if canon/project.json declares a native dry-run
# entrypoint under "migration_dry_run_cmd", it is executed in a
# subshell with a timeout - it must be the project's own
# manifest-declared command, never an ad-hoc production command.
# The command is read ONLY from project.json, never from the
# environment (env vars are caller-controllable). A present but
# malformed project.json fails closed. Before the dry-run executes,
# the worktree must match the index on every migration-pattern path -
# the command sees the working tree, so a benign unstaged shadow of a
# malicious staged blob would falsify the dry-run.
#
# Usage: migration_gate.sh [--check]   # --check: verify only, no stamp
# Exit: 0 verified (stamp written unless --check), 1 violations found.
set -uo pipefail
# Physical paths only: a logical `pwd` through a symlinked parent and
# `git rev-parse --show-toplevel` disagree, which would silently
# disable the roll-forward note lookup (CANON_DIR_REL="").
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP"
# Path of canon relative to the repo root, for HEAD lookups of
# tracked files like migration_rollforward.md. Empty when canon sits
# outside the repo (nested workspace layout) or IS the toplevel
# (degenerate) - the project-side note locations (docs/, repo root)
# are tried regardless, so coverage (c) stays available.
CANON_DIR_REL=""
case "$CANON_DIR" in
  "$TOP/"*) CANON_DIR_REL="${CANON_DIR#"$TOP"/}" ;;
esac

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# Shared pattern - single source, do not fork it here.
. "$CANON_DIR/bin/migration_pattern.sh"

# A basename that denotes a rollback artifact rather than a migration
# that needs coverage. The marker must be the FINAL filename segment
# behind a ./_/- separator (001_down.sql, 003.down.sql,
# add_users_undo.sql) or the Flyway U-prefix (U2__name.sql): an
# interior word (007_file_downloads.sql, scale_down_more.sql) is a
# forward migration, and only a trailing marker can be stripped by
# pair_key() below.
is_rollback_name() {
  local b; b=$(basename "$1"); b=${b%.*}
  printf '%s' "$b" | grep -qiE '(^|[._-])(down|undo|rollback|revert|downgrade)$' && return 0
  printf '%s' "$b" | grep -qiE '^u[0-9]+(_[0-9]+)*__' && return 0
  return 1
}

# Pairing key: basename minus extension, case-folded (tr, not sed
# /I - the /I flag is GNU-only and its failure on BSD sed would
# collapse every key to ""), minus ONE trailing direction-marker
# segment (./_/- separated: down/up/undo/rollback/revert/downgrade/
# migrate/forward). Flyway V/U/R prefixes keep their VERSION - only
# the letter is normalized - so V2__x.sql pairs with U2__x.sql but
# never with U1__x.sql. Two files pair only in the SAME directory
# with equal keys: 003_up <-> 003_down, 003.up <-> 003.down,
# 001_users <-> 001_users_down, up.sql <-> down.sql (empty key).
pair_key() {
  local b; b=$(basename "$1"); b=${b%.*}
  b=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
  b=$(printf '%s' "$b" | sed -E 's/(^|[._-])(down|up|undo|rollback|revert|downgrade|migrate|forward)$//')
  b=$(printf '%s' "$b" | sed -E 's/^[vur]([0-9]+(_[0-9]+)*)__/f\1__/')
  printf '%s' "$b"
}

NOTE="$CANON_DIR/migration_rollforward.md"

# The roll-forward note covers a repo-relative path only when the note
# is tracked in HEAD (reviewed in an earlier commit) and lists that
# exact path on its own line. Exact-line equality via python, not
# grep -qxF: a staged filename containing a newline would otherwise
# match a blank line in the note (grep treats \n in the pattern as an
# OR-ed alternation).
# Candidate locations, in order: inside the canon dir (tracked-canon
# layouts), docs/ and the repo root. The deployed layout gitignores
# canon/, so the reachable locations for a standard deploy are the
# two project-side paths - both require the note to be HEAD-tracked,
# preserving the "reviewed in an earlier commit" property.
note_covers() {
  local loc
  for loc in "$CANON_DIR_REL/migration_rollforward.md" \
             "docs/migration_rollforward.md" \
             "migration_rollforward.md"; do
    [ -n "$loc" ] || continue
    git cat-file -e "HEAD:$loc" 2>/dev/null || continue
    git show "HEAD:$loc" 2>/dev/null \
      | TARGET="$1" python3 -I -c 'import os,sys; t=os.environ["TARGET"]; sys.exit(0 if any(l.rstrip("\r") == t for l in sys.stdin.read().splitlines()) else 1)' \
      && return 0
  done
  return 1
}

# Staged files needing coverage. --no-renames: rename detection would
# let deleting a tracked migration plus staging a >=50%-similar file
# surface as R on the NEW path only - erasing the deletion from the
# D list. With --no-renames the old path shows as D and the new path
# as A. Filters cover T (type change) and C (copy): a migration
# replaced by a symlink must not slip past.
# NUL-delimited reads without mapfile (bash>=4 only; the canon targets
# bash 3.2 too). -d '' reads NUL-separated entries; the trailing
# || true keeps set -e alive on empty diffs.
all_mig=(); deleted=()
while IFS= read -r -d '' f; do all_mig+=("$f"); done \
  < <(git diff --cached --name-only -z --no-renames --diff-filter=AMTC | grep -zE "$MIG_PAT" || true)
while IFS= read -r -d '' f; do deleted+=("$f"); done \
  < <(git diff --cached --name-only -z --no-renames --diff-filter=D | grep -zE "$MIG_PAT" || true)
staged=(); pairs=()
for f in ${all_mig[@]+"${all_mig[@]}"}; do
  if is_rollback_name "$f"; then pairs+=("$f"); else staged+=("$f"); fi
done

# A staged migration/rollback blob must be a REGULAR file. A staged
# symlink (120000) makes `git show ":$f"` print the TARGET string -
# "revert:x" satisfies the marker regex and any path satisfies the
# non-empty check; a gitlink (160000) prints a commit SHA. Reject both.
mode_of() { GIT_LITERAL_PATHSPECS=1 git ls-files -s -- "$1" | awk '{print $1; exit}'; }
non_regular=""
for f in ${all_mig[@]+"${all_mig[@]}"}; do
  case "$(mode_of "$f")" in
    100644|100755) ;;
    *) non_regular="$non_regular $f" ;;
  esac
done
if [ -n "$non_regular" ]; then
  echo "MIGRATION GATE FAIL: non-regular staged entries:$non_regular" >&2
  echo "(symlink/gitlink - migration blobs must be real files)" >&2
  exit 1
fi

# Rollback artifacts staged alone: still verify their blobs are real
# and non-empty (an empty 'down' file is not a rollback), then fall
# through to the optional dry-run - a rollback file is migration-
# relevant and the declared dry-run must still run.
if [ ${#staged[@]} -eq 0 ] && [ ${#deleted[@]} -eq 0 ]; then
  if [ ${#pairs[@]} -eq 0 ]; then
    echo "no staged migration files - nothing to verify" >&2
    exit 1
  fi
  pfail=0
  for p in ${pairs[@]+"${pairs[@]}"}; do
    git show ":$p" 2>/dev/null | grep -q '[^[:space:]]' \
      || { echo "MIGRATION GATE FAIL: empty rollback file $p" >&2; pfail=1; }
  done
  [ $pfail -ne 0 ] && exit 1
  echo "only rollback files staged - nothing to cover" >&2
fi

# Rollback marker heuristic. Line-anchored directive form: the keyword
# starts the statement (optionally after 'def') and is followed by
# ':'/'('/'=' - 'def downgrade()' and 'down:' count, a mid-expression
# 'tx.rollback()' or 'session.rollback()' does not. Comment form: a
# down-word immediately inside a --/#/// comment, optionally behind a
# goose/migrate label ("-- +goose Down").
ROLLBACK_RE='^[[:space:]]*(def[[:space:]]+)?(rollback|downgrade|revert|undo|down)[A-Za-z0-9_]*[[:space:]]*[:(=]|(--|#|//)[[:space:]]*\+?[[:space:]]*((goose|migrate)[[:space:]]+)?(down|rollback|downgrade|revert|undo)\b'

fail=0
for f in ${staged[@]+"${staged[@]}"}; do
  covered=""
  fdir=$(dirname "$f"); fkey=$(pair_key "$f")
  # a) staged paired rollback file: same directory, equal pairing key,
  #    non-trivial staged blob (a 1-byte ';' or '--' is no rollback)
  for p in ${pairs[@]+"${pairs[@]}"}; do
    [ "$p" = "$f" ] && continue
    [ "$(dirname "$p")" = "$fdir" ] && [ "$(pair_key "$p")" = "$fkey" ] \
      && [ "$(git show ":$p" 2>/dev/null | tr -d '[:space:]' | wc -c)" -ge 8 ] \
      && { covered="paired rollback: $p"; break; }
  done
  # b) embedded rollback/downgrade marker in the STAGED blob
  #    (index content, not the working copy - they may differ)
  if [ -z "$covered" ] && git show ":$f" 2>/dev/null | grep -qiE "$ROLLBACK_RE"; then
    covered="embedded rollback section"
  fi
  # c) approved roll-forward note, HEAD-tracked, naming this exact
  #    repo-relative path on its own line
  if [ -z "$covered" ] && note_covers "$f"; then
    covered="approved roll-forward (canon/migration_rollforward.md)"
  fi
  if [ -z "$covered" ]; then
    echo "MIGRATION GATE FAIL: $f has no rollback path" >&2
    fail=1
  else
    echo "OK: $f -> $covered"
  fi
done

# Staged deletions: covered ONLY by the roll-forward note listing each
# deleted path on its own line - pairs and embedded sections cannot
# apply to a file that no longer exists.
for f in ${deleted[@]+"${deleted[@]}"}; do
  if note_covers "$f"; then
    echo "OK: $f -> approved roll-forward (canon/migration_rollforward.md)"
  else
    echo "MIGRATION GATE FAIL: deleted migration $f has no roll-forward coverage" >&2
    fail=1
  fi
done
[ $fail -ne 0 ] && exit 1

# Optional native dry-run, only via the project-declared command in
# canon/project.json ("migration_dry_run_cmd"). The environment is
# caller-controllable, so a DRY_RUN_CMD env var is never honored.
# Fail closed: an existing but unreadable/malformed project.json is
# an error, not a silent skip - a corrupted manifest must not weaken
# the gate. Absent file = no dry-run declared, skip as before.
DRY_RUN=""
if [ -f "$CANON_DIR/project.json" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "MIGRATION GATE FAIL: python3 required to read $CANON_DIR/project.json" >&2
    exit 1
  fi
  if ! DRY_RUN=$(HYGIENE_PJ="$CANON_DIR/project.json" python3 -I -c "import json,os; v=json.load(open(os.environ['HYGIENE_PJ'])).get('migration_dry_run_cmd','') or ''; print(v if isinstance(v,str) else '')" 2>/dev/null); then
    echo "MIGRATION GATE FAIL: $CANON_DIR/project.json exists but is not valid JSON" >&2
    exit 1
  fi
fi
if [ -n "$DRY_RUN" ]; then
  # The dry-run reads the WORKTREE while coverage checks read the
  # INDEX. Require parity on every migration-pattern path - a benign
  # unstaged shadow of a destructive staged blob would make the
  # dry-run certify a different file than the one being committed.
  PARITY_DIFF=$(git diff --name-only -z -- . 2>/dev/null | grep -zE "$MIG_PAT" || true)
  if [ -n "$PARITY_DIFF" ]; then
    echo "MIGRATION GATE FAIL: worktree/index divergence on migration files:" >&2
    printf '%s\n' "$PARITY_DIFF" | tr '\0' '\n' | sed 's/^/  /' >&2
    echo "(stage or revert the working-tree edits before committing)" >&2
    exit 1
  fi
  # GNU coreutils 'timeout' or its BSD/gnu-getopt twin 'gtimeout'.
  TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
  if [ -z "$TIMEOUT_BIN" ]; then
    echo "MIGRATION GATE FAIL: dry-run declared but neither 'timeout'" >&2
    echo "nor 'gtimeout' is available on PATH - cannot bound it" >&2
    exit 1
  fi
  echo "running project dry-run: $DRY_RUN"
  "$TIMEOUT_BIN" 120 env DRY_RUN=1 bash -c "$DRY_RUN" || {
    echo "MIGRATION GATE FAIL: dry-run exited non-zero" >&2; exit 1; }
fi

if [ $CHECK_ONLY -eq 1 ]; then
  echo "check-only: all ${#staged[@]} migration file(s) verified"
  exit 0
fi

# Informational stamp: binds the full staged footprint of
# migration-pattern files (mode+blob+path per ls-files entry, plus
# staged deletions as D:<path> lines). NOT consulted by ship_commit -
# kept only as an audit record of what was verified and when.
HASH_BIN=$(command -v sha256sum || command -v shasum || true)
[ -z "$HASH_BIN" ] && { echo "MIGRATION GATE FAIL: no sha256 tool on PATH" >&2; exit 1; }
[ "${HASH_BIN##*/}" = "shasum" ] && HASH_BIN="$HASH_BIN -a 256"
want=$( { for f in ${all_mig[@]+"${all_mig[@]}"}; do GIT_LITERAL_PATHSPECS=1 git ls-files -s -z -- "$f" | tr '\0' '\n'; done; for d in ${deleted[@]+"${deleted[@]}"}; do printf 'D:%s\n' "$d"; done; } | sort | $HASH_BIN | cut -d' ' -f1)
{
  echo "files=$want"
  echo "verified_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'list=%s\n' "${staged[*]:-}"
} > "$CANON_DIR/migration_ok"
echo "stamp written: $CANON_DIR/migration_ok"
