#!/usr/bin/env bash
# repo_pr_review.sh - submit a PR review through the hygiene gate.
# Usage:
#   repo_pr_review.sh --pr <N> --event approve|request-changes|comment [--body "..."]
#   repo_pr_review.sh --pr <N> --json-file review.json
#       review.json: GitHub reviews API payload {commit_id, body,
#       event, comments[]}; every body text is hygiene-checked before
#       publication - this is the ONLY path for reviewer-authored
#       reviews with inline comments.
# GH_BIN may only be the literal value `gh` or a basename declared in
# project.json review.gh_bin (the reviewer identity binary the project
# configures, e.g. an alternate-account gh wrapper). A path containing
# '/' or an undeclared value would execute an arbitrary binary under
# the reviewer GitHub credentials.
# Output JSON: {pr_number, event, status}
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP"
GH_BIN="${GH_BIN:-gh}"
ALLOWED_GH=$(CANON_DIR="$CANON_DIR" python3 -c 'import json,os,re
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
    alt = ((pj.get("review") or {}).get("gh_bin")) or ""
    alt = alt if re.fullmatch(r"[A-Za-z0-9_-]+", alt) else ""
    print("gh " + alt)
except Exception:
    print("gh")' 2>/dev/null)
case "$GH_BIN" in
  */*|*\\*) echo '{"status":"error","failure_class":"malformed_input","message":"GH_BIN must be a bare basename, not a path"}'; exit 2 ;;
esac
GH_OK=0
for a in $ALLOWED_GH; do [ "$GH_BIN" = "$a" ] && GH_OK=1; done
[ "$GH_OK" = "1" ] || { echo '{"status":"error","failure_class":"malformed_input","message":"GH_BIN not in allowlist (gh + project review.gh_bin)"}'; exit 2; }

usage() { echo "usage: repo_pr_review.sh --pr <N> --event approve|request-changes|comment [--body text] | --pr <N> --json-file review.json" >&2; exit 2; }

PR=""; EVENT=""; BODY=""; JFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr|--event|--body|--json-file)
      [ $# -ge 2 ] || usage ;;
  esac
  case "$1" in
    --pr) PR=$2 ;;
    --event) EVENT=$2 ;;
    --body) BODY=$2 ;;
    --json-file) JFILE=$2 ;;
    *) usage ;;
  esac; shift 2
done
[ -n "$PR" ] || {
  echo '{"status":"error","failure_class":"malformed_input","message":"--pr required"}'; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo '{"status":"error","failure_class":"malformed_input","message":"--pr must be numeric"}'; exit 2; }

if [ -n "$JFILE" ]; then
  [ -f "$JFILE" ] || { echo '{"status":"error","failure_class":"not_found","message":"--json-file missing"}'; exit 2; }
  JFILE=$(realpath -m "$JFILE")
  SANIT=$(mktemp "${TMPDIR:-/tmp}/review-payload.XXXXXX.json")
  trap 'rm -f "$SANIT"' EXIT INT TERM
  # Resolve the CURRENT head before validation: the submitted review
  # is always pinned to it (caller commit_id must match; an absent
  # one is filled in) - a review bound to a stale/arbitrary commit
  # does not count at the merge gate.
  HEAD_SHA=$("$GH_BIN" pr view "$PR" --json headRefOid --jq .headRefOid 2>/dev/null)
  [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || {
    echo '{"status":"error","failure_class":"upstream_error","message":"cannot resolve PR head sha"}'; exit 1; }
  # Read the payload once into memory (no TOCTOU between validation
  # and submission): validate its shape, hygiene-gate every text
  # field, and write a sanitized copy that is what actually gets
  # submitted - the caller's file is never re-read by gh.
  JFILE="$JFILE" SANIT="$SANIT" CANON_DIR="$CANON_DIR" HEAD_SHA="$HEAD_SHA" python3 - <<'PY' || {
import json, os, subprocess, sys, tempfile
jfile = os.environ["JFILE"]
try:
    raw = open(jfile, "rb").read()
except OSError as e:
    print(json.dumps({"status":"error","failure_class":"not_found","message":str(e)}))
    sys.exit(2)
try:
    payload = json.loads(raw)
except Exception as e:
    print(json.dumps({"status":"error","failure_class":"malformed_input",
                      "message":f"review.json is not valid JSON: {e}"}))
    sys.exit(2)
if not isinstance(payload, dict):
    print(json.dumps({"status":"error","failure_class":"malformed_input",
                      "message":"review.json must be a JSON object"}))
    sys.exit(2)
if payload.get("event") not in ("APPROVE","REQUEST_CHANGES","COMMENT",
                                "approve","request-changes","comment"):
    print(json.dumps({"status":"error","failure_class":"malformed_input",
                      "message":"review.json event must be APPROVE|REQUEST_CHANGES|COMMENT"}))
    sys.exit(2)
comments = payload.get("comments") or []
if not isinstance(comments, list):
    print(json.dumps({"status":"error","failure_class":"malformed_input",
                      "message":"comments must be a list"}))
    sys.exit(2)
for c in comments:
    if not isinstance(c, dict) or not c.get("path") or not c.get("body"):
        print(json.dumps({"status":"error","failure_class":"malformed_input",
                          "message":"each comment needs {path, body, line|position}"}))
        sys.exit(2)
    if not isinstance(c.get("body"), str):
        print(json.dumps({"status":"error","failure_class":"malformed_input",
                          "message":"comment.body must be a string"}))
        sys.exit(2)
    # GitHub rejects inline comments without a diff anchor: 'line'
    # (diff line) or 'position' are mandatory and must be ints.
    ln, pos = c.get("line"), c.get("position")
    if not (type(ln) is int and ln >= 1) and not (type(pos) is int and pos >= 1):
        print(json.dumps({"status":"error","failure_class":"malformed_input",
                          "message":"comment needs an int 'line' or 'position' (diff anchor)"}))
        sys.exit(2)
texts = [payload.get("body") or ""]
texts += [c.get("body") or "" for c in comments]
bad = []
for t in texts:
    if not t:
        continue
    r = subprocess.run(
        [os.path.join(os.environ["CANON_DIR"], "bin", "hygiene_check.sh")],
        input=t, capture_output=True, text=True)
    if r.returncode != 0:
        bad.append(t[:80])
if bad:
    print(json.dumps({"status": "error", "failure_class": "gate_blocked",
                      "violations": bad}))
    sys.exit(2)
# Submit exactly what was validated: keep only known payload fields.
# GitHub expects uppercase event names - the lowercase aliases are
# accepted for ergonomics but must be normalized before submission.
# A caller-supplied commit_id must be a 40-hex sha AND equal the PR
# head sha fetched above (HEAD_SHA): a review bound to a stale or
# arbitrary commit misstates what was approved. Omitting commit_id
# is fine - the submission below pins HEAD_SHA regardless.
if "commit_id" in payload:
    cid = payload["commit_id"]
    if not (isinstance(cid, str) and __import__("re").fullmatch(r"[0-9a-fA-F]{40}", cid)):
        print(json.dumps({"status":"error","failure_class":"malformed_input",
                          "message":"commit_id must be a 40-hex sha"}))
        sys.exit(2)
    if cid.lower() != os.environ["HEAD_SHA"].lower():
        print(json.dumps({"status":"error","failure_class":"stale_input",
                          "message":"commit_id must equal the current PR head sha"}))
        sys.exit(2)
EVENT_MAP = {"approve": "APPROVE", "request-changes": "REQUEST_CHANGES",
             "comment": "COMMENT"}
clean = {k: payload[k] for k in ("commit_id", "body", "event", "comments")
         if k in payload}
clean["event"] = EVENT_MAP.get(clean["event"], clean["event"])
# Severity invariant (harness.md): an APPROVE carrying blocking
# findings is invalid - [CRITICAL]/[WARNING] anywhere in the body
# or inline comments forces REQUEST_CHANGES/COMMENT instead.
if clean["event"] == "APPROVE" and any(
        "[CRITICAL]" in t or "[WARNING]" in t for t in texts):
    print(json.dumps({"status":"error","failure_class":"malformed_input",
                      "message":"APPROVE with [CRITICAL]/[WARNING] findings is invalid - submit REQUEST_CHANGES or COMMENT"}))
    sys.exit(2)
# The review is bound to the resolved head unconditionally - absent
# commit_id is filled, a matching one is kept.
clean["commit_id"] = os.environ["HEAD_SHA"]
with open(os.environ["SANIT"], "w", encoding="utf-8") as f:
    f.write(json.dumps(clean))
print("hygiene-ok")
PY
    echo '{"status":"error","failure_class":"gate_blocked","message":"review.json invalid or failed hygiene"}'; exit 2; }
  ERR=$("$GH_BIN" api -X POST "repos/{owner}/{repo}/pulls/$PR/reviews" --input "$SANIT" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    python3 -c 'import json,sys;print(json.dumps({"pr_number":int(sys.argv[1]),"event":"review","status":"ok"}))' "$PR"
    exit 0
  fi
  python3 -c 'import json,sys;print(json.dumps({"status":"error","failure_class":"upstream_error","message":sys.argv[1]}))' "$ERR"
  exit 1
fi

[ -n "$EVENT" ] || {
  echo '{"status":"error","failure_class":"malformed_input","message":"--event required"}'; exit 2; }
case "$EVENT" in
  approve|request-changes|comment) ;;
  *) echo '{"status":"error","failure_class":"malformed_input","message":"--event must be approve|request-changes|comment"}'; exit 2 ;;
esac
# request-changes without a body is an anonymous objection - the
# reviewer must always state what blocks the merge.
if { [ "$EVENT" = "comment" ] || [ "$EVENT" = "request-changes" ]; } && [ -z "$BODY" ]; then
  echo '{"status":"error","failure_class":"malformed_input","message":"--body required for comment/request-changes events"}'; exit 2
fi

if [ -n "$BODY" ]; then
  HYGIENE_OUT=$(printf '%s\n' "$BODY" | "$CANON_DIR/bin/hygiene_check.sh")
  if [ $? -ne 0 ]; then
    HYGIENE_OUT="$HYGIENE_OUT" python3 -c 'import json,os
try: v=json.loads(os.environ["HYGIENE_OUT"])
except Exception: v={"raw": os.environ["HYGIENE_OUT"]}
print(json.dumps({"status":"error","failure_class":"gate_blocked","violations":v.get("violations",v)}))'
    exit 2
  fi
fi

# Bind the verdict to the CURRENT head: `gh pr review` has no
# --commit flag, so the review would land on whatever head exists at
# submit time - a force-push between gate and review would attach the
# verdict to the wrong tree. Resolve headRefOid, then submit via the
# REST API with an explicit commit_id.
case "$EVENT" in
  approve) GHEVENT=APPROVE ;;
  request-changes) GHEVENT=REQUEST_CHANGES ;;
  comment) GHEVENT=COMMENT ;;
esac
HEAD_SHA=$("$GH_BIN" pr view "$PR" --json headRefOid --jq .headRefOid 2>/dev/null)
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || {
  echo '{"status":"error","failure_class":"upstream_error","message":"cannot resolve PR head sha"}'; exit 1; }
PAYLOAD=$(EVENT="$GHEVENT" BODY="$BODY" HEAD_SHA="$HEAD_SHA" python3 -c 'import json,os
p = {"event": os.environ["EVENT"], "commit_id": os.environ["HEAD_SHA"]}
if os.environ.get("BODY"): p["body"] = os.environ["BODY"]
print(json.dumps(p))')
ERR=$(printf '%s' "$PAYLOAD" | "$GH_BIN" api -X POST "repos/{owner}/{repo}/pulls/$PR/reviews" --input - 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
  python3 -c 'import json,sys;print(json.dumps({"pr_number":int(sys.argv[1]),"event":sys.argv[2],"status":"ok"}))' "$PR" "$EVENT"
else
  python3 -c 'import json,sys;print(json.dumps({"status":"error","failure_class":"upstream_error","message":sys.argv[1]}))' "$ERR"
  exit 1
fi
