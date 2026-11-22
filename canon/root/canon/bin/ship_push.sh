#!/usr/bin/env bash
# ship_push.sh - push wrapper. Verifies branch convention and clean
# state, pushes current branch with upstream tracking.
set -uo pipefail
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ ! "$BRANCH" =~ ^(epic_)?issue_[0-9]+-[a-z0-9][a-z0-9_-]*$ ]]; then
  echo "PUSH BLOCKED: branch '$BRANCH' is not issue_<N>-<slug> | epic_issue_<N>-<slug>" >&2
  exit 2
fi

DIRTY=$(git status --porcelain | grep -c . || true)
if [ "${DIRTY:-0}" -gt 0 ]; then
  echo "PUSH BLOCKED: uncommitted or untracked changes present" >&2
  exit 2
fi

# Remote: prefer the remote whose URL points at github.com (the PR
# target), fall back to origin only when no github remote exists.
REMOTE=$(git remote -v | awk '$2 ~ /github\.com/ {print $1; exit}')
if [ -z "${REMOTE:-}" ] && git remote get-url origin >/dev/null 2>&1; then
  REMOTE=origin
fi
if [ -z "${REMOTE:-}" ]; then
  echo "PUSH BLOCKED: no github remote configured" >&2
  exit 2
fi

git push -u "$REMOTE" "$BRANCH" "$@"
