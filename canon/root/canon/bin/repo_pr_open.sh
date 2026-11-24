#!/usr/bin/env bash
# repo_pr_open.sh - open a PR through the hygiene gate.
# Usage: repo_pr_open.sh --branch i_NN --base main --issue N \
#        --title "..." --body "..."
# Output JSON: {pr_url, pr_number, status}
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

# Repository-agent credential for repository mutations (merge.gh_bin
# -> gh), NEVER the reviewer identity (self-approve
# deadlock + signal forgery).
GH=$("$CANON_DIR/bin/gh_id.sh" merge)
[ -n "$GH" ] || { echo "merge.gh_bin in project.json is not a bare binary basename" >&2; exit 2; }

BRANCH=""; BASE=""; ISSUE=""; TITLE=""; BODY=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
  case "$1" in
    --branch) BRANCH=$2;; --base) BASE=$2;; --issue) ISSUE=$2;;
    --title) TITLE=$2;; --body) BODY=$2;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift 2
done
[ -n "$BRANCH" ] && [ -n "$TITLE" ] || {
  echo '{"status":"error","failure_class":"malformed_input","message":"--branch and --title required"}'; exit 2; }
[ -n "$BASE" ] || BASE=$("$GH" repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
[[ "$BASE" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
  echo '{"status":"error","failure_class":"malformed_input","message":"unsafe --base ref"}'; exit 2; }
if [ -n "$ISSUE" ]; then
  [[ "$ISSUE" =~ ^[0-9]+$ ]] && [ "$ISSUE" -gt 0 ] || {
    echo '{"status":"error","failure_class":"malformed_input","message":"--issue must be a positive number"}'; exit 2; }
fi

# The branch convention binds a PR to its issue: an issue_<N>-<slug>
# or epic_issue_<N>-<slug> branch MUST produce a body with
# "Closes #N" - the verify_constraints link check would otherwise
# pass a PR that never re-verifies the link.
if [ -z "$ISSUE" ] && [[ "$BRANCH" =~ ^(epic_)?issue_([0-9]+)- ]]; then
  ISSUE=$((10#${BASH_REMATCH[2]}))
fi
if [ -n "$ISSUE" ] && ! printf '%s' "$BODY" | grep -qiE "(closes|fixes|resolves)[[:space:]]+#$ISSUE([^0-9]|$)"; then
  BODY="${BODY:+$BODY

}Closes #$ISSUE"
fi
# A branch covering several items links every issue: extras come from
# env ISSUE_NUMS (space/comma separated), same "Closes #N" contract as
# the branch-name issue (verify_constraints.sh checks each one).
for extra in $(printf '%s' "${ISSUE_NUMS:-}" | tr ',' ' '); do
  # normalize: "007" and "7" are the same issue; reject non-numeric
  [[ "$extra" =~ ^[0-9]+$ ]] || {
    echo '{"status":"error","failure_class":"malformed_input","message":"ISSUE_NUMS entries must be numeric"}'; exit 2; }
  extra=$((10#$extra))
  [ "$extra" = "$ISSUE" ] && continue
  printf '%s' "$BODY" | grep -qiE "(closes|fixes|resolves)[[:space:]]+#$extra([^0-9]|$)" \
    || BODY="${BODY:+$BODY

}Closes #$extra"
done

# Fragments carried by the branch must be mentionable: the merge
# gate only allows a fragment issue: that is the branch issue or a
# #N referenced in the body (FRAG_ISSUES). An epic accumulates task
# fragments - link each declared issue: as `Includes #M` (a
# reference, not a close: task issues close on task->epic landing).
# Only fragments introduced/changed BY THIS BRANCH count - globbing
# the whole .changes/ dir would attribute foreign fragments already
# sitting on the base (e.g. an epic's earlier task fragments) to this
# PR and let it edit them via FRAG_ISSUES.
BASE_REF=""
for r in $(git remote 2>/dev/null | sed "s#\$#/$BASE#") "$BASE"; do
  git rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { BASE_REF=$r; break; }
done
DELTA_FRAGS=""
[ -n "$BASE_REF" ] && DELTA_FRAGS=$(git diff --name-only --diff-filter=ACMR \
  "$BASE_REF"...HEAD -- '.changes/*.md' 2>/dev/null || true)
for frag in $DELTA_FRAGS; do
  [ -f "$frag" ] || continue
  # The directory's own README may document an example 'issue:'
  # field - it is not a release fragment (same exclusion as
  # issue_merge/spec_anchor_check/repo_release).
  [ "$frag" = ".changes/README.md" ] && continue
  # Leading key: value zone, optional '---' fences - same contract as
  # spec_anchor_check.sh front_fields (fragments may omit '---').
  # 'issue:' may be a comma list or carry '#' marks/quotes/comments:
  # every number is extracted in Python - concatenating digits via
  # tr would weld '10, 11' into a phantom '#1011'.
  fi_nums=$(CANON_DIR="$CANON_DIR" python3 -I - "$frag" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ.get("CANON_DIR") or "", "bin"))
from changes_parser import front_fields, issue_numbers
body = open(sys.argv[1], encoding="utf-8", errors="replace").read()
print(" ".join(str(n) for n in issue_numbers(front_fields(body).get("issue"))))
PY
)
  for fi_n in $fi_nums; do
    printf '%s' "$BODY" | grep -qE "#$fi_n([^0-9]|$)" \
      || BODY="${BODY:+$BODY

}Includes #$fi_n"
  done
done

HYGIENE_OUT=$(printf '%s\n%s\n' "$TITLE" "$BODY" | "$CANON_DIR/bin/hygiene_check.sh")
if [ $? -ne 0 ]; then
  HYGIENE_OUT="$HYGIENE_OUT" python3 -I -c 'import json,os
try: v=json.loads(os.environ["HYGIENE_OUT"])
except Exception: v={"raw": os.environ["HYGIENE_OUT"]}
print(json.dumps({"status":"error","failure_class":"gate_blocked","violations":v.get("violations",v)}))'
  exit 2
fi

URL=$("$GH" pr create --head "$BRANCH" --base "$BASE" --title "$TITLE" --body "$BODY" 2>&1) || {
  python3 -I -c 'import json,sys;print(json.dumps({"status":"error","failure_class":"upstream_error","message":sys.argv[1]}))' "$URL"
  exit 1
}
NUM=$(basename "$URL")
[[ "$NUM" =~ ^[0-9]+$ ]] || {
  python3 -I -c 'import json,sys;print(json.dumps({"status":"error","failure_class":"upstream_error","message":"unparseable gh pr create output"}))'
  exit 1
}
python3 -I -c 'import json,sys;print(json.dumps({"pr_url":sys.argv[2],"pr_number":int(sys.argv[1]),"status":"ok"}))' "$NUM" "$URL"
