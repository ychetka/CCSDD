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

# Network discipline (review_16 #13): no forge/git call may hang a
# gate slot forever - prompt-hangs die instantly via the env flags,
# transport stalls die via `timeout` where the binary exists.
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30
NET_TO=$(command -v timeout || command -v gtimeout || true)
# Gate 0 (review_15 #5): the merge path must never run under a
# workspace-tampered canon - prove manifest hashes + the external
# stamp before trusting any $CANON_DIR script or adapter hook.
if [ -f "$CANON_DIR/canon_manifest.json" ]; then
  [ -x "$CANON_DIR/bin/assert_canon_integrity.sh" ] \
    || { echo "GATE_INTEGRITY: assert_canon_integrity.sh missing under a pinned manifest" >&2; exit 1; }
  "$CANON_DIR/bin/assert_canon_integrity.sh" || exit 1
fi
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

json_error() {
  python3 -I -c 'import json,sys;print(json.dumps({"status":"error","failure_class":sys.argv[1],"message":sys.argv[2]}))' "$1" "$2"
  exit 1
}

PR="${1:-}"
[[ "$PR" =~ ^[0-9]+$ ]] || json_error malformed_input "pr_number must be a positive integer"

# GitHub CLI resolution: merges run under the repository-agent
# credential, NOT the reviewer identity - separation of powers.
# project.json `merge.gh_bin` names that binary (fallback:
# plain `gh`). Never review.gh_bin. Anything else - paths,
# undeclared names - would run an arbitrary binary under the merge
# credentials.
GH=$("$CANON_DIR/bin/gh_id.sh" merge)
[ -n "$GH" ] || json_error malformed_input "merge.gh_bin in project.json is not a bare binary basename"
command -v "$GH" >/dev/null 2>&1 || json_error upstream_error "github cli '$GH' not found on PATH"

INFO_ERR=$(mktemp)
INFO=$(${NET_TO:+$NET_TO 120} "$GH" pr view "$PR" --json headRefName 2>"$INFO_ERR") || {
  json_error upstream_error "$(cat "$INFO_ERR" 2>/dev/null | head -c 300)"
}
rm -f "$INFO_ERR"
HEAD_BRANCH=$(INFO="$INFO" python3 -I -c 'import json,os,sys;print((json.loads(os.environ["INFO"]) or {}).get("headRefName") or "")' 2>/dev/null)

case "$HEAD_BRANCH" in
  epic_issue_*) exec "$CANON_DIR/bin/epic_merge.sh" "$@" ;;
  *)            exec "$CANON_DIR/bin/issue_merge.sh" "$@" ;;
esac
