#!/usr/bin/env bash
# repo_status_check.sh - report checks and mergeability of a PR.
# Usage: repo_status_check.sh <pr_number>
# Output JSON: {checks:[{name,state,required}], mergeable, status}
#
# Review verdicts use the SAME semantics as issue_merge.sh /
# panel_gate.sh: the expected reviewer set comes from project.json
# (review.reviewer_logins UNION reviewer_profiles keys MINUS
# high_risk_only profiles - an ordinary PR never waits on the
# second-family gate), every expected login must APPROVE bound to
# the CURRENT head sha, the PR author's own reviews never count,
# a login in reviewRequests has no standing verdict, and a pending
# or stale verdict is reported - never a bare "approved: true"
# from a single stray APPROVED row.
set -uo pipefail
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

PR="${1:?usage: repo_status_check.sh <pr_number>}"

# Merge-context read: the merge identity binary, never the review
# one - status reporting must not borrow reviewer credentials.
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
GH_BIN="$("$CANON_DIR/bin/gh_id.sh" merge)"

GH_OUT=$("$GH_BIN" pr view "$PR" --json statusCheckRollup,mergeable,headRefOid,author,reviewRequests,files 2>/dev/null) || {
  echo '{"status":"error","failure_class":"upstream_error","message":"gh pr view failed"}'
  exit 1
}
# Reviews come from the paginated REST endpoint, same as
# issue_merge.sh - `gh pr view --json reviews` truncates at the
# first 100 GraphQL nodes, so a fresh APPROVE past the cut would be
# invisible. Numeric id ordering resolves submittedAt
# second-resolution ties deterministically.
REVIEWS_JSONL=$(mktemp "${TMPDIR:-/tmp}/ccsdd-reviews.XXXXXX")
trap 'rm -f "$REVIEWS_JSONL"' EXIT
"$GH_BIN" api "repos/{owner}/{repo}/pulls/${PR}/reviews?per_page=100" \
  --paginate --jq '.[] | @json' > "$REVIEWS_JSONL" 2>/dev/null || {
  echo '{"status":"error","failure_class":"upstream_error","message":"reviews fetch failed"}'
  exit 1
}
CFG=$(CANON_DIR="$CANON_DIR" python3 -I -c 'import json,os
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
    rev = pj.get("review") or {}
    seen, high, fam = [], [], []
    for x in (rev.get("reviewer_logins") or []):
        x = str(x).strip().lower()
        if x and x not in seen: seen.append(x)
    rp = rev.get("reviewer_profiles") or {}
    if isinstance(rp, dict):
        for x, prof in rp.items():
            lx = str(x).strip().lower()
            if isinstance(prof, dict) and prof.get("high_risk_only") is True:
                if lx and lx not in high: high.append(lx)
            elif lx and lx not in seen:
                seen.append(lx)
            if isinstance(prof, dict):
                fam.append("%s\t%s" % (lx, prof.get("model_family") or "default"))
    print(json.dumps({"expected": seen, "high_risk": high, "family_map": dict(f.split("\t",1) for f in fam)}))
except Exception:
    print(json.dumps({"expected": [], "high_risk": [], "family_map": {}}))' 2>/dev/null || true)

# risk:high flag from the PR's .changes fragments - front-zone
# key:value only, same parser contract as issue_merge's FRAG_SCAN.
# Fragment bodies come from the PR head via the contents API so the
# report does not depend on the local checkout having the branch.
RISK_HIGH=$(GH_OUT="$GH_OUT" GH_BIN="$GH_BIN" python3 -I -c '
import json, os, re, subprocess, base64
try:
    d = json.loads(os.environ["GH_OUT"])
except Exception:
    print("no"); raise SystemExit(0)
head = d.get("headRefOid") or ""
frags = [f.get("path") for f in (d.get("files") or [])
         if (f.get("path") or "").startswith(".changes/")
         and f.get("path").endswith(".md")
         and not f.get("path").endswith("/README.md")]
risk = False
for p in frags:
    out = subprocess.run(
        [os.environ["GH_BIN"], "api",
         "repos/{owner}/{repo}/contents/" + p + "?ref=" + head,
         "--jq", ".content"],
        capture_output=True, text=True)
    if out.returncode != 0:
        continue
    try:
        body = base64.b64decode(out.stdout.strip()).decode("utf-8", "replace")
    except Exception:
        continue
    lines = body.splitlines()
    start = 1 if lines and lines[0].strip() == "---" else 0
    for ln in lines[start:]:
        s = ln.strip()
        if not s:
            continue
        if s == "---":
            break
        m = re.match(r"^([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*)$", s)
        if not m:
            break
        if m.group(1).lower() == "risk" and \
                m.group(2).strip().strip('"').strip("'") == "high":
            risk = True
print("yes" if risk else "no")' 2>/dev/null || echo no)

GH_OUT="$GH_OUT" CFG="$CFG" RISK_HIGH="$RISK_HIGH" \
REVIEWS_JSONL="$REVIEWS_JSONL" python3 -I -c '
import json, os, sys
try:
    d = json.loads(os.environ["GH_OUT"])
    cfg = json.loads(os.environ.get("CFG") or "{}")
except Exception:
    print(json.dumps({"status":"error","failure_class":"upstream_error",
                      "message":"unparseable gh output"}))
    sys.exit(1)
head = d.get("headRefOid")
pr_author = (((d.get("author") or {}).get("login")) or "").lower()
checks = [{"name": c.get("name") or c.get("context","?"),
           "state": c.get("conclusion") or c.get("state","?")}
          for c in (d.get("statusCheckRollup") or [])]
mergeable = d.get("mergeable") == "MERGEABLE"
expected = set(cfg.get("expected") or [])
high_risk_reviewers = set(cfg.get("high_risk") or [])
family_map = {k.lower(): v for k, v in (cfg.get("family_map") or {}).items()}
risk_high = os.environ.get("RISK_HIGH") == "yes"
# Same semantics as the merge gate: the LATEST verdict-state review
# per reviewer, bound to the current head; reviews by the PR author
# never count; a login in reviewRequests holds no standing verdict.
latest = {}
self_reviews = []
reviews = []
for ln in open(os.environ["REVIEWS_JSONL"], encoding="utf-8",
               errors="replace"):
    ln = ln.strip()
    if not ln:
        continue
    try:
        reviews.append(json.loads(ln))
    except Exception:
        continue
reviews.sort(key=lambda r: r.get("id") or 0)
for r in reviews:
    if r.get("state") not in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
        continue
    author = ((r.get("user") or {}).get("login") or "").lower()
    if author == pr_author:
        if r.get("state") in ("APPROVED", "CHANGES_REQUESTED"):
            self_reviews.append(author)
        continue
    # id-ordered: the last verdict-state review per reviewer wins
    latest[author] = r
pending_reviewers = {((r.get("login") or "")).lower()
                     for r in (d.get("reviewRequests") or [])
                     if isinstance(r, dict)}
approved_on_head, blocking = [], []
for login, r in latest.items():
    st = r.get("state")
    rc = r.get("commit_id")
    if login not in expected | high_risk_reviewers:
        if st == "CHANGES_REQUESTED":
            blocking.append("%s:CHANGES_REQUESTED" % login)
        continue
    if st == "APPROVED" and rc == head and login not in pending_reviewers:
        approved_on_head.append(login)
    elif st == "CHANGES_REQUESTED" or (st == "APPROVED" and rc and rc != head):
        blocking.append("%s:%s" % (login, st))
missing = sorted(expected - set(approved_on_head))
# risk:high - the two distinct model families count across ordinary
# AND high_risk_only approvers, exactly like issue_merge.
approved_families = {family_map.get(l, "default") for l in approved_on_head}
family_ok = (not risk_high) or len(approved_families) >= 2
approved = not missing and not blocking and family_ok \
    and (expected or approved_on_head)
out = {"checks": checks, "mergeable": mergeable,
       "approved": approved, "approved_by": approved_on_head,
       "missing_approvals": missing,
       "pending_reviewers": sorted(pending_reviewers & (expected | high_risk_reviewers)),
       "blocking_reviews": blocking,
       "self_reviews_ignored": self_reviews,
       "expected_reviewers": sorted(expected),
       "high_risk_reviewers": sorted(high_risk_reviewers),
       "risk_high": risk_high,
       "approved_model_families": sorted(approved_families),
       "actual_head": head, "status": "ok"}
if risk_high and not family_ok:
    out["family_deficit"] = ("risk: high requires APPROVED reviews "
        "from >=2 distinct model families; got %d" % len(approved_families))
print(json.dumps(out))
'
