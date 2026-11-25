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

# Network discipline (review_16 #13): no forge/git call may hang a
# gate slot forever - prompt-hangs die instantly via the env flags,
# transport stalls die via `timeout` where the binary exists.
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30
NET_TO=$(command -v timeout || command -v gtimeout || true)
GH_BIN="$("$CANON_DIR/bin/gh_id.sh" merge)"

GH_OUT=$(${NET_TO:+$NET_TO 120} "$GH_BIN" pr view "$PR" --json statusCheckRollup,mergeable,headRefOid,author,reviewRequests 2>/dev/null) || {
  echo '{"status":"error","failure_class":"upstream_error","message":"gh pr view failed"}'
  exit 1
}
# Reviews come from the paginated REST endpoint, same as
# issue_merge.sh - `gh pr view --json reviews` truncates at the
# first 100 GraphQL nodes, so a fresh APPROVE past the cut would be
# invisible. Numeric id ordering resolves submittedAt
# second-resolution ties deterministically.
REVIEWS_JSONL=$(mktemp "${TMPDIR:-/tmp}/ccsdd-reviews.XXXXXX")
PR_FILES=$(mktemp "${TMPDIR:-/tmp}/ccsdd-prfiles.XXXXXX")
trap 'rm -f "$REVIEWS_JSONL" "$PR_FILES"' EXIT
${NET_TO:+$NET_TO 120} "$GH_BIN" api "repos/{owner}/{repo}/pulls/${PR}/reviews?per_page=100" \
  --paginate --jq '.[] | @json' > "$REVIEWS_JSONL" 2>/dev/null || {
  echo '{"status":"error","failure_class":"upstream_error","message":"reviews fetch failed"}'
  exit 1
}
# The file list paginates too: `--json files` is a GraphQL array and
# truncates at 100 nodes, so a .changes/ fragment landing as file
# 101 of a large PR would report risk_high:false on a risk:high
# delta. REST /pulls/<n>/files paginates fully.
${NET_TO:+$NET_TO 120} "$GH_BIN" api "repos/{owner}/{repo}/pulls/${PR}/files?per_page=100" \
  --paginate --jq '.[].filename' > "$PR_FILES" 2>/dev/null || {
  echo '{"status":"error","failure_class":"upstream_error","message":"PR files fetch failed"}'
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
RISK_HIGH=$(GH_OUT="$GH_OUT" GH_BIN="$GH_BIN" PR_FILES="$PR_FILES" \
  CANON_DIR="$CANON_DIR" python3 -I -c '
import json, os, re, subprocess, base64
try:
    d = json.loads(os.environ["GH_OUT"])
except Exception:
    print("no"); raise SystemExit(0)
head = d.get("headRefOid") or ""
frags = [l.strip() for l in open(os.environ["PR_FILES"], encoding="utf-8")
         if l.strip().startswith(".changes/")
         and l.strip().endswith(".md")
         and not l.strip().endswith("/README.md")]
risk = False
for p in frags:
    # Local object first: the PR head is usually fetched already, and
    # 'git show' answers for files the API cannot (e.g. a fragment
    # DELETED by a release PR - contents/<p> would 404). The API call
    # stays only as fallback for an unfetched head.
    body = ""
    loc = subprocess.run(["git", "show", head + ":" + p],
                         capture_output=True, text=True)
    if loc.returncode == 0:
        body = loc.stdout
    else:
        try:
            out = subprocess.run(
                [os.environ["GH_BIN"], "api",
                 "repos/{owner}/{repo}/contents/" + p + "?ref=" + head,
                 "--jq", ".content"],
                capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            continue
        if out.returncode != 0:
            continue
        try:
            body = base64.b64decode(out.stdout.strip()).decode("utf-8", "replace")
        except Exception:
            continue
    # The canonical .changes front-zone parser - the inline copy used
    # to end the scan at the first '#' comment inside the fence,
    # silently dropping a later 'risk: high' (review_16 #8).
    import sys as _s
    _s.path.insert(0, os.path.join(os.environ.get("CANON_DIR") or "", "bin"))
    from changes_parser import front_fields as _ff
    if (_ff(body).get("risk") or "").lower() == "high":
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
