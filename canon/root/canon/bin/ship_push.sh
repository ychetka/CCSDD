#!/usr/bin/env bash
# ship_push.sh - push wrapper. Verifies branch convention and clean
# state, pushes current branch with upstream tracking.
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
# release/v<ver>[-r<sha>] is pushed by repo_release.sh --push-tag as
# part of release-on-merge (TAG="v$NEXT", RBR="release/$TAG" -
# the v prefix is mandatory). Keeping it legal here preserves the
# atomic head+tag push for humans and runtime adapters.
if [[ ! "$BRANCH" =~ ^(epic_)?issue_[0-9]+-[a-z0-9][a-z0-9_-]*$ \
      && ! "$BRANCH" =~ ^release/v[0-9]+\.[0-9]+\.[0-9]+(-r[0-9a-zA-Z]+)?$ ]]; then
  echo "PUSH BLOCKED: branch '$BRANCH' is not issue_<N>-<slug> | epic_issue_<N>-<slug> | release/v<semver>[-r<sha>]" >&2
  exit 2
fi

# Canon runtime journals are runtime-local and gitignored in item
# worktrees (they may sit untracked under an unpinned canon checkout)
# - they never make the head "dirty" for push purposes. Same exempt
# set as gate_run.sh's DIRTY regex: journals, fixtures, signoff
# stores, locks and temp files.
DIRTY=$(git status --porcelain | grep -vE \
  'canon/(gate_runs\.jsonl.*|cycle_log\.jsonl.*|actors\.json.*|panel_signals_fixture\.json.*|panel_comments_fixture\.jsonl.*|release_history\.jsonl.*|human_signoffs/|quota_park\.json.*|gateway|harness_log\.jsonl.*|migration_ok|scope_whitelist\.txt|canon_manifest\.json|.*\.(lock|tmp))|.*__pycache__/.*|.*\.pyc' \
  | grep -c . || true)
if [ "${DIRTY:-0}" -gt 0 ]; then
  echo "PUSH BLOCKED: uncommitted or untracked changes present" >&2
  exit 2
fi

# Remote: prefer the remote whose URL ends with the project.json
# repo slug (forge-agnostic - works for github/gitlab/custom hosts),
# then any forge-looking URL; 'origin' is only the last resort.
REPO_SLUG=$(CANON_DIR="$CANON_DIR" python3 -I -c 'import json,os
try: print((json.load(open(os.path.join(os.environ["CANON_DIR"],"project.json"))).get("repo") or "").strip("/"))
except Exception: print("")' 2>/dev/null)
REMOTE=""
if [ -n "$REPO_SLUG" ]; then
  REMOTE=$(git remote -v | awk -v s="$REPO_SLUG" '$2 ~ ("(^|[:/])" s "(\\.git)?$") {print $1; exit}')
fi
[ -z "${REMOTE:-}" ] && REMOTE=$(git remote -v | awk '$2 ~ /github\.com|gitlab\./ {print $1; exit}')
if [ -z "${REMOTE:-}" ] && git remote get-url origin >/dev/null 2>&1; then
  REMOTE=origin
fi
if [ -z "${REMOTE:-}" ]; then
  echo "PUSH BLOCKED: no github remote configured" >&2
  exit 2
fi

git push -u "$REMOTE" "$BRANCH" "$@"
