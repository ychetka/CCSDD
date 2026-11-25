#!/usr/bin/env bash
# repo_issue_comment.sh - post a comment on a GitHub issue through the
# hygiene gate.
# Usage: repo_issue_comment.sh <issue_number> --body "<text>"
# Output JSON: {issue_id, url, status}
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

# Network discipline (review_16 #13): no forge/git call may hang a
# gate slot forever - prompt-hangs die instantly via the env flags,
# transport stalls die via `timeout` where the binary exists.
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30
NET_TO=$(command -v timeout || command -v gtimeout || true)

GH=$("$CANON_DIR/bin/gh_id.sh" merge)
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

ISSUE="${1:?usage: repo_issue_comment.sh <issue_number> --body \"<text>\"}"
shift || true
[[ "$ISSUE" =~ ^[0-9]+$ ]] || { echo '{"status":"error","failure_class":"malformed_input","message":"issue_number must be numeric"}'; exit 2; }
BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body) BODY="${2:?--body needs text}"; shift 2 ;;
    *) echo '{"status":"error","failure_class":"malformed_input","message":"unknown arg"}'; exit 2 ;;
  esac
done
[ -n "$BODY" ] || { echo '{"status":"error","failure_class":"malformed_input","message":"--body required"}'; exit 2; }

HYGIENE_OUT=$(printf '%s\n' "$BODY" | "$CANON_DIR/bin/hygiene_check.sh")
if [ $? -ne 0 ]; then
  HYGIENE_OUT="$HYGIENE_OUT" python3 -I -c 'import json,os
try: v=json.loads(os.environ["HYGIENE_OUT"])
except Exception: v={"raw": os.environ["HYGIENE_OUT"]}
print(json.dumps({"status":"error","failure_class":"gate_blocked","violations":v.get("violations",v)}))'
  exit 2
fi

URL=$(${NET_TO:+$NET_TO 120} "$GH" issue comment "$ISSUE" --body "$BODY" 2>&1) || {
  python3 -I -c 'import json,sys;print(json.dumps({"status":"error","failure_class":"upstream_error","message":sys.argv[1]}))' "$URL"
  exit 1
}
python3 -I -c 'import json,sys;print(json.dumps({"issue_id":int(sys.argv[1]),"url":sys.argv[2].strip(),"status":"ok"}))' "$ISSUE" "$URL"
