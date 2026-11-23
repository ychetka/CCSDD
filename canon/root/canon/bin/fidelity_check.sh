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

# An impl spec only counts when it lives in the tracked artifact
# location docs/impl_specs/<item>.md - an "## Impl spec" heading
# smuggled into a contract/code comment must never satisfy the gate.
IMPL_SPEC_RE = re.compile(r"^docs/impl_specs/[^/]+\.md$")

def strip_markers(line):
    line = line.strip()
    while line and not line.startswith("##") and \
            re.match(r'^(#|//|\*|/\*|\*/|""")', line):
        line = re.sub(r'^("""|/\*|\*/|//|#|\*)', "", line).strip()
    return line

def norm(name):
    # Unified axis normalization with design_spec_check.sh:
    # lowercase, [a-z0-9_-] only - whitespace/case/punctuation can
    # never make one axis pass one gate and fail the other.
    return re.sub(r"[^a-z0-9_-]", "", name.lower())

def stem_of(rel):
    return os.path.splitext(os.path.basename(rel))[0]

# Axes bind to their declaring contract file: ALL axes of one file
# must be decided inside ONE docs/impl_specs/<stem>.md whose stem
# names an item of this PR (a .changes fragment slug or the
# declaring file's own stem). A spec block smuggled into a code
# comment never counts, and axes can no longer be covered piecemeal
# across unrelated impl specs. Residual: two contracts in one PR
# declaring literally same-named axes still share the namespace -
# the full fix is <item_slug>.<axis> prefixes (documented in
# review_5 #2).
# declared keyed by FILE: two contracts declaring a same-named axis
# must not overwrite each other - each file's axes are checked
# against its own bound spec independently.
declared = {}   # rel -> set(norm(axis))
frag_stems = {stem_of(f) for f in files
              if f.startswith(".changes/") and f.endswith(".md")}
decided = {}    # spec_rel -> set(norm(axis))
# Explicit binding: a spec may name the contract it resolves via
# '- contract: <repo_rel_path>' inside '## Impl spec'. In multi-item
# / epic PRs every contract file is literally named contract.py|ts
# (stem 'contract'), so stem-based binding lets module_A's axes be
# "covered" by module_B's spec. When a spec declares contract paths
# only those bind it; a spec with no declarations keeps the legacy
# stem rule for backward compatibility.
spec_contracts = {}  # spec_rel -> set(rel_path) or empty set
for rel in files:
    p = os.path.join(top, rel)
    try:
        body = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    is_spec = bool(IMPL_SPEC_RE.match(rel))
    stem = stem_of(rel)
    in_axes = in_spec = False
    cur_axis = None
    for raw in body.splitlines():
        line = strip_markers(raw)
        if re.match(r"^##\s+Delegated decisions", line):
            in_axes = True; in_spec = False; continue
        if is_spec and re.match(r"^##\s+Impl spec", line):
            in_spec = True; in_axes = False; continue
        if re.match(r"^##\s", line):
            in_axes = False; in_spec = False; cur_axis = None
            continue
        if in_axes:
            m = re.match(r"^-\s+axis:\s*([^|]+)", line)
            if m:
                name = norm(m.group(1))
                if name: declared.setdefault(rel, set()).add(name)
        if in_spec:
            mc = re.match(r"^-\s+contract:\s*(\S+)", line)
            if mc:
                spec_contracts.setdefault(rel, set()).add(mc.group(1).strip())
                continue
            m = re.match(r"^###\s+axis:\s*([^|]+)", line)
            if m:
                cur_axis = norm(m.group(1)); continue
            if cur_axis and re.match(r"^-\s+decision:\s*\S", line):
                decided.setdefault(rel, set()).add(cur_axis)

if not declared:
    print("AXES: none")
    print("GATE_NOTE: axes=none")
    print("PASS: no delegated axes - fidelity reviewer may auto-pass")
    raise SystemExit(0)
all_declared = {a for s in declared.values() for a in s}
def spec_binds(spec_rel):
    bound = spec_contracts.get(spec_rel)
    if bound:
        return bound                      # explicit contract: paths
    return None                           # legacy stem rule applies

missing = []
for rel, axes_of_file in declared.items():
    candidates = frag_stems | {stem_of(rel)}
    covered = False
    for spec_rel, spec_axes in decided.items():
        bound = spec_binds(spec_rel)
        if bound is not None:
            if rel not in bound:
                continue
        elif stem_of(spec_rel) not in candidates:
            continue
        if axes_of_file <= spec_axes:
            covered = True
            break
    if not covered:
        missing.extend(sorted(axes_of_file))
missing = sorted(set(missing))
# Improvisation check (same direction as design_spec_check's EXTRA):
# an impl spec may not decide axes no contract in this PR delegated.
extra = sorted({a for spec_axes in decided.values() for a in spec_axes}
               - all_declared)
print("AXES: " + ",".join(sorted(all_declared)))
print("GATE_NOTE: axes=present")
if missing:
    print("FAIL: delegated axes without a decided impl-spec entry "
          "(expected under docs/impl_specs/<item>.md): "
          + ", ".join(missing))
    raise SystemExit(1)
if extra:
    print("FAIL: impl spec decides axes the contracts never delegated "
          "(improvisation): " + ", ".join(extra))
    raise SystemExit(1)
print(f"PASS: {len(all_declared)} delegated axis/axes covered by impl spec")
PY
