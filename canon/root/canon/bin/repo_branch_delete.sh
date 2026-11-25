#!/usr/bin/env bash
# repo_branch_delete.sh - delete an issue_<N>-<slug> /
# epic_issue_<N>-<slug> branch locally
# and on the github remote. Base branches and non-convention names
# are refused unless --force is given (records the override reason).
# Usage: repo_branch_delete.sh <branch> [--remote-only|--local-only] [--force]
# Output JSON: {branch, deleted, status}
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

# Network discipline (review_16 #13): no forge/git call may hang a
# gate slot forever - prompt-hangs die instantly via the env flags,
# transport stalls die via `timeout` where the binary exists.
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30
NET_TO=$(command -v timeout || command -v gtimeout || true)
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

BASE=$(${NET_TO:+$NET_TO 120} "$GH" repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
if [ "$BRANCH" = "$BASE" ] || [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  echo '{"status":"error","failure_class":"gate_blocked","message":"refusing to delete base branch"}'
  exit 2
fi
if [ "$FORCE" -eq 0 ] && [[ ! "$BRANCH" =~ ^(epic_)?issue_[0-9]+-[a-z0-9][a-z0-9_-]*$|^i_[0-9]+$|^release/v[0-9]+\.[0-9]+\.[0-9]+(-r[0-9a-zA-Z]+)?$ ]]; then
  echo "{\"status\":\"error\",\"failure_class\":\"gate_blocked\",\"message\":\"branch '$BRANCH' is not an issue branch - pass --force to delete anyway\"}"
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
[ -z "${REMOTE:-}" ] && REMOTE=$(git remote get-url origin >/dev/null 2>&1 && echo origin)
DELETED=()
REMOTE_ERR=""
if [ "$SCOPE" != "local" ] && [ -n "${REMOTE:-}" ]; then
  if ${NET_TO:+$NET_TO 300} git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    PUSH_ERR=$(${NET_TO:+$NET_TO 300} git push "$REMOTE" --delete "$BRANCH" 2>&1) && {
      # verify the remote ref is actually gone - a swallowed delete
      # must not report as deleted
      if ${NET_TO:+$NET_TO 300} git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
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
