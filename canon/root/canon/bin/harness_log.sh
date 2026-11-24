#!/usr/bin/env bash
# harness_log.sh - append a completed-item record to canon/harness_log.jsonl.
# One JSON line per closed roadmap item, 8 fields (harness.md spec):
#
#   harness_log.sh append --item item_03 --category implementation \
#     --arch-revisions 1 --exec-review-rounds 2 \
#     --deviations-autonomous 1 --deviations-escalations 0 \
#     --model-tier-upgraded false \
#     --outcome merged_clean [--friction-note "..."]
#
# category: contract|implementation|test|refactor|docs|exploration|infra|epic
# outcome:  merged_clean|merged_with_deviations|escalated|abandoned
# (enum kept in sync with canon/specs/harness.md)
set -euo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
LOG="$CANON_DIR/harness_log.jsonl"

[ "${1:-}" = "append" ] || {
  echo "usage: harness_log.sh append --item .. --category .. --arch-revisions N --exec-review-rounds N --deviations-autonomous N --deviations-escalations N --model-tier-upgraded true|false --outcome .. [--friction-note ..]" >&2
  exit 2
}
shift

ITEM=""; CAT=""; AR=""; ER=""; DA=0; DE=0; MTU=false; OUT=""; NOTE=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "harness_log: dangling flag $1" >&2; exit 2; }
  case "$1" in
    --item) ITEM=$2;; --category) CAT=$2;;
    --arch-revisions) AR=$2;; --exec-review-rounds) ER=$2;;
    --deviations-autonomous) DA=$2;; --deviations-escalations) DE=$2;;
    --model-tier-upgraded) MTU=$2;; --outcome) OUT=$2;;
    --friction-note) NOTE=$2;; *) echo "harness_log: bad flag $1" >&2; exit 2;;
  esac; shift 2
done

[ -n "$ITEM" ] && [ -n "$CAT" ] && [ -n "$AR" ] && [ -n "$ER" ] && [ -n "$OUT" ] \
  || { echo "harness_log: --item --category --arch-revisions --exec-review-rounds --outcome required" >&2; exit 2; }
case "$CAT" in contract|implementation|test|refactor|docs|exploration|infra|epic) ;;
  *) echo "harness_log: bad category '$CAT'" >&2; exit 2;; esac
case "$OUT" in merged_clean|merged_with_deviations|escalated|abandoned) ;;
  *) echo "harness_log: bad outcome '$OUT'" >&2; exit 2;; esac
case "$MTU" in true|false) ;; *) echo "harness_log: --model-tier-upgraded true|false" >&2; exit 2;; esac
for n in "$AR" "$ER" "$DA" "$DE"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "harness_log: counters must be integers" >&2; exit 2; }
done

LOCK="$LOG.lock"
exec 9>"$LOCK"
flock 9 || { echo "harness_log: cannot acquire lock" >&2; exit 1; }

python3 -I - "$ITEM" "$CAT" "$AR" "$ER" "$DA" "$DE" "$MTU" "$OUT" "$NOTE" <<'PY' >> "$LOG"
import json, sys
from datetime import datetime, timezone
item, cat, ar, er, da, de, mtu, outcome, note = sys.argv[1:10]
print(json.dumps({
    "ts_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "item_id": item, "category": cat,
    "arch_revisions": int(ar), "exec_review_rounds": int(er),
    "deviations_reported": {"autonomous": int(da),
                            "contract_escalations": int(de)},
    "model_tier_upgraded": mtu == "true",
    "final_outcome": outcome,
    "friction_note": note or None}))
PY
echo "harness_log: appended $ITEM ($CAT -> $OUT)"
