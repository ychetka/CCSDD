#!/usr/bin/env bash
# panel_gate.sh - review-panel merge gate (specs/review_panel.md).
# Called by issue_merge.sh after the blood-sign verify, with the
# candidate checked out at --worktree (detached at --sha).
#
#   panel_gate.sh --sha <sha40> --worktree <wt> --info-file <pr.json>
#
# Verifies, fail-closed, in this order:
#   1. Every registry entry with a gate_check must have a GREEN
#      attestation at --sha. Canon scripts (static analysis only -
#      they read files, never execute project code) are RUN here in
#      the merge context via gate_run; project commands
#      (gate_checks.* argv - they execute PR code) are only VERIFIED
#      against the journal: they must have been attested earlier by
#      the pipeline inside the credential-free candidate worktree.
#      The floor requirement is unconditional - an advisory LLM
#      domain never disables its mechanical floor.
#   2. Every REQUIRED llm/hybrid domain has its `ccsdd/<domain>`
#      signal == success on --sha, created by a configured review
#      identity (project.json review.reviewer_logins /
#      reviewer_profiles[*].login).
#   3. project.json `external_checks` (DAST and other forge-side CI
#      names) appear green in the PR statusCheckRollup.
# Exit 0 clean / exit 1 blocked (JSON report on stdout).
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

# Network discipline (review_16 #13): no forge/git call may hang a
# gate slot forever - prompt-hangs die instantly via the env flags,
# transport stalls die via `timeout` where the binary exists.
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30
NET_TO=$(command -v timeout || command -v gtimeout || true)
# Gate 0 (review_15 #5 / review_16 #12): never run under a
# workspace-tampered canon - prove manifest hashes + the external
# stamp before trusting any $CANON_DIR script or adapter hook.
if [ -f "$CANON_DIR/canon_manifest.json" ]; then
  [ -x "$CANON_DIR/bin/assert_canon_integrity.sh" ] \
    || { echo "GATE_INTEGRITY: assert_canon_integrity.sh missing under a pinned manifest" >&2; exit 1; }
  "$CANON_DIR/bin/assert_canon_integrity.sh" || exit 1
fi
PJ="$CANON_DIR/project.json"
REG="$CANON_DIR/config/review_panel.json"
FORGE_DIR="$CANON_DIR/forge"

json_out() { python3 -I -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1])))' "$1"; }

SHA=""; WT=""; INFO_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) SHA=$2;; --worktree) WT=$2;; --info-file) INFO_FILE=$2;; *) shift;;
  esac; shift 2
done
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { json_out '{"status":"error","failure_class":"malformed_input","message":"--sha must be 40-hex"}'; exit 1; }
[ -d "$WT" ] || { json_out '{"status":"error","failure_class":"malformed_input","message":"--worktree missing"}'; exit 1; }
[ -f "$REG" ] || { json_out '{"status":"blocked","failure_class":"missing_panel_registry","message":"canon/config/review_panel.json absent"}'; exit 1; }

