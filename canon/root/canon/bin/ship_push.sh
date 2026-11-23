#!/usr/bin/env bash
# ship_push.sh - push wrapper. Verifies branch convention and clean
# state, pushes current branch with upstream tracking.
set -uo pipefail
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
# release/<ver>[-r<sha>] is pushed by repo_release.sh --push-tag as
# part of release-on-merge; keeping it legal here preserves the
# atomic head+tag push for humans and runtime adapters.
if [[ ! "$BRANCH" =~ ^(epic_)?issue_[0-9]+-[a-z0-9][a-z0-9_-]*$ \
      && ! "$BRANCH" =~ ^release/[0-9]+\.[0-9]+\.[0-9]+(-r[0-9a-f]+)?$ ]]; then
  echo "PUSH BLOCKED: branch '$BRANCH' is not issue_<N>-<slug> | epic_issue_<N>-<slug> | release/<semver>[-r<sha>]" >&2
  exit 2
fi

# Canon runtime journals are runtime-local and gitignored in item
# worktrees (they may sit untracked under an unpinned canon checkout)
# - they never make the head "dirty" for push purposes. Same class of
# exemption as DIRTY_FILE_RE in gate_run.sh / verify_constraints.sh.
DIRTY=$(git status --porcelain | grep -vE '^.. canon/[^/]*\.(lock|tmp)$' | grep -c . || true)
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
