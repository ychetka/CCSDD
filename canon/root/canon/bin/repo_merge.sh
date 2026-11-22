#!/usr/bin/env bash
# repo_merge.sh - merge-gate entry point: routes the PR by its head
# branch convention to the specialized merge script.
#   epic_issue_<N>-<slug> head -> epic_merge.sh (epic completeness
#                                 gate, then the common pipeline)
#   any other head             -> issue_merge.sh (the common
#                                 objective merge gate)
# Usage: repo_merge.sh <pr_number> <expected_head_sha> [squash|merge|rebase]
set -uo pipefail
# CANON_DIR resolves from the script location, not the git top: in
# nested workspaces the git top may be a subdir like code/ while
# canon/ lives at the workspace root.
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

json_error() {
  python3 -c 'import json,sys;print(json.dumps({"status":"error","failure_class":sys.argv[1],"message":sys.argv[2]}))' "$1" "$2"
  exit 1
}

PR="${1:-}"
[[ "$PR" =~ ^[0-9]+$ ]] || json_error malformed_input "pr_number must be a positive integer"

# GitHub CLI resolution: merges run under the repository-agent
# credential, NOT the reviewer identity - separation of powers.
# project.json `merge.gh_bin` names that binary (fallback:
# review.gh_bin, then plain `gh`). Anything else - paths,
# undeclared names - would run an arbitrary binary under the merge
# credentials.
GH=$(CANON_DIR="$CANON_DIR" python3 -c 'import json,os,re
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
    gb = ((pj.get("merge") or {}).get("gh_bin")) \
         or ((pj.get("review") or {}).get("gh_bin")) or "gh"
    print(gb if isinstance(gb, str) and re.fullmatch(r"[A-Za-z0-9_-]+", gb) else "")
except Exception:
    print("gh")' 2>/dev/null)
[ -n "$GH" ] || json_error malformed_input "merge.gh_bin in project.json is not a bare binary basename"
command -v "$GH" >/dev/null 2>&1 || json_error upstream_error "github cli '$GH' not found on PATH"

INFO_ERR=$(mktemp)
INFO=$("$GH" pr view "$PR" --json headRefName 2>"$INFO_ERR") || {
  json_error upstream_error "$(cat "$INFO_ERR" 2>/dev/null | head -c 300)"
}
rm -f "$INFO_ERR"
HEAD_BRANCH=$(INFO="$INFO" python3 -c 'import json,os,sys;print((json.loads(os.environ["INFO"]) or {}).get("headRefName") or "")' 2>/dev/null)

case "$HEAD_BRANCH" in
  epic_issue_*) exec "$CANON_DIR/bin/epic_merge.sh" "$@" ;;
  *)            exec "$CANON_DIR/bin/issue_merge.sh" "$@" ;;
esac
