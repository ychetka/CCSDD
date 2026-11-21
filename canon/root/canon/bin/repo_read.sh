#!/usr/bin/env bash
# repo_read.sh - read repository metadata for other agents.
# Usage: repo_read.sh <pr|issue|checks|reviews|diff|releases|tags> <ref>
# Output: raw gh json/text under {data, status} envelope.
set -uo pipefail
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

WHAT="${1:?usage: repo_read.sh <pr|issue|checks|reviews|diff|releases|tags> <ref>}"
REF="${2:-}"

case "$WHAT" in
  pr|issue|checks|reviews|diff)
    [ -n "$REF" ] || { echo "ref required for $WHAT" >&2; exit 2; }
    # numeric PR/issue refs only - a raw string would reach gh unquoted
    [[ "$REF" =~ ^[0-9]+$ ]] || { echo "ref must be a numeric PR/issue id" >&2; exit 2; } ;;
esac

run() {
  # Envelope: {status:ok, data:<json or text>} on success,
  # {status:error, failure_class:upstream_error, message} on failure -
  # callers parse one shape regardless of the gh subcommand.
  local out rc
  out=$("$@" 2>&1) && rc=0 || rc=$?
  OUT="$out" RC="$rc" python3 -c 'import json,os
out, rc = os.environ["OUT"], int(os.environ["RC"])
if rc != 0:
    print(json.dumps({"status":"error","failure_class":"upstream_error","message":out}))
else:
    try: data = json.loads(out)
    except Exception: data = out
    print(json.dumps({"status":"ok","data":data}))'
  return $rc
}

case "$WHAT" in
  pr)      run gh pr view "$REF" --json number,title,body,state,headRefName,baseRefName,headRefOid,mergeable,mergeCommit,reviews,comments ;;
  issue)   run gh issue view "$REF" --json number,title,body,state,labels,comments ;;
  checks)  run gh pr view "$REF" --json statusCheckRollup ;;
  reviews) run gh pr view "$REF" --json reviews,latestReviews,reviewRequests ;;
  diff)    run gh pr diff "$REF" ;;
  # release/tag reads take no ref: `latest` narrows releases to the
  # newest one, anything else lists all
  releases)
    if [ "$REF" = "latest" ]; then
      run gh release list --limit 1
    else
      run gh release list
    fi ;;
  tags)
    run git tag --list 'v*' --sort=-v:refname ;;
  *)       echo "unknown what: $WHAT" >&2; exit 2 ;;
esac
