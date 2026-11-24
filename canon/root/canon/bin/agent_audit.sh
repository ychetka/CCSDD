#!/usr/bin/env bash
# agent_audit.sh <transcript_file> - end-of-instance stats.
# Counts mechanical signals from cycle_log + transcript greps.
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
LOG=$CANON_DIR/cycle_log.jsonl
TR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file) [ $# -ge 2 ] || { echo "usage: agent_audit.sh [-f] <transcript>" >&2; exit 2; }
               TR=$2; shift 2 ;;
    -*)        echo "usage: agent_audit.sh [-f] <transcript>" >&2; exit 2 ;;
    *)         TR=$1; shift ;;
  esac
done
[ -n "$TR" ] || { echo "usage: agent_audit.sh [-f] <transcript>" >&2; exit 2; }
[ -f "$TR" ] || { echo "agent audit: transcript '$TR' not found" >&2; exit 2; }

echo "== agent audit =="
if [ -f "$LOG" ]; then
  # Structured JSONL counting - a compact serializer (no space after
  # ':') or an escaped '"action": "commit"' inside another field's
  # string value would fool a plain grep -c.
  LOG="$LOG" python3 -I - <<'PY'
import json, os
n = dict.fromkeys(
    ("agent_calls","commits","failures","escalations",
     "unknown_failure_class"), 0)
for ln in open(os.environ["LOG"], encoding="utf-8", errors="replace"):
    ln = ln.strip()
    if not ln:
        continue
    n["agent_calls"] += 1
    try:
        e = json.loads(ln)
    except Exception:
        continue
    if e.get("action") == "commit":       n["commits"] += 1
    if e.get("verdict") == "failure":     n["failures"] += 1
    if e.get("verdict") == "escalated":   n["escalations"] += 1
    if e.get("failure_class") == "unknown": n["unknown_failure_class"] += 1
for k, v in n.items():
    print(f"{k}={v}")
PY
else
  echo "cycle_log: missing"
fi
echo "direct_git_calls=$(grep -acE 'Exec\(git|(^| )git (status|add|commit|push|checkout|diff|log)' "$TR" || true)"
echo "direct_gh_calls=$(grep -acE 'Exec\(gh|(^| )gh (pr|issue|api|auth)' "$TR" || true)"
echo "confirmations_asked=$(grep -aciE 'confirm|approve\?|may i|permission|allow(ed)? (me|to)|подтверд|можно ли|разреш' "$TR" || true)"
echo "attribution_hits=$(grep -aciE 'Generated with|Co-Authored-By|Devin AI' "$TR" || true)"
V=$(grep -ac 'VERIFY: ALL PASS' "$TR" || true)
echo "verify_output=$([ "${V:-0}" -gt 0 ] && echo present || echo absent)"