FORGE=$(PJ="$PJ" python3 -I -c 'import json,os
try: print(json.load(open(os.environ["PJ"])).get("forge") or "github")
except Exception: print("github")' 2>/dev/null)
ADAPTER="$FORGE_DIR/$FORGE.sh"
[ -f "$ADAPTER" ] || { json_out "{\"status\":\"error\",\"failure_class\":\"malformed_input\",\"message\":\"no forge adapter $FORGE.sh\"}"; exit 1; }

# Read identity for signal_get: the merge/author binary through the
# canonical resolver - never the reviewer identity here (this gate
# runs under merge credentials; review.* keys are not a fallback).
API_BIN=$("$CANON_DIR/bin/gh_id.sh" merge 2>/dev/null || true)
[ -n "$API_BIN" ] || { json_out '{"status":"error","failure_class":"malformed_input","message":"merge.gh_bin in project.json is not a bare binary basename"}'; exit 1; }
export API_BIN CANON_DIR

# --- 1. mechanical floors ---
# canon scripts: safe to run here (file reads only). project argv:
# code execution - verify the journal, never run under merge creds.
# Base branch = the PR's own baseRefName (INFO_FILE), not
# project.json base_branch: merging a task PR into an epic branch
# must gate the task-vs-epic diff - checking the whole epic vs main
# would re-judge every previously merged task (and their fragments
# would fail spec_anchor's issue binding).
BB=$(INFO_FILE="$INFO_FILE" PJ="$PJ" python3 -I - <<'PY'
import json, os
bb = ""
try:
    f = os.environ.get("INFO_FILE") or ""
    if f and os.path.isfile(f):
        bb = (json.load(open(f)).get("baseRefName") or "").strip()
except Exception:
    bb = ""
if not bb:
    try:
        bb = json.load(open(os.environ["PJ"])).get("base_branch") or "main"
    except Exception:
        bb = "main"
print(bb)
PY
)
# Remote like issue_merge: project.json 'repo' is a bare slug
# 'owner/name' - match it as a SUFFIX of the remote URL, then fall
# back to a github/gitlab URL heuristic, then 'origin'.
REPO_SLUG=$(CANON_DIR="$CANON_DIR" python3 -I -c 'import json,os
try: print((json.load(open(os.path.join(os.environ["CANON_DIR"],"project.json"))).get("repo") or "").strip("/"))
except Exception: print("")' 2>/dev/null)
REMOTE=""
if [ -n "$REPO_SLUG" ]; then
  REMOTE=$(git remote -v | awk -v s="$REPO_SLUG" '$2 ~ ("(^|[:/])" s "(\\.git)?$") {print $1; exit}')
fi
[ -z "$REMOTE" ] && REMOTE=$(git remote -v | awk '$2 ~ /github\.com|gitlab\./ {print $1; exit}')
[ -z "$REMOTE" ] && REMOTE=$(git remote get-url origin >/dev/null 2>&1 && echo origin)
BREF=""
for r in ${REMOTE:+"$REMOTE/$BB"} $(git remote | sed "s#\$#/$BB#") "$BB"; do
  git rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { BREF=$r; break; }
done
FLOOR_FAIL=""; FLOOR_NOTES="{}"
while IFS= read -r chk; do
  [ -z "$chk" ] && continue
  # Canon floors are static-only (no project argv) -> safe to run in
  # the merge context. Source of truth: base-ref blob when canon is
  # tracked, else the deploy-pinned $CANON_DIR script. Project argv
  # floors (runner=project) are NEVER run here - only their prior
  # credential-free journal attestations are verified.
  if { [ -n "$BREF" ] && git cat-file -e "$BREF:canon/bin/$chk.sh" 2>/dev/null; } \
     || [ -f "$CANON_DIR/bin/$chk.sh" ]; then
    (cd "$WT" && BASE_REF="$BREF" bash "$CANON_DIR/bin/gate_run.sh" run --check "$chk" --candidate "$SHA") >/dev/null 2>&1
  fi
  BASE_REF="$BREF" bash "$CANON_DIR/bin/gate_run.sh" verify --check "$chk" --candidate "$SHA" >/dev/null 2>&1 \
    || FLOOR_FAIL="$FLOOR_FAIL $chk"
  NREC=$(bash "$CANON_DIR/bin/gate_run.sh" status --check "$chk" --candidate "$SHA" 2>/dev/null)
  FLOOR_NOTES=$(FN="$FLOOR_NOTES" NR="$NREC" CHK="$chk" python3 -I -c 'import json,os
d = json.loads(os.environ["FN"])
try: r = json.loads(os.environ["NR"])
except Exception: r = None
if r and r.get("note"): d[os.environ["CHK"]] = r["note"]
print(json.dumps(d))')
done < <(REG="$REG" python3 -I -c 'import json,os
d = json.load(open(os.environ["REG"]))
for name, e in (d.get("domains") or {}).items():
    if e.get("gate_check"): print(e["gate_check"])' | sort -u)

# --- 1b. project-declared checks not consumed by any domain ---
# gate_checks.* keys that no registry gate_check names (lint, sast,
# typecheck, extra suites) still bind the merge: each must have a
# green attestation at --sha in gate_runs.jsonl, recorded earlier in
# the credential-free worktree (gate_run run). *_optional opt-outs
# are handled inside gate_run verify itself.
REG_CHECKS=$(REG="$REG" python3 -I -c 'import json,os
d = json.load(open(os.environ["REG"]))
print(" ".join(sorted({e.get("gate_check") or "" for e in
      (d.get("domains") or {}).values()} - {""})))' 2>/dev/null)
while IFS= read -r chk; do
  [ -z "$chk" ] && continue
  case " $REG_CHECKS " in *" $chk "*) continue;; esac
  BASE_REF="$BREF" bash "$CANON_DIR/bin/gate_run.sh" verify --check "$chk" --candidate "$SHA" >/dev/null 2>&1 \
    || FLOOR_FAIL="$FLOOR_FAIL $chk"
done < <(PJ="$PJ" python3 -I -c 'import json,os
try:
    gc = json.load(open(os.environ["PJ"])).get("gate_checks") or {}
except Exception: gc = {}
for k in sorted(gc):
    if not k.endswith("_optional"): print(k)')

# --- 2. domain signals on --sha ---
SIG_JSON=$(bash "$ADAPTER" signal_get --sha "$SHA" 2>/dev/null || echo '{"signals":[]}')
PANEL_REPORT=$(SIG_JSON="$SIG_JSON" REG="$REG" PJ="$PJ" SHA="$SHA" FLOOR_FAIL="$FLOOR_FAIL" FLOOR_NOTES="$FLOOR_NOTES" INFO_FILE="$INFO_FILE" python3 -I - <<'PY'
import json, os
reg = json.load(open(os.environ["REG"]))
domains = reg.get("domains") or {}
prefix = reg.get("signal_prefix", "ccsdd/")
try:
    pj = json.load(open(os.environ["PJ"]))
except Exception:
    pj = {}
rev = pj.get("review") or {}
logins = {l.lower() for l in (rev.get("reviewer_logins") or [])}
# reviewer_profiles is keyed BY login (canonical schema).
for k, prof in (rev.get("reviewer_profiles") or {}).items():
    logins.add(k.lower())
    if isinstance(prof, dict) and prof.get("login"):
        logins.add(prof["login"].lower())
# review.panel (optional) narrows which domains need an LLM signal;
# mechanical floors above are unconditional either way.
active = set(rev.get("panel") or domains.keys())
floor_notes = {}
try:
    floor_notes = json.loads(os.environ.get("FLOOR_NOTES") or "{}")
except Exception:
    floor_notes = {}
sha = os.environ["SHA"]
sigs = {}
try:
    for s in (json.loads(os.environ["SIG_JSON"]).get("signals") or []):
        sigs[s.get("domain")] = s
except Exception:
    sigs = {}

missing, bad_creator, failed = [], [], []
for name, e in domains.items():
    if e.get("class") == "ci" or not e.get("required", True):
        continue
    if name not in active:
        continue
    # deterministic auto-pass: a domain flagged auto_pass_when_no_axes
    # whose floor attested axes=none on this head needs no LLM signal.
    if e.get("auto_pass_when_no_axes") \
       and floor_notes.get(e.get("gate_check") or "") == "axes=none":
        continue
    s = sigs.get(name)
    if s is None:
        missing.append(name); continue
    if s.get("state") != "success":
        failed.append(f"{name}:{s.get('state')}")
    cr = (s.get("creator") or "").lower()
    if logins and cr not in logins:
        bad_creator.append(f"{name}:{cr or '?'}")
advisory_missing = [n for n, e in domains.items()
                    if e.get("class") != "ci" and not e.get("required", True)
                    and n not in sigs]

# 3. external checks (DAST & friends) green in the rollup
ext_missing, ext_bad = [], []
ext = pj.get("external_checks") or []
if ext and os.environ.get("INFO_FILE"):
    try:
        info = json.load(open(os.environ["INFO_FILE"]))
        rollup = info.get("statusCheckRollup") or []
    except Exception:
        rollup = []
    def names(c):
        return {c.get("name") or "", c.get("context") or ""} - {""}
    def green(c):
        return (c.get("conclusion") or c.get("state") or "") in ("SUCCESS", "success")
    for req in ext:
        hits = [c for c in rollup
                if any(req == n or n.endswith(" / " + req) for n in names(c))]
        if not hits: ext_missing.append(req)
        elif not all(green(c) for c in hits): ext_bad.append(req)

floor_fail = os.environ.get("FLOOR_FAIL","").split()
ok = not (missing or failed or bad_creator or floor_fail or ext_missing or ext_bad)
fc = None
if not ok:
    if missing: fc = "missing_review_domain"
    elif bad_creator: fc = "bad_creator"
    elif failed or floor_fail: fc = "gate_blocked"
    else: fc = "external_check_failed"
print(json.dumps({
    "ok": ok, "failure_class": fc,
    "missing_domains": missing, "failed_domains": failed,
    "bad_creator": bad_creator, "floor_failures": floor_fail,
    "advisory_absent": advisory_missing,
    "external_missing": ext_missing, "external_failing": ext_bad,
    "signals_seen": {k: {"state": v.get("state"), "creator": v.get("creator")}
                     for k, v in sigs.items()}}))
PY
)
echo "$PANEL_REPORT"
OK=$(printf '%s' "$PANEL_REPORT" | python3 -I -c 'import json,sys
try: print("yes" if json.load(sys.stdin)["ok"] else "no")
except Exception: print("no")')
[ "$OK" = "yes" ] && exit 0 || exit 1
