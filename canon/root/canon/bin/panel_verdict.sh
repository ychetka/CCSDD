#!/usr/bin/env bash
# panel_verdict.sh - domain verdict publication for the review panel
# (specs/review_panel.md). Forge-agnostic: the transport is a
# named per-SHA signal `ccsdd/<domain>` plus a findings comment; the
# adapter under canon/forge/<forge>.sh maps it to the forge API.
#
#   panel_verdict.sh set --pr <N> --sha <sha40> --record <verdict.json>
#   panel_verdict.sh get --sha <sha40> [--domain <d>]
#
# verdict.json:
#   {"domain": "<registry domain>", "head": "<sha40>",
#    "summary": "<english text>", "receipt": ["<files inspected>", ...],
#    "findings": [{"severity": "CRITICAL|WARNING|MINOR|UNCERTAIN",
#                  "text": "..."}]}
#
# The signal state is computed MECHANICALLY - the record's own
# `verdict` field is advisory only and never trusted:
#   CRITICAL or UNCERTAIN >= 1          -> failure (fail closed)
#   otherwise                           -> success
# For domains whose registry entry declares a gate_check, success is
# only emitted when `gate_run.sh verify` passes on --sha - a
# missing/failed mechanical floor forces the signal to `failure`.
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP"
PJ="$CANON_DIR/project.json"
REG="$CANON_DIR/config/review_panel.json"
FORGE_DIR="$CANON_DIR/forge"

json_err() { python3 -c 'import json,sys;print(json.dumps({"status":"error","failure_class":sys.argv[1],"message":sys.argv[2]}))' "$1" "$2"; }

usage() {
  echo "usage: panel_verdict.sh set --pr <N> --sha <sha40> --record <verdict.json>" >&2
  echo "       panel_verdict.sh get --sha <sha40> [--domain <d>]" >&2
  exit 2
}
[ $# -ge 1 ] || usage
CMD=$1; shift

PR=""; SHA=""; RECORD=""; DOMAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR=$2;; --sha) SHA=$2;; --record) RECORD=$2;; --domain) DOMAIN=$2;;
    *) usage;;
  esac; shift 2
done
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { json_err malformed_input "--sha must be a 40-hex sha"; exit 2; }

