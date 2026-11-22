#!/usr/bin/env bash
# security_check.sh - mechanical floor for the `security` domain.
#   1. Secret-pattern scan of the delta's ADDED lines (API keys,
#      tokens, private-key blocks, common credential assignments).
#   2. Forbidden-API pattern list from project.json
#      `security.forbidden_patterns` (regexes, applied to added lines).
#   3. Project-declared SAST: project.json `gate_checks.security`
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
if [ -n "$BASE" ]; then
  DIFF=$(git diff --unified=0 "$BASE"...HEAD 2>/dev/null | grep -E '^\+' | grep -v '^\+\+\+')
else
  DIFF=$(git diff --unified=0 --cached 2>/dev/null | grep -E '^\+' | grep -v '^\+\+\+'; git status --porcelain | awk '$1=="??"{print $2}' | xargs -r cat 2>/dev/null)
fi

# --- 1. secret patterns on added lines ---
SECRET_BAD=$(printf '%s\n' "$DIFF" | python3 - <<'PY'
import re, sys
pats = [
    (r"(?i)(api[_-]?key|secret|token|password|passwd)\s*[:=]\s*['\"][^'\"]{8,}['\"]", "hardcoded credential assignment"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key material"),
    (r"(?i)bearer\s+[a-z0-9._~+/=-]{20,}", "bearer token literal"),
    (r"ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}", "github token literal"),
    (r"sk-[A-Za-z0-9_-]{20,}", "api key literal (sk-*)"),
    (r"AKIA[0-9A-Z]{16}", "aws access key id"),
]
bad = []
for line in sys.stdin:
    for rx, label in pats:
        if re.search(rx, line):
            bad.append(f"{label}: {line.strip()[:120]}")
            break
for b in bad[:30]:
    print(b)
PY
)
if [ -n "$SECRET_BAD" ]; then
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
  FP_BAD=$(printf '%s\n' "$DIFF" | FORB="$FORB" python3 - <<'PY'
import os, re, sys
pats = [p for p in os.environ["FORB"].splitlines() if p.strip()]
bad = []
for line in sys.stdin:
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

# --- 3. project-declared SAST ---
SARGV=$(PJ="$PJ" python3 -c 'import json,os
try:
    v = (json.load(open(os.environ["PJ"])).get("gate_checks") or {}).get("security")
    print("\t".join(v) if isinstance(v, list) else "")
except Exception: print("")' 2>/dev/null)
if [ -n "$SARGV" ]; then
  IFS=$'\t' read -r -a SV <<< "$SARGV"
  if "${SV[@]}"; then echo "PASS: project SAST"
  else echo "FAIL: project SAST ($SARGV)"; fails=$((fails+1)); fi
fi

[ $fails -eq 0 ] && { echo "SECURITY_CHECK: PASS"; exit 0; }
echo "SECURITY_CHECK: $fails FAILURES"; exit 1
