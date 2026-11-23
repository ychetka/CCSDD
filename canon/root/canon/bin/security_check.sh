#!/usr/bin/env bash
# security_check.sh - mechanical floor for the `security` domain.
#   1. Secret-pattern scan of the delta's ADDED lines (API keys,
#      tokens, private-key blocks, common credential assignments).
#   2. Forbidden-API pattern list from project.json
#      `security.forbidden_patterns` (regexes, applied to added lines).
#   (project SAST runs as a separate RUNNER=project check.)
#      argv (semgrep/bandit/etc.) - runs last, propagates exit code.
# Base: BASE env or origin/<base_branch>. CANON_DIR env honored.
set -uo pipefail
CANON_DIR="${CANON_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)}"
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP"
PJ="$CANON_DIR/project.json"
fails=0

BASE="${BASE:-}"
if [ -z "$BASE" ]; then
  BB=$(PJ="$PJ" python3 -c 'import json,os
try: print(json.load(open(os.environ["PJ"])).get("base_branch") or "main")
except Exception: print("main")' 2>/dev/null)
  for r in "origin/$BB" "$BB"; do
    git rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { BASE=$r; break; }
  done
fi
# --text: a secret added inside a binary/non-UTF-8 file must still
# reach the scanner (without it git prints "Binary files differ" and
# the secret never appears). --no-ext-diff pins the builtin differ
# against attacker-controlled diff.external config. The stream goes
# to a FILE, never a bash variable: bash drops NUL bytes inside $(),
# mangling the scan input. grep -aE on both sides (BRE '\+' would
# delete every '+' line; without -a grep emits 'binary file matches'
# and nothing else).
DIFF_F=$(mktemp); trap 'rm -f "$DIFF_F"' EXIT
if [ -n "$BASE" ]; then
  git diff --text --no-ext-diff --unified=0 "$BASE"...HEAD 2>/dev/null \
    | grep -aE '^\+' | grep -avE '^\+\+\+' > "$DIFF_F" || true
else
  { git diff --text --no-ext-diff --unified=0 --cached 2>/dev/null \
      | grep -aE '^\+' | grep -avE '^\+\+\+' || true
    # Untracked files are added content too - concat with a newline
    # separator so two files never glue into one line.
    git ls-files -z --others --exclude-standard 2>/dev/null \
      | while IFS= read -r -d '' uf; do cat "$uf" 2>/dev/null; printf '\n'; done
  } > "$DIFF_F"
fi

# --- 1. secret patterns on added lines ---
# Unified scanner (bin/secret_scan.py) - the same pattern set the
# partner gateway enforces on outbound args. A scanner crash must
# fail the check, never silently pass: capture the exit code
# explicitly (empty stdout + ||true would swallow UnicodeDecodeError).
SECRET_BAD=$(python3 "$CANON_DIR/bin/secret_scan.py" < "$DIFF_F")
SCAN_RC=$?
if [ $SCAN_RC -eq 2 ] || [ $SCAN_RC -gt 2 ]; then
  echo "FAIL: secret scanner crashed (rc=$SCAN_RC)"; fails=$((fails+1))
elif [ $SCAN_RC -eq 1 ]; then
  printf '%s\n' "$SECRET_BAD" | sed 's/^/  secret: /'
  echo "FAIL: possible secrets in the delta"; fails=$((fails+1))
else
  echo "PASS: no secret patterns in the delta"
fi

# --- 2. forbidden patterns (project policy) ---
FORB=$(PJ="$PJ" python3 -c 'import json,os
try:
    v = (json.load(open(os.environ["PJ"])).get("security") or {}).get("forbidden_patterns")
    print("\n".join(v) if isinstance(v, list) else "")
except Exception: print("")' 2>/dev/null)
if [ -n "$FORB" ]; then
  FP_BAD=$(FORB="$FORB" DIFF_F="$DIFF_F" python3 - <<'PY'
import os, re
pats = [p for p in os.environ["FORB"].splitlines() if p.strip()]
bad = []
for line in open(os.environ["DIFF_F"], encoding="utf-8", errors="replace"):
    for rx in pats:
        try:
            if re.search(rx, line):
                bad.append(f"forbidden pattern /{rx}/: {line.strip()[:120]}")
                break
        except re.error:
            pass
for b in bad[:30]:
    print(b)
PY
)
  if [ -n "$FP_BAD" ]; then
    printf '%s\n' "$FP_BAD" | sed 's/^/  forbidden: /'
    echo "FAIL: forbidden API/pattern hits"; fails=$((fails+1))
  else
    echo "PASS: no forbidden patterns"
  fi
fi

# --- 3. project SAST lives in RUNNER=project (gate_run),
# never here - canon checks are static-only.

[ $fails -eq 0 ] && { echo "SECURITY_CHECK: PASS"; exit 0; }
echo "SECURITY_CHECK: $fails FAILURES"; exit 1
