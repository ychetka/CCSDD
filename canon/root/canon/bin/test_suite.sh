#!/usr/bin/env bash
# test_suite.sh - mechanical floor for the `tester` domain: executes
# the project's declared test command and reports pass/fail. The LLM
# tester judges COVERAGE; this floor only answers "do the tests run
# green on the candidate".
#
# Command source: project.json `gate_checks.test` argv. When absent,
# the floor reports SKIP (visible in the gate_runs journal) - it does
# NOT silently invent a pass.
#
# WARNING: executes PR code - run only in credential-free contexts
# (director/merge runner, writer/judge worktrees). Never inside
# reviewer or repository agents.
# CANON_DIR env honored.
set -uo pipefail
CANON_DIR="${CANON_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)}"
PJ="$CANON_DIR/project.json"

TARGV=$(PJ="$PJ" python3 -c 'import json,os
try:
    v = (json.load(open(os.environ["PJ"])).get("gate_checks") or {}).get("test")
    print("\t".join(v) if isinstance(v, list) else "")
except Exception: print("")' 2>/dev/null)

if [ -z "$TARGV" ]; then
  echo "SKIP: no test command configured (project.json gate_checks.test)"
  exit 0
fi
IFS=$'\t' read -r -a TV <<< "$TARGV"
if "${TV[@]}"; then
  echo "TEST_SUITE: PASS"
  exit 0
fi
echo "TEST_SUITE: FAIL ($TARGV)"
exit 1