# Forge adapter resolution: project.json `forge` (default github) ->
# canon/forge/<forge>.sh must exist.
FORGE=$(PJ="$PJ" python3 -c 'import json,os
try: print(json.load(open(os.environ["PJ"])).get("forge") or "github")
except Exception: print("github")' 2>/dev/null)
[[ "$FORGE" =~ ^[a-z][a-z0-9_]*$ ]] || { json_err malformed_input "bad forge name"; exit 2; }
ADAPTER="$FORGE_DIR/$FORGE.sh"
[ -f "$ADAPTER" ] || { json_err malformed_input "no forge adapter canon/forge/$FORGE.sh"; exit 2; }

# Panel identity binary: review.gh_bin allowlist (same policy as
# repo_pr_review.sh) - panel signals must be created by the review
# identity, not the merge/author account.
API_BIN="${GH_BIN:-}"
ALLOWED=$(PJ="$PJ" python3 -c 'import json,os,re
try:
    pj = json.load(open(os.environ["PJ"]))
    rev = pj.get("review") or {}
    bins = ["gh", "glab", rev.get("gh_bin") or "", rev.get("api_bin") or ""]
    for prof in (rev.get("reviewer_profiles") or {}).values():
        if isinstance(prof, dict):
            bins.append(prof.get("gh_bin") or "")
            bins.append(prof.get("api_bin") or "")
    print(" ".join(b for b in bins if re.fullmatch(r"[A-Za-z0-9_-]+", b or "")))
except Exception: print("gh")' 2>/dev/null)
if [ -z "$API_BIN" ]; then
  API_BIN=$(PJ="$PJ" python3 -c 'import json,os
try:
    pj = json.load(open(os.environ["PJ"])); rev = pj.get("review") or {}
    print(rev.get("gh_bin") or rev.get("api_bin") or "gh")
except Exception: print("gh")' 2>/dev/null)
fi
case "$API_BIN" in */*|*\\*) json_err malformed_input "API binary must be a bare basename"; exit 2;; esac
OK=0; for a in $ALLOWED; do [ "$API_BIN" = "$a" ] && OK=1; done
[ "$OK" = "1" ] || { json_err malformed_input "panel identity binary not in review allowlist"; exit 2; }
export API_BIN CANON_DIR

if [ "$CMD" = "get" ]; then
  bash "$ADAPTER" signal_get --sha "$SHA" || { json_err upstream_error "signal_get failed"; exit 1; }
  exit 0
fi

# ---- set ----
[ "$CMD" = "set" ] || usage
[[ "$PR" =~ ^[0-9]+$ ]] || { json_err malformed_input "--pr must be numeric"; exit 2; }
[ -f "$RECORD" ] || { json_err not_found "--record file missing"; exit 2; }
# realpath -m is GNU-only - python3 is the portable canonicalizer.
RECORD=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$RECORD")

# Validate + derive the signal state + build the comment body.
DERIVED=$(RECORD="$RECORD" REG="$REG" SHA="$SHA" CANON_DIR="$CANON_DIR" python3 - <<'PY'
import json, os, sys
reg = json.load(open(os.environ["REG"]))
domains = reg.get("domains") or {}
try:
    v = json.load(open(os.environ["RECORD"]))
except Exception as e:
    print(json.dumps({"status":"error","failure_class":"malformed_input",
                      "message":f"verdict record is not valid JSON: {e}"})); sys.exit(2)
if not isinstance(v, dict):
    print(json.dumps({"status":"error","failure_class":"malformed_input","message":"record must be an object"})); sys.exit(2)
d = v.get("domain")
if d not in domains:
    print(json.dumps({"status":"error","failure_class":"malformed_input",
                      "message":f"domain '{d}' not in review_panel.json"})); sys.exit(2)
if v.get("head") != os.environ["SHA"]:
    print(json.dumps({"status":"error","failure_class":"stale_input",
                      "message":"record.head must equal --sha"})); sys.exit(2)
receipt = v.get("receipt")
# Protocol requires min(3, files_in_diff) receipts; the wrapper can
# only enforce the non-empty invariant - reviewers report honestly.
# Entries must also look like paths: blank/whitespace strings and
# stop words ('none', 'n/a', 'todo', 'null', '-') are placeholders,
# not inspected files.
STOP = {"none", "n/a", "na", "todo", "null", "-", "tbd", "unknown"}
if not isinstance(receipt, list) or not receipt \
   or not all(isinstance(x, str) and x.strip() for x in receipt) \
   or any(x.strip().lower() in STOP for x in receipt):
    print(json.dumps({"status":"error","failure_class":"malformed_input",
                      "message":"receipt must be a non-empty list of inspected file paths (no blanks/placeholders)"})); sys.exit(2)
findings = v.get("findings")
if not isinstance(findings, list):
    print(json.dumps({"status":"error","failure_class":"malformed_input","message":"findings must be a list"})); sys.exit(2)
SEV = {"CRITICAL","WARNING","MINOR","UNCERTAIN"}
for f in findings:
    if not isinstance(f, dict) or f.get("severity") not in SEV or not isinstance(f.get("text"), str) or not f["text"].strip():
        print(json.dumps({"status":"error","failure_class":"malformed_input",
                          "message":"each finding needs {severity: CRITICAL|WARNING|MINOR|UNCERTAIN, text}"})); sys.exit(2)
blocking = [f for f in findings if f["severity"] in ("CRITICAL","UNCERTAIN")]
state = "failure" if blocking else "success"
entry = domains[d]
out = {"status":"ok","domain":d,"signal":reg.get("signal_prefix","ccsdd/")+d,
       "state":state,"needs_floor":bool(entry.get("gate_check")),
       "gate_check":entry.get("gate_check"),
       "summary":v.get("summary") or "",
       "findings":findings}
print(json.dumps(out))
PY
) || { echo "$DERIVED"; exit 2; }

ST=$(printf '%s' "$DERIVED" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get("state"))')
DOM=$(printf '%s' "$DERIVED" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get("domain"))')
SIG=$(printf '%s' "$DERIVED" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get("signal"))')
GC=$(printf '%s' "$DERIVED" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get("gate_check") or "")')

# Mechanical floor enforcement (independent of the caller's honesty):
# a hybrid/ci domain may only emit success when its floor record on
# this exact sha is green.
if [ -n "$GC" ] && [ "$ST" = "success" ]; then
  if ! "$CANON_DIR/bin/gate_run.sh" verify --check "$GC" --candidate "$SHA" >/dev/null 2>&1; then
    ST=failure
    FLOOR_NOTE="mechanical floor '$GC' missing or failed on this head"
  fi
fi

# Compose the findings comment; hygiene-gate every outgoing text.
BODY=$(DERIVED="$DERIVED" SHA="$SHA" ST="$ST" FLOOR_NOTE="${FLOOR_NOTE:-}" python3 - <<'PY'
import json, os
d = json.loads(os.environ["DERIVED"])
head = os.environ["SHA"][:8]
lines = [f"## {d['domain']} — review @{head}", ""]
lines.append(f"**Signal:** `{d['signal']} = {os.environ['ST']}`")
if os.environ.get("FLOOR_NOTE"):
    lines.append(f"**Floor:** {os.environ['FLOOR_NOTE']}")
if d.get("summary"):
    lines += ["", d["summary"]]
if d["findings"]:
    lines += ["", "**Findings:**"]
    for f in d["findings"]:
        lines.append(f"- [{f['severity']}] {f['text']}")
else:
    lines += ["", "No findings."]
print("\n".join(lines))
PY
)
if ! printf '%s\n' "$BODY" | "$CANON_DIR/bin/hygiene_check.sh" >/dev/null 2>&1; then
  json_err gate_blocked "panel comment failed hygiene_check"; exit 2
fi

# Publish: comment first (carries the findings), then the named
# signal bound to --sha with the comment as target_url.
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/panel-verdict.XXXXXX.md")
trap 'rm -f "$BODY_FILE"' EXIT INT TERM
printf '%s' "$BODY" > "$BODY_FILE"
CURL_OUT=$(bash "$ADAPTER" finding_post --pr "$PR" --body-file "$BODY_FILE" 2>/dev/null)
CURL=$(printf '%s' "$CURL_OUT" | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read() or "{}").get("url") or "")
except Exception: print("")' 2>/dev/null)

DESCR=$(printf '%s' "$DERIVED" | python3 -c 'import json,sys
d=json.loads(sys.stdin.read()); n=len(d["findings"])
b=sum(1 for f in d["findings"] if f["severity"] in ("CRITICAL","UNCERTAIN"))
print((f"{b} blocking finding(s), {n} total" if n else "no findings")[:140])')

bash "$ADAPTER" signal_set --sha "$SHA" --context "$SIG" --state "$ST" \
  --description "$DESCR" ${CURL:+--url "$CURL"} || { json_err upstream_error "signal_set failed"; exit 1; }

# WARNING telemetry: non-blocking findings must not vanish silently
# at auto-merge - count them into the cycle log so a risk:high human
# sign-off summary shows the accumulated debt. Best-effort: the
# merge workspace may lack the actor registry, never block on it.
WARN_N=$(printf '%s' "$DERIVED" | python3 -c 'import json,sys
d=json.loads(sys.stdin.read())
print(sum(1 for f in d["findings"] if f["severity"]=="WARNING"))' 2>/dev/null || echo 0)
VERDICT_C="ok"; [ "$ST" = "success" ] || VERDICT_C="failure"
if [ "$VERDICT_C" = ok ]; then
  "$CANON_DIR/bin/cycle_log.sh" append --item "panel_pr_${PR}" \
    --actor "reviewer_${DOM}" --action panel_verdict \
    --expected "domain ${DOM} signal" \
    --result "state=${ST} warnings=${WARN_N}" \
    --status closed --verdict ok --failure-class "" >/dev/null 2>&1 || true
else
  "$CANON_DIR/bin/cycle_log.sh" append --item "panel_pr_${PR}" \
    --actor "reviewer_${DOM}" --action panel_verdict \
    --expected "domain ${DOM} signal" \
    --result "state=${ST} warnings=${WARN_N}" \
    --status closed --verdict failure --failure-class panel_domain >/dev/null 2>&1 || true
fi

python3 -c 'import json,sys;print(json.dumps({"status":"ok","signal":sys.argv[1],"state":sys.argv[2],"sha":sys.argv[3]}))' "$SIG" "$ST" "$SHA"
