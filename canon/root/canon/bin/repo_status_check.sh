#!/usr/bin/env bash
# repo_status_check.sh - report checks and mergeability of a PR.
# Usage: repo_status_check.sh <pr_number>
# Output JSON: {checks:[{name,state,required}], mergeable, status}
set -uo pipefail
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

PR="${1:?usage: repo_status_check.sh <pr_number>}"

GH_OUT=$(gh pr view "$PR" --json statusCheckRollup,mergeable,reviews,headRefOid 2>/dev/null) || {
  echo '{"status":"error","failure_class":"upstream_error","message":"gh pr view failed"}'
  exit 1
}
GH_OUT="$GH_OUT" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ["GH_OUT"])
except Exception:
    print(json.dumps({"status":"error","failure_class":"upstream_error",
                      "message":"unparseable gh output"}))
    sys.exit(1)
head = d.get("headRefOid")
checks = [{"name": c.get("name") or c.get("context","?"),
           "state": c.get("conclusion") or c.get("state","?")}
          for c in (d.get("statusCheckRollup") or [])]
mergeable = d.get("mergeable") == "MERGEABLE"
# Same semantics as the merge gate: the LATEST review state per
# reviewer, bound to the current head - a stale APPROVED on an old
# sha must not report as approved.
latest = {}
for r in (d.get("reviews") or []):
    # verdict events only (see repo_merge.sh): COMMENTED must not
    # erase a standing APPROVE/CHANGES_REQUESTED verdict
    if r.get("state") not in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
        continue
    author = (r.get("author") or {}).get("login", "?")
    cur = latest.get(author)
    if cur is None or (r.get("submittedAt") or "") > (cur.get("submittedAt") or ""):
        latest[author] = r
approved_on_head, blocking = [], []
for login, r in latest.items():
    st = r.get("state")
    rc = (r.get("commit") or {}).get("oid")
    # APPROVED counts only when bound to the CURRENT head sha. An
    # APPROVED without a commit oid is unverifiable, not approved -
    # fail closed instead of treating "binding unknown" as current.
    if st == "APPROVED" and rc == head:
        approved_on_head.append(login)
    elif st == "CHANGES_REQUESTED" or (st == "APPROVED" and rc != head):
        blocking.append("%s:%s" % (login, st))
approved = bool(approved_on_head) and not blocking
print(json.dumps({"checks": checks, "mergeable": mergeable,
                  "approved": approved, "approved_by": approved_on_head,
                  "blocking_reviews": blocking,
                  "actual_head": head, "status": "ok"}))
'
