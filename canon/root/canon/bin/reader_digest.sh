#!/usr/bin/env bash
# reader_digest.sh - mechanical reader attestation. A reader agent's
# self-report is NEVER trusted on its own: this script computes the
# file digest, size, line count, coverage ranges and tail anchor
# independently, and can verify an agent-reported attestation
# against ground truth.
#
# Usage:
#   reader_digest.sh <path>
#       Emit attestation JSON:
#       {path, sha256, total_bytes, total_lines,
#        covered_ranges:[[1,N]], tail_anchor}
#
#   reader_digest.sh --verify <path> --attestation <file|->
#       Verify an agent-reported attestation (same JSON shape) for
#       <path>: sha256/total_bytes/total_lines must match the real
#       file, covered_ranges must cover [1, total_lines] without
#       gaps, tail_anchor must equal the file's actual last
#       non-empty line (or last line if all-empty).
#       Exit 0 = attested, 1 = mismatch, 2 = usage.
set -uo pipefail

usage() { echo "usage: reader_digest.sh <path> | --verify <path> --attestation <file|->" >&2; exit 2; }

MODE=emit; FILE=""; ATTEST=""
if [ "${1:-}" = "--verify" ]; then
  MODE=verify; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --attestation) [ $# -ge 2 ] || usage; ATTEST=$2; shift 2 ;;
      --*) usage ;;
      *) [ -z "$FILE" ] || usage; FILE=$1; shift ;;
    esac
  done
  [ -n "$FILE" ] && [ -n "$ATTEST" ] || usage
else
  [ $# -eq 1 ] || usage
  FILE=$1
fi
[ -f "$FILE" ] || { echo '{"status":"error","failure_class":"not_found","message":"file missing"}'; exit 2; }

if [ "$MODE" = emit ]; then
  FILE="$FILE" python3 - <<'PY'
import hashlib, json, os
p = os.environ["FILE"]
raw = open(p, "rb").read()
lines = raw.decode("utf-8", "replace").splitlines()
tail = ""
for ln in reversed(lines):
    if ln.strip():
        tail = ln; break
if not tail and lines:
    tail = lines[-1]
print(json.dumps({
    "path": p,
    "sha256": hashlib.sha256(raw).hexdigest(),
    "total_bytes": len(raw),
    "total_lines": len(lines),
    "covered_ranges": [[1, len(lines)]] if lines else [],
    "tail_anchor": tail}))
PY
  exit 0
fi

# verify mode
FILE="$FILE" ATTEST="$ATTEST" python3 - <<'PY'
import hashlib, json, os, sys
p = os.environ["FILE"]
src = os.environ["ATTEST"]
raw = open(p, "rb").read()
lines = raw.decode("utf-8", "replace").splitlines()
truth = {
    "sha256": hashlib.sha256(raw).hexdigest(),
    "total_bytes": len(raw),
    "total_lines": len(lines),
}
tail = ""
for ln in reversed(lines):
    if ln.strip():
        tail = ln; break
if not tail and lines:
    tail = lines[-1]
truth["tail_anchor"] = tail

try:
    att = json.loads(sys.stdin.read() if src == "-" else open(src).read())
except Exception as e:
    print(json.dumps({"status":"error","failure_class":"malformed_input",
                      "message":f"attestation not valid JSON: {e}"}))
    sys.exit(1)
if not isinstance(att, dict):
    print(json.dumps({"status":"error","failure_class":"malformed_input",
                      "message":"attestation must be a JSON object"}))
    sys.exit(1)

mismatches = []
for k in ("sha256","total_bytes","total_lines","tail_anchor"):
    if att.get(k) != truth[k]:
        mismatches.append({"field": k, "reported": att.get(k),
                           "actual": truth[k]})
# 'path' binds the attestation to THIS file when present - a stale
# or swapped attestation for a different file must not verify here.
if "path" in att and att["path"] != p:
    mismatches.append({"field": "path", "reported": att["path"],
                       "actual": p})

# coverage: reported ranges must cover [1, total_lines] with no gaps.
# bool is an int subclass in Python - type() checks exclude it.
ranges = att.get("covered_ranges")
if not isinstance(ranges, list):
    mismatches.append({"field":"covered_ranges","reported":ranges,
                       "actual":"must be a list of [start,end]"})
else:
    ok, need = True, 1
    for r in sorted(ranges, key=lambda x: (x or [0])[0] if isinstance(x, list) and x else 0):
        if not (isinstance(r, list) and len(r) == 2
                and all(type(v) is int for v in r)):
            ok = False; break
        s, e = r
        if not (1 <= s <= e <= max(truth["total_lines"], 1)) or s > need:
            ok = False; break
        need = max(need, e + 1)
    if not ok or need <= truth["total_lines"]:
        mismatches.append({"field":"covered_ranges","reported":ranges,
                           "actual":f"incomplete coverage of 1..{truth['total_lines']}"})

if mismatches:
    print(json.dumps({"status":"error","failure_class":"incomplete_read",
                      "path": p, "mismatches": mismatches}))
    sys.exit(1)
print(json.dumps({"status":"attested","path":p,
                  "sha256":truth["sha256"],
                  "total_lines":truth["total_lines"]}))
PY
