#!/usr/bin/env bash
# quality_check.sh - mechanical floor for the `quality` domain.
#   (project lint runs as a separate RUNNER=project check.)
#      argv - runs first and propagates its exit code.
#   2. Complexity metrics on the delta's changed source files, when
#      a tool is present (best-effort, reports skipped otherwise):
#        radon  (python): cc blocks ranked D+ (cyclomatic >= 15)
#        lizard (multi-lang): functions with CCN >= 15 or length > 100
#      CRAP/cognitive metrics need a configured tool in gate_checks.
# Base: BASE env or origin/<base_branch>. CANON_DIR env honored.
set -uo pipefail
CANON_DIR="${CANON_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)}"
# Nested workspaces: probe cwd, ./code, and the sibling of CANON_DIR.
TOP=$(git rev-parse --show-toplevel 2>/dev/null \
      || git -C code rev-parse --show-toplevel 2>/dev/null \
      || git -C "$CANON_DIR/../code" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP"
PJ="$CANON_DIR/project.json"
fails=0

# --- 1. project linter ---
# Project lint is RUNNER=project (gate_run), not here.

# --- 2. complexity metrics on changed source files ---
BASE="${BASE:-}"
if [ -z "$BASE" ]; then
  BB=$(PJ="$PJ" python3 -I -c 'import json,os
try: print(json.load(open(os.environ["PJ"])).get("base_branch") or "main")
except Exception: print("main")' 2>/dev/null)
  # Probe every configured remote, not just 'origin' - a mirror or
  # fork-named remote is as valid a base as the default.
  for r in $(git remote 2>/dev/null | sed "s#\$#/$BB#") "$BB"; do
    git rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { BASE=$r; break; }
  done
fi
# An unresolved base must not degrade the metrics floor to a SKIP:
# 'no changed files' and 'cannot compute the delta' are different
# outcomes, and only the first may pass.
[ -n "$BASE" ] || { echo "FAIL: cannot resolve base ref for quality delta check" >&2; exit 1; }
CHANGED=""
[ -n "$BASE" ] && CHANGED=$(git diff --name-only --diff-filter=ACMR "$BASE"...HEAD 2>/dev/null \
  | grep -E '\.(py|js|ts|jsx|tsx|go|java|rb|php|cs|c|cc|cpp|rs)$' | grep -v -E '(^|/)(test_|.*_test\.|.*\.test\.|tests?/)' || true)

if [ -z "$CHANGED" ]; then
  echo "SKIP: no changed source files for metrics"
else
  # radon covers .py, lizard the rest - INDEPENDENT blocks: a host
  # with both tools must not let 'radon present, no .py changed'
  # shadow the lizard run for a JS/Go-only delta. lizard also covers
  # .py when radon is absent.
  PYFILES=$(printf '%s\n' "$CHANGED" | grep '\.py$' || true)
  NONPY=$(printf '%s\n' "$CHANGED" | grep -v '\.py$' || true)
  LIZFILES="$NONPY"
  command -v radon >/dev/null 2>&1 || LIZFILES="$CHANGED"
  covered=""
  QCDIR=$(mktemp -d "${TMPDIR:-/tmp}/ccsdd-qc.XXXXXX")
  if [ -n "$PYFILES" ] && command -v radon >/dev/null 2>&1; then
    covered=1
    # py_compile first: radon emits 'ERROR: <file>' on unparseable
    # input, which the rank grep would silently read as "no D+ block"
    # -> a syntax-broken file would PASS. Both must fail the gate.
    # No -I{} interpolation: xargs substitutes the filename into the
    # sh -c template as raw text, so a filename with a quote or $()
    # becomes shell code. Positional args keep the name opaque.
    # Isolation: this script may run inside merge context while CWD is
    # the candidate's tree. `python3 -I -m py_compile` imports stdlib
    # modules (tokenize & co) and -m puts CWD on sys.path, so a PR
    # shipping `tokenize.py` would execute PR code under gate creds.
    # -I (isolated) drops CWD/site-packages/PYTHONPATH. radon/lizard
    # likewise run from an empty scratch dir with absolute paths - a
    # PR's setup.cfg/.radon.cfg/flake8 plugins must never load here.
    BADSYNTAX=$(printf '%s\n' "$PYFILES" | tr '\n' '\0' \
      | xargs -0 -n1 sh -c 'python3 -I -m py_compile "$1" 2>/dev/null || printf "%s\n" "$1"' _ || true)
    RADON_OUT=$(cd "$QCDIR" && printf '%s\n' "$PYFILES" | sed "s|^|$TOP/|" \
      | tr '\n' '\0' | xargs -0 radon cc -s -n C 2>/dev/null || true)
    RADON_ERR=$(printf '%s\n' "$RADON_OUT" | grep -E '^ERROR:' || true)
    HOT=$(printf '%s\n' "$RADON_OUT" | grep -E ' - [DEF]\(' || true)
    if [ -n "$BADSYNTAX" ]; then
      printf '%s\n' "$BADSYNTAX" | head -10 | sed 's/^/  syntax: /'
      echo "FAIL: unparseable .py in changed files"; fails=$((fails+1))
    fi
    if [ -n "$RADON_ERR" ]; then
      printf '%s\n' "$RADON_ERR" | head -10 | sed 's/^/  radon: /'
      echo "FAIL: radon could not analyze changed files"; fails=$((fails+1))
    fi
    if [ -n "$HOT" ]; then
      printf '%s\n' "$HOT" | head -20 | sed 's/^/  complexity: /'
      echo "FAIL: cyclomatic complexity rank D+ in changed files"; fails=$((fails+1))
    fi
    if [ -z "$BADSYNTAX" ] && [ -z "$RADON_ERR" ] && [ -z "$HOT" ]; then
      echo "PASS: radon cyclomatic complexity (no rank D+ blocks)"
    fi
  elif [ -n "$PYFILES" ]; then
    echo "SKIP: no changed .py files analyzed (radon absent)"
  fi
  if [ -n "$LIZFILES" ] && command -v lizard >/dev/null 2>&1; then
    covered=1
    # Same isolation as radon: run from an empty dir on absolute paths.
    HOT=$(cd "$QCDIR" && printf '%s\n' "$LIZFILES" | sed "s|^|$TOP/|" \
      | tr '\n' '\0' | xargs -0 lizard -C 15 -L 100 2>/dev/null | grep -E '^\s+[0-9]+' || true)
    if [ -n "$HOT" ]; then
      printf '%s\n' "$HOT" | head -20 | sed 's/^/  complexity: /'
      echo "FAIL: lizard CCN>=15 or length>100 in changed files"; fails=$((fails+1))
    else
      echo "PASS: lizard complexity thresholds"
    fi
  elif [ -n "$LIZFILES" ]; then
    echo "SKIP: non-python complexity unchecked (lizard absent)"
  fi
  rm -rf "$QCDIR"
  if [ -z "$covered" ]; then
    # No metrics tool: a bare SKIP reads as a pass. On a repo that HAS
    # changed source files, require the project to declare the floor
    # optional explicitly - silence is not consent.
    OPT=$(PJ="$PJ" python3 -I -c 'import json,os
try: print("yes" if (json.load(open(os.environ["PJ"])).get("gate_checks") or {}).get("complexity_optional") is True else "no")
except Exception: print("no")' 2>/dev/null)
    if [ "$OPT" != "yes" ]; then
      echo "FAIL: no complexity tool (radon/lizard) and gate_checks.complexity_optional not declared - the floor is unconfigured, not passed"
      fails=$((fails+1))
    else
      echo "SKIP: no metrics tool found (radon/lizard) - complexity floor unconfigured"
    fi
  fi
fi

[ $fails -eq 0 ] && { echo "QUALITY_CHECK: PASS"; exit 0; }
echo "QUALITY_CHECK: $fails FAILURES"; exit 1
