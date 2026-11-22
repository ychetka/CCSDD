#!/usr/bin/env bash
# repo_status_check.sh - report checks and mergeability of a PR.
# Usage: repo_status_check.sh <pr_number>
# Output JSON: {checks:[{name,state,required}], mergeable, status}
#
# Review verdicts use the SAME semantics as issue_merge.sh /
# panel_gate.sh: the expected reviewer set comes from project.json
# (review.reviewer_logins UNION review.reviewer_profiles keys), every
# expected login must APPROVE bound to the CURRENT head sha, and a
# pending or stale verdict is reported - never a bare
# "approved: true" from a single stray APPROVED row.
set -uo pipefail
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

PR="${1:?usage: repo_status_check.sh <pr_number>}"

# Merge-context read: the merge identity binary, never the review
# one - status reporting must not borrow reviewer credentials.
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
GH_BIN="$("$CANON_DIR/bin/gh_id.sh" merge)"

GH_OUT=$("$GH_BIN" pr view "$PR" --json statusCheckRollup,mergeable,reviews,headRefOid 2>/dev/null) || {
  echo '{"status":"error","failure_class":"upstream_error","message":"gh pr view failed"}'
  exit 1
}
EXPECTED=$(CANON_DIR="$CANON_DIR" python3 -c 'import json,os
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
    rev = pj.get("review") or {}
    seen = []
    for x in (rev.get("reviewer_logins") or []):
        x = str(x)
        if x not in seen: seen.append(x)
    rp = rev.get("reviewer_profiles") or {}
    if isinstance(rp, dict):
        for x in rp:
            if x not in seen: seen.append(x)
    print("\n".join(seen))
except Exception:
    print("")' 2>/dev/null || true)
GH_OUT="$GH_OUT" EXPECTED="$EXPECTED" python3 -c '
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
expected = [l for l in os.environ.get("EXPECTED","").splitlines() if l.strip()]
# Same semantics as the merge gate: the LATEST verdict-state review
# per reviewer, bound to the current head - a stale APPROVED on an
# old sha must not report as approved.
latest = {}
for r in (d.get("reviews") or []):
    # verdict events only (see issue_merge.sh): COMMENTED must not
    # erase a standing APPROVE/CHANGES_REQUESTED verdict
    if r.get("state") not in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
        continue
    author = (r.get("author") or {}).get("login", "?")
    cur = latest.get(author)
    if cur is None or (r.get("submittedAt") or "") > (cur.get("submittedAt") or ""):
        latest[author] = r
approved_on_head, blocking, pending = [], [], []
subjects = expected or sorted(latest)
for login in subjects:
    r = latest.get(login)
    if r is None:
        if expected:
            pending.append(login)
        continue
    st = r.get("state")
    rc = (r.get("commit") or {}).get("oid")
    # APPROVED counts only when bound to the CURRENT head sha. An
    # APPROVED without a commit oid is unverifiable, not approved -
    # fail closed instead of treating "binding unknown" as current.
    if st == "APPROVED" and rc == head:
        approved_on_head.append(login)
    elif st == "CHANGES_REQUESTED" or (st == "APPROVED" and rc != head):
        blocking.append("%s:%s" % (login, st))
approved = bool(subjects) and not blocking and not pending \
    and len(approved_on_head) == len(subjects)
print(json.dumps({"checks": checks, "mergeable": mergeable,
                  "approved": approved, "approved_by": approved_on_head,
                  "pending_reviewers": pending,
                  "blocking_reviews": blocking,
                  "expected_reviewers": expected,
                  "actual_head": head, "status": "ok"}))
'
