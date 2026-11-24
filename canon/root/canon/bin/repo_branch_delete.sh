#!/usr/bin/env bash
# repo_branch_delete.sh - delete an issue_<N>-<slug> /
# epic_issue_<N>-<slug> branch locally
# and on the github remote. Base branches and non-convention names
# are refused unless --force is given (records the override reason).
# Usage: repo_branch_delete.sh <branch> [--remote-only|--local-only] [--force]
# Output JSON: {branch, deleted, status}
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

# Repository-agent credential for repository mutations (merge.gh_bin
# -> gh), NEVER the reviewer identity (self-approve
# deadlock + signal forgery).
GH=$("$CANON_DIR/bin/gh_id.sh" merge)
[ -n "$GH" ] || { echo "merge.gh_bin in project.json is not a bare binary basename" >&2; exit 2; }

BRANCH="${1:?usage: repo_branch_delete.sh <branch> [--remote-only|--local-only] [--force]}"
shift || true
SCOPE=both; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remote-only) SCOPE=remote; shift ;;
    --local-only)  SCOPE=local; shift ;;
    --force)       FORCE=1; shift ;;
    *) echo '{"status":"error","failure_class":"malformed_input","message":"unknown arg"}'; exit 2 ;;
  esac
done

BASE=$("$GH" repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
if [ "$BRANCH" = "$BASE" ] || [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  echo '{"status":"error","failure_class":"gate_blocked","message":"refusing to delete base branch"}'
  exit 2
fi
if [ "$FORCE" -eq 0 ] && [[ ! "$BRANCH" =~ ^(epic_)?issue_[0-9]+-[a-z0-9][a-z0-9_-]*$|^i_[0-9]+$|^release/v[0-9]+\.[0-9]+\.[0-9]+(-r[0-9a-zA-Z]+)?$ ]]; then
  echo "{\"status\":\"error\",\"failure_class\":\"gate_blocked\",\"message\":\"branch '$BRANCH' is not an issue branch - pass --force to delete anyway\"}"
  exit 2
fi

REMOTE=$(git remote -v | awk '$2 ~ /github\.com/ {print $1; exit}')
[ -z "${REMOTE:-}" ] && REMOTE=$(git remote get-url origin >/dev/null 2>&1 && echo origin)
DELETED=()
REMOTE_ERR=""
if [ "$SCOPE" != "local" ] && [ -n "${REMOTE:-}" ]; then
  if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    PUSH_ERR=$(git push "$REMOTE" --delete "$BRANCH" 2>&1) && {
      # verify the remote ref is actually gone - a swallowed delete
      # must not report as deleted
      if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
        REMOTE_ERR="remote delete accepted but branch still present"
      else
        DELETED+=("remote")
      fi
    } || REMOTE_ERR="$PUSH_ERR"
  fi
fi
if [ "$SCOPE" != "remote" ] && git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git branch -D "$BRANCH" >/dev/null 2>&1 && DELETED+=("local")
fi

if [ -n "$REMOTE_ERR" ]; then
  python3 -I -c 'import json,sys;print(json.dumps({"branch":sys.argv[1],"status":"error","failure_class":"upstream_error","message":sys.argv[2],"deleted":sys.argv[3].split(",") if sys.argv[3] else []}))' \
    "$BRANCH" "$REMOTE_ERR" "$(IFS=,; echo "${DELETED[*]:-}")"
  exit 1
fi
if [ ${#DELETED[@]} -eq 0 ]; then
  python3 -I -c 'import json,sys;print(json.dumps({"branch":sys.argv[1],"status":"not_found"}))' "$BRANCH"
  exit 1
fi
python3 -I -c 'import json,sys;print(json.dumps({"branch":sys.argv[1],"deleted":sys.argv[2].split(","),"status":"ok"}))' "$BRANCH" "$(IFS=,; echo "${DELETED[*]}")"
