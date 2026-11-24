#!/usr/bin/env bash
# epic_merge.sh - merge gate for epic_issue_<N>-<slug> heads.
# Runs the EPIC COMPLETENESS GATE before delegating to
# issue_merge.sh for the common objective merge pipeline:
#   * the epic's roadmap item (the deployed canon/roadmap.md in the
#     workspace - it is a working document, gitignored by design -
#     matched by `issue: <N>`) must declare `type: epic` and
#     `tasks: [M,...]`;
#   * every declared task issue M must be SHIPPED - a
#     .changes/<slug>.md fragment with `issue: M` in the
#     base...head diff (task merges into the epic branch are
#     fragment-gated, so presence = objective evidence);
#   * every declared task issue M must be CLOSED in the tracker -
#     the repository agent closes a task issue when its PR lands
#     on the epic branch.
# Blocks with {status: blocked, failure_class: epic_incomplete,
# tasks_pending:[...]} otherwise; never merges a partial epic.
# Usage: epic_merge.sh <pr_number> <expected_head_sha> [squash|merge|rebase]
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

json_error() {
  python3 -I -c 'import json,sys;print(json.dumps({"status":"error","failure_class":sys.argv[1],"message":sys.argv[2]}))' "$1" "$2"
  exit 1
}
json_blocked() {
  python3 -I -c 'import json,sys;print(json.dumps({"status":"blocked","failure_class":sys.argv[1],"message":sys.argv[2]}))' "$1" "$2"
  exit 1
}

PR="${1:-}"
EXPECTED="${2:-}"
METHOD="${3:-squash}"
[[ "$PR" =~ ^[0-9]+$ ]] || json_error malformed_input "pr_number must be a positive integer"
[[ "$EXPECTED" =~ ^[0-9a-f]{40}$ ]] || json_error malformed_input "expected head sha must be a 40-char hex string"
case "$METHOD" in
  squash|merge|rebase) ;;
  *) json_error malformed_input "merge method must be squash|merge|rebase" ;;
esac

# GitHub CLI resolution (same contract as repo_merge.sh).
GH=$("$CANON_DIR/bin/gh_id.sh" merge)
[ -n "$GH" ] || json_error malformed_input "merge.gh_bin in project.json is not a bare binary basename"
command -v "$GH" >/dev/null 2>&1 || json_error upstream_error "github cli '$GH' not found on PATH"

INFO_ERR=$(mktemp)
INFO=$("$GH" pr view "$PR" --json headRefName,baseRefName 2>"$INFO_ERR") || {
  json_error upstream_error "$(cat "$INFO_ERR" 2>/dev/null | head -c 300)"
}
rm -f "$INFO_ERR"
HEAD_BRANCH=$(INFO="$INFO" python3 -I -c 'import json,os;print((json.loads(os.environ["INFO"]) or {}).get("headRefName") or "")' 2>/dev/null)
BASE=$(INFO="$INFO" python3 -I -c 'import json,os;print((json.loads(os.environ["INFO"]) or {}).get("baseRefName") or "")' 2>/dev/null)

[[ "$HEAD_BRANCH" =~ ^epic_issue_([0-9]+)-[a-z0-9][a-z0-9_-]*$ ]] \
  || json_error gate_blocked "epic_merge.sh requires an epic_issue_<N>-<slug> head, got '$HEAD_BRANCH' (route via repo_merge.sh)"
