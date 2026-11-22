#!/usr/bin/env bash
# fidelity_check.sh - mechanical floor for the `fidelity` domain:
# detects whether the PR delta declares delegated design axes and, if
# it does, whether an impl spec covering them is present in the delta
# or the cycle journal.
#
# Output contract consumed by the panel:
#   "AXES: <comma-list>" / "AXES: none"  - detected declarations
#   exit 0 always when declarations are either absent or covered;
#   exit 1 when axes are declared but no impl spec covers them.
#
# Sources scanned (worktree + diff vs BASE):
#   - roadmap item sections: '## Delegated decisions' + '- axis: <n>'
#   - contract files referenced in the delta
#   - impl spec blocks: '## Impl spec' + '### axis: <n>' + '- decision:'
# Base: BASE env or origin/<base_branch>. CANON_DIR env honored.
set -uo pipefail
CANON_DIR="${CANON_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)}"
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP"
PJ="$CANON_DIR/project.json"

BASE="${BASE:-}"
if [ -z "$BASE" ]; then
  BB=$(PJ="$PJ" python3 -c 'import json,os
try: print(json.load(open(os.environ["PJ"])).get("base_branch") or "main")
except Exception: print("main")' 2>/dev/null)
  for r in "origin/$BB" "$BB"; do
    git rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { BASE=$r; break; }
  done
fi

DELTA_FILES=""
if [ -n "$BASE" ]; then
  DELTA_FILES=$(git diff --name-only --diff-filter=ACMR "$BASE"...HEAD 2>/dev/null \
    | grep -E '\.(md|py|ts|txt|yaml|yml|json)$' || true)
fi
# Scan ONLY the PR delta. The global roadmap is deliberately excluded:
# unresolved axes of future, not-yet-started items must never fail
# this PR. The impl spec is a tracked artifact (docs/impl_specs/
# <item>.md per harness) so it appears in the delta when present.
SCAN_FILES=""
for f in $DELTA_FILES; do
  [ -n "$f" ] && [ -f "$TOP/$f" ] && SCAN_FILES="$SCAN_FILES $f"
done

TOP="$TOP" SCAN_FILES="$SCAN_FILES" python3 - <<'PY'
import os, re
top = os.environ["TOP"]
files = os.environ.get("SCAN_FILES","").split()

def strip_markers(line):
    line = line.strip()
    while line and not line.startswith("##") and \
            re.match(r'^(#|//|\*|/\*|\*/|""")', line):
        line = re.sub(r'^("""|/\*|\*/|//|#|\*)', "", line).strip()
    return line

declared = {}   # axis -> file
decided = set() # axes with a non-empty decision
in_axes = False
cur_axis = None
for rel in files:
    p = os.path.join(top, rel)
    try:
        body = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    in_axes = False
    in_spec = False
    cur_axis = None
    for raw in body.splitlines():
        line = strip_markers(raw)
        if re.match(r"^##\s+Delegated decisions", line):
            in_axes = True; continue
        if re.match(r"^##\s+Impl spec", line):
            in_spec = True; in_axes = False; continue
        if re.match(r"^##\s", line):
            in_axes = False; in_spec = False; cur_axis = None
            continue
        if in_axes:
            m = re.match(r"^-\s+axis:\s*([^|]+)", line)
            if m:
                name = m.group(1).strip()
                if name: declared[name] = rel
        if in_spec:
            m = re.match(r"^###\s+axis:\s*([^|]+)", line)
            if m:
                cur_axis = m.group(1).strip(); continue
            if cur_axis and re.match(r"^-\s+decision:\s*\S", line):
                decided.add(cur_axis)

if not declared:
    print("AXES: none")
    print("GATE_NOTE: axes=none")
    print("PASS: no delegated axes - fidelity reviewer may auto-pass")
    raise SystemExit(0)
missing = sorted(set(declared) - decided)
print("AXES: " + ",".join(sorted(declared)))
print("GATE_NOTE: axes=present")
if missing:
    print("FAIL: delegated axes without a decided impl-spec entry: "
          + ", ".join(missing))
    raise SystemExit(1)
print(f"PASS: {len(declared)} delegated axis/axes covered by impl spec")
PY
