#!/usr/bin/env bash
# quality_check.sh - mechanical floor for the `quality` domain.
#   1. Project-declared linter: project.json `gate_checks.quality`
#      argv - runs first and propagates its exit code.
#   2. Complexity metrics on the delta's changed source files, when
#      a tool is present (best-effort, reports skipped otherwise):
#        radon  (python): cc blocks ranked D+ (cyclomatic >= 15)
#        lizard (multi-lang): functions with CCN >= 15 or length > 100
#      CRAP/cognitive metrics need a configured tool in gate_checks.
# Base: BASE env or origin/<base_branch>. CANON_DIR env honored.
set -uo pipefail
CANON_DIR="${CANON_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)}"
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP"
PJ="$CANON_DIR/project.json"
fails=0

# --- 1. project linter ---
LARGV=$(PJ="$PJ" python3 -c 'import json,os
try:
    v = (json.load(open(os.environ["PJ"])).get("gate_checks") or {}).get("quality")
    print("\t".join(v) if isinstance(v, list) else "")
except Exception: print("")' 2>/dev/null)
if [ -n "$LARGV" ]; then
  IFS=$'\t' read -r -a LV <<< "$LARGV"
  if "${LV[@]}"; then echo "PASS: project lint"
  else echo "FAIL: project lint ($LARGV)"; fails=$((fails+1)); fi
else
  echo "SKIP: no project lint configured (gate_checks.quality)"
fi

# --- 2. complexity metrics on changed source files ---
BASE="${BASE:-}"
if [ -z "$BASE" ]; then
  BB=$(PJ="$PJ" python3 -c 'import json,os
try: print(json.load(open(os.environ["PJ"])).get("base_branch") or "main")
except Exception: print("main")' 2>/dev/null)
  for r in "origin/$BB" "$BB"; do
    git rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { BASE=$r; break; }
  done
fi
CHANGED=""
[ -n "$BASE" ] && CHANGED=$(git diff --name-only --diff-filter=ACMR "$BASE"...HEAD 2>/dev/null \
  | grep -E '\.(py|js|ts|jsx|tsx|go|java|rb|php|cs|c|cc|cpp|rs)$' | grep -v -E '(^|/)(test_|.*_test\.|.*\.test\.|tests?/)' || true)

if [ -z "$CHANGED" ]; then
  echo "SKIP: no changed source files for metrics"
elif command -v radon >/dev/null 2>&1; then
  PYFILES=$(printf '%s\n' "$CHANGED" | grep '\.py$' || true)
  if [ -n "$PYFILES" ]; then
    HOT=$(printf '%s\n' "$PYFILES" | xargs radon cc -s -n C 2>/dev/null | grep -E ' - [DEF]\(' || true)
    if [ -n "$HOT" ]; then
      printf '%s\n' "$HOT" | head -20 | sed 's/^/  complexity: /'
      echo "FAIL: cyclomatic complexity rank D+ in changed files"; fails=$((fails+1))
    else
      echo "PASS: radon cyclomatic complexity (no rank D+ blocks)"
    fi
  else
    echo "SKIP: no changed .py files for radon"
  fi
elif command -v lizard >/dev/null 2>&1; then
  HOT=$(printf '%s\n' "$CHANGED" | xargs lizard -C 15 -L 100 2>/dev/null | grep -E '^\s+[0-9]+' || true)
  if [ -n "$HOT" ]; then
    printf '%s\n' "$HOT" | head -20 | sed 's/^/  complexity: /'
    echo "FAIL: lizard CCN>=15 or length>100 in changed files"; fails=$((fails+1))
  else
    echo "PASS: lizard complexity thresholds"
  fi
else
  echo "SKIP: no metrics tool found (radon/lizard) - complexity floor unconfigured"
fi

[ $fails -eq 0 ] && { echo "QUALITY_CHECK: PASS"; exit 0; }
echo "QUALITY_CHECK: $fails FAILURES"; exit 1