EN=$((10#${BASH_REMATCH[1]}))
[ -n "$BASE" ] || json_error upstream_error "baseRefName missing from PR metadata"

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
[ -n "${REMOTE:-}" ] || json_error upstream_error "no git remote found"

# The completeness gate diffs the head against its merge base - the
# head object must be local.
git cat-file -e "$EXPECTED" 2>/dev/null \
  || git fetch -q "$REMOTE" "$HEAD_BRANCH" >/dev/null 2>&1 || true
git cat-file -e "$EXPECTED" 2>/dev/null \
  || json_error upstream_error "expected head $EXPECTED not available locally"

# canon/roadmap.md is a deployed working document (gitignored by
# design, canon manifest entry) - read the live workspace copy. It
# lives next to this script (CANON_DIR), not under the code repo
# top: the supported nested layout keeps canon/ as a workspace
# sibling of code/.
TMPD_RM="$CANON_DIR/roadmap.md"
[ -f "$TMPD_RM" ] \
  || json_blocked epic_incomplete "canon/roadmap.md missing in the workspace - the epic item cannot be resolved"

# Roadmap resolve: the `## Item` block declaring `issue: <EN>` must
# be `type: epic` with a non-empty `tasks: [M,...]` list.
TASKS=$(RM="$TMPD_RM" EN="$EN" python3 -I - <<'PY'
import json, os, re
en = os.environ["EN"]
body = open(os.environ["RM"], encoding="utf-8", errors="replace").read()
def _issue_num(v):
    # 'issue: #9' / 'issue: 9 # main epic' all denote issue 9.
    v = re.split(r"\s*#", (v or "").strip(), 1)[0]
    v = v.lstrip("#").strip()
    return str(int(v)) if v.isdigit() else ""

blocks = re.split(r"(?m)^##\s+Item\s*:", body)[1:]
item = None
for b in blocks:
    fields = dict(re.findall(r"(?m)^\s*-\s*([a-z_]+)\s*:\s*(.+?)\s*$", b))
    if _issue_num(fields.get("issue")) == en:
        item = fields; break
if item is None:
    print(json.dumps({"error": "no roadmap item declares 'issue: %s'" % en})); raise SystemExit(0)
if item.get("type", "").strip() != "epic":
    print(json.dumps({"error": "roadmap item with 'issue: %s' is not 'type: epic'" % en})); raise SystemExit(0)
raw = (item.get("tasks") or "").strip()
nums = [n.strip() for n in raw.strip("[]").split(",") if n.strip()]
if not nums or not all(re.fullmatch(r"\d+", n) for n in nums):
    print(json.dumps({"error": "epic item must declare 'tasks: [<issue numbers>]'" })); raise SystemExit(0)
print(json.dumps({"tasks": [str(int(n)) for n in nums]}))
PY
)
TASKS_ERR=$(TASKS="$TASKS" python3 -I -c 'import json,os;print(json.loads(os.environ["TASKS"]).get("error") or "")')
if [ -n "$TASKS_ERR" ]; then
  json_blocked epic_incomplete "$TASKS_ERR"
fi

# Frozen-plan integrity: every roadmap item carrying a recorded
# frozen_hash must still hash to it (canonicalization: mutable
# fields status/pr/issue/frozen_hash are stripped before sha256 -
# see bin/roadmap_hash.sh). Drift = the plan was edited after
# freeze; the epic must not merge on a mutated contract.
if ! "$CANON_DIR/bin/roadmap_hash.sh" --verify; then
  json_blocked plan_drift "canon/roadmap.md frozen_hash mismatch - the frozen plan was edited; re-freeze through the arch committee"
fi

# Objective evidence per task: fragment with `issue: M` in the
# merge-base..head diff AND issue state CLOSED.
PENDING=$(EXPECTED="$EXPECTED" BASE_REF="$REMOTE/$BASE" TASKS="$TASKS" python3 -I - <<'PY'
import json, os, re, subprocess
expected = os.environ["EXPECTED"]; base = os.environ["BASE_REF"]
tasks = json.loads(os.environ["TASKS"])["tasks"]
mb = subprocess.run(["git","merge-base",base,expected],
                    capture_output=True,text=True).stdout.strip()
names = subprocess.run(["git","diff","--name-only",mb,expected],
                       capture_output=True,text=True).stdout.splitlines()
frags = [n.strip() for n in names
         if n.strip().startswith(".changes/") and n.strip().endswith(".md")
         and not n.strip().endswith("/README.md")]
have = set()
for f in frags:
    try:
        body = subprocess.run(["git","show","%s:%s"%(expected,f)],
                              capture_output=True,text=True).stdout
    except Exception:
        continue
    # Leading key: value zone only (optional '---' fences) - the same
    # front_fields contract as spec_anchor_check; an 'issue:' mention
    # inside the prose body must not count as a declaration.
    lines = body.splitlines()
    start = 1 if lines and lines[0].strip() == "---" else 0
    for ln in lines[start:]:
        s = ln.strip()
        if s == "---" or s.startswith("#"):
            break
        m = re.match(r"^issue\s*:\s*([#\d,\s'\"]+)", ln)
        if m:
            have.update(x.strip().strip('"').strip("'").lstrip("#")
                        for x in m.group(1).split(",")
                        if x.strip().strip('"').strip("'").lstrip("#"))
            break
        if s and not re.match(r"^[A-Za-z_]+\s*:", ln):
            break
pending = [t for t in tasks if t not in have]
print(json.dumps({"pending": pending, "have": sorted(have, key=int)}))
PY
)
PEND_LIST=$(PENDING="$PENDING" python3 -I -c 'import json,os;print(" ".join(json.loads(os.environ["PENDING"])["pending"]))')
if [ -n "$PEND_LIST" ]; then
  json_blocked epic_incomplete "task issue(s) #$PEND_LIST have no .changes fragment on the epic branch - not shipped into the epic"
fi

# Tracker evidence: every declared task issue must be CLOSED.
# A failed upstream call is an infrastructure error (upstream_error),
# not a substantive epic_incomplete block - the routings differ.
OPEN_TASKS=""
for t in $(TASKS="$TASKS" python3 -I -c 'import json,os;print(" ".join(json.loads(os.environ["TASKS"])["tasks"]))'); do
  st_json=$("$GH" issue view "$t" --json state 2>/dev/null) \
    || json_error upstream_error "failed to query issue #$t state"
  st=$(printf '%s' "$st_json" | python3 -I -c 'import json,sys;print((json.load(sys.stdin) or {}).get("state") or "")' 2>/dev/null) \
    || json_error upstream_error "unparseable issue #$t state payload"
  [ "$st" = "CLOSED" ] || OPEN_TASKS="$OPEN_TASKS $t"
done
if [ -n "$OPEN_TASKS" ]; then
  json_blocked epic_incomplete "task issue(s)#$OPEN_TASKS are not CLOSED - close them via repository-agent when the task lands on the epic branch"
fi

EPIC_GATE_PASSED=1 exec "$CANON_DIR/bin/issue_merge.sh" "$@"
