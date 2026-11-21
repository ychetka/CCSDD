#!/usr/bin/env bash
# session_audit.sh <transcript_file> - end-of-session stats.
# Counts mechanical signals from cycle_log + transcript greps.
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
LOG=$CANON_DIR/cycle_log.jsonl
TR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file) [ $# -ge 2 ] || { echo "usage: session_audit.sh [-f] <transcript>" >&2; exit 2; }
               TR=$2; shift 2 ;;
    -*)        echo "usage: session_audit.sh [-f] <transcript>" >&2; exit 2 ;;
    *)         TR=$1; shift ;;
  esac
done
[ -n "$TR" ] || { echo "usage: session_audit.sh [-f] <transcript>" >&2; exit 2; }
[ -f "$TR" ] || { echo "session audit: transcript '$TR' not found" >&2; exit 2; }

echo "== session audit =="
if [ -f "$LOG" ]; then
  echo "agent_calls=$(grep -c . "$LOG")"
  echo "commits=$(grep -c '"action": *"commit"' "$LOG")"
  echo "failures=$(grep -c '"verdict": *"failure"' "$LOG")"
  echo "escalations=$(grep -c '"verdict": *"escalated"' "$LOG")"
  echo "unknown_failure_class=$(grep -c '"failure_class": *"unknown"' "$LOG")"
else
  echo "cycle_log: missing"
fi
echo "direct_git_calls=$(grep -cE 'Exec\(git|(^| )git (status|add|commit|push|checkout|diff|log)' "$TR" || true)"
echo "direct_gh_calls=$(grep -cE 'Exec\(gh|(^| )gh (pr|issue|api|auth)' "$TR" || true)"
echo "confirmations_asked=$(grep -ciE 'confirm|approve\?|may i|permission|allow(ed)? (me|to)|подтверд|можно ли|разреш' "$TR" || true)"
echo "attribution_hits=$(grep -ciE 'Generated with|Co-Authored-By|Devin AI' "$TR" || true)"
V=$(grep -c 'VERIFY: ALL PASS' "$TR" || true)
echo "verify_output=$([ "${V:-0}" -gt 0 ] && echo present || echo absent)"
