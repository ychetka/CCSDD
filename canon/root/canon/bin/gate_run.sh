#!/usr/bin/env bash
# gate_run.sh - mechanical floor runner with execution attestation.
#
#   gate_run.sh run    --check <name> --candidate <sha40>
#   gate_run.sh status --check <name> --candidate <sha40>
#   gate_run.sh verify --check <name> --candidate <sha40>
#
# A check resolves in this order:
#   1. canon script:  <base>:canon/bin/<name>.sh - the blob is taken
#      from the BASE ref, never the candidate worktree, so a PR cannot
#      edit its own gate into `exit 0`. canon/bin scripts must honor
#      the CANON_DIR env var (exported by this runner).
#   2. project command: project.json `gate_checks.<name>` - an argv
#      array declared by the repo (lint/tests/SAST). Executes in the
#      candidate worktree: it may run untrusted PR code, so it is for
#      credential-free contexts only (director/merge runner, writer,
#      judge worktrees) - NEVER inside reviewer/repository agents.
#
# `run` requires: HEAD == --candidate AND a clean worktree - the
# attested verdict is bound to exactly that tree state.
# Every `run` appends a record to canon/gate_runs.jsonl:
#   {ts, check, runner, script_sha256|argv, base_ref, candidate_sha,
#    exit_code, output_sha256}
# `status` prints the newest record for (check, candidate) as JSON.
# `verify` exits 0 iff the newest record has exit_code==0 AND (canon
# runner) script_sha256 equals the base blob hash.
set -uo pipefail
SHA256_BIN=$(command -v sha256sum || true)
[ -z "$SHA256_BIN" ] && SHA256_BIN="shasum -a 256"
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP"
JOURNAL="$CANON_DIR/gate_runs.jsonl"
PJ="$CANON_DIR/project.json"

usage() {
  echo "usage: gate_run.sh run --check <name> --candidate <sha40>" >&2
  echo "       gate_run.sh status --check <name> --candidate <sha40>" >&2
  echo "       gate_run.sh verify --check <name> --candidate <sha40>" >&2
  exit 2
}
[ $# -ge 1 ] || usage
CMD=$1; shift

CHECK=""; CAND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=$2; shift 2;;
    --candidate) CAND=$2; shift 2;;
    *) usage;;
  esac
done
[ -n "$CHECK" ] && [ -n "$CAND" ] || usage
[[ "$CHECK" =~ ^[a-z][a-z0-9_]*$ ]] || { echo "gate_run: bad check name '$CHECK'" >&2; exit 2; }
[[ "$CAND" =~ ^[0-9a-f]{40}$ ]] || { echo "gate_run: --candidate must be a 40-hex sha" >&2; exit 2; }

# Base ref: the trusted source of canon gate scripts. A caller that
# knows the PR's real base (panel_gate hands down the PR baseRefName)
# passes BASE_REF/BASE in the env - otherwise we derive from
# project.json base_branch. Guessing 'main' on an epic-bound PR would
# attest the whole epic diff, not the task diff.
BASE_BRANCH=$(CANON_DIR="$CANON_DIR" python3 -I -c 'import json,os
try: print(json.load(open(os.path.join(os.environ["CANON_DIR"],"project.json"))).get("base_branch") or "main")
except Exception: print("main")' 2>/dev/null)
BASE_REF="${BASE_REF:-}"
if [ -z "$BASE_REF" ]; then
  # Probe every configured remote, not just 'origin': a mirror or a
  # fork-named remote would leave BASE_REF empty and attest the
  # whole branch history instead of the delta.
  for cand_ref in $(git remote 2>/dev/null | sed "s#\$#/$BASE_BRANCH#") "$BASE_BRANCH"; do
    git rev-parse --verify --quiet "$cand_ref" >/dev/null 2>&1 && { BASE_REF=$cand_ref; break; }
  done
fi
# Resolved base head: the attestation records what base the floor
# ran against so a later verify can detect a moved base (stale
# evidence must not validate a new diff window).
BASE_HEAD=""
[ -n "$BASE_REF" ] && BASE_HEAD=$(git rev-parse "$BASE_REF" 2>/dev/null || true)
# Child check scripts take BASE as their diff base ref: honor an
# explicit caller BASE, else give them the merge-base so
# three-dot diffs compute exactly what we attested.
CHILD_BASE="${BASE:-}"
if [ -z "$CHILD_BASE" ] && [ -n "$BASE_REF" ]; then
  CHILD_BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || true)
fi

# Resolve the runner + script source. Priority:
#   1. deployed script pinned by canon_manifest.json - the manifest is
#      the deploy-integrity root, and a manifest-pinned file beats a
#      base-ref blob (a repo that TRACKED canon before untracking
#      leaves a stale blob that would self-attest; its aux imports
#      resolve from disk anyway, so blob execution adds no isolation).
#      A pin MISMATCH refuses outright - never silent-fall-back.
#   2. base-ref blob (canon tracked in repo, no manifest coverage) -
#      minimal fixtures and legacy layouts.
#   3. deployed script without manifest coverage.
#   4. project.json gate_checks.<name> argv.
RUNNER=""; SCRIPT_TMP=""; SCRIPT_SRC=""
CANON_PATH="canon/bin/$CHECK.sh"
BASE_SHA=""
DEPLOYED="$CANON_DIR/bin/$CHECK.sh"
MF_PIN=absent   # absent|ok|mismatch|unlisted
if [ -f "$CANON_DIR/canon_manifest.json" ] && [ -f "$DEPLOYED" ]; then
  MF_PIN=$(DEPLOYED="$DEPLOYED" CANON_PATH="$CANON_PATH" CANON_DIR="$CANON_DIR" \
    python3 -I - <<'PY'
import hashlib, json, os, sys
try:
    mf = json.load(open(os.path.join(os.environ["CANON_DIR"], "canon_manifest.json")))
    want = (mf.get("sha256") or {}).get(os.environ["CANON_PATH"])
except Exception:
    print("unlisted"); sys.exit(0)
if not isinstance(want, str):
    print("unlisted"); sys.exit(0)
h = hashlib.sha256(open(os.environ["DEPLOYED"], "rb").read()).hexdigest()
print("ok" if h == want else "mismatch")
PY
)
fi
case "$MF_PIN" in
  ok)
    # The pin is only as good as the manifest itself - and the
    # manifest is workspace-writable. When the deploy left an
    # external stamp, the local manifest must hash to it before its
    # 'ok' verdict means anything.
    if [ -x "$CANON_DIR/bin/stamp_verify.sh" ]; then
      SRC=0; "$CANON_DIR/bin/stamp_verify.sh" || SRC=$?
      case "$SRC" in
        0|3) ;;  # match, or unmanaged workspace (no stamp)
        *) echo "gate_run: canon_manifest.json fails the external stamp check - manifest pins are self-attested, refusing" >&2
           exit 1 ;;
      esac
    fi
    RUNNER=canon; SCRIPT_SRC=deployed
    BASE_SHA=$($SHA256_BIN "$DEPLOYED" | cut -d' ' -f1) ;;
  mismatch|unlisted)
    # Fail-closed like Gate-0: a deployed canon tree plus a manifest
    # that does not cover this script means either a tampered file or
    # an attacker-dropped gate - never silent-fall-back to the blob.
    echo "gate_run: $CANON_PATH failed manifest pin ($MF_PIN) - refuse to execute tampered gate" >&2
    exit 1 ;;
esac
if [ -z "$RUNNER" ] && [ -n "$BASE_REF" ] && git cat-file -e "$BASE_REF:$CANON_PATH" 2>/dev/null; then
  RUNNER=canon; SCRIPT_SRC=blob
  BASE_SHA=$(git show "$BASE_REF:$CANON_PATH" | $SHA256_BIN | cut -d' ' -f1)
elif [ -z "$RUNNER" ] && [ -f "$DEPLOYED" ]; then
  RUNNER=canon; SCRIPT_SRC=deployed
  BASE_SHA=$($SHA256_BIN "$DEPLOYED" | cut -d' ' -f1)
elif [ -z "$RUNNER" ]; then
  ARGV=$(PJ="$PJ" CHECK="$CHECK" python3 -I -c 'import json,os
try:
    pj = json.load(open(os.environ["PJ"]))
    v = (pj.get("gate_checks") or {}).get(os.environ["CHECK"])
    print("\t".join(v) if isinstance(v, list) else "")
except Exception: print("")' 2>/dev/null)
  [ -n "$ARGV" ] && RUNNER=project
fi
# An unresolved check may be explicitly optional: gate_checks.<name>
# absent + gate_checks.<name>_optional=true -> a recorded skip-pass
# (exit 0, note="optional"). Default is fail-closed.
OPTIONAL=""
if [ -z "$RUNNER" ]; then
  OPTIONAL=$(PJ="$PJ" CHECK="$CHECK" python3 -I -c 'import json,os
try:
    pj = json.load(open(os.environ["PJ"]))
    v = (pj.get("gate_checks") or {}).get(os.environ["CHECK"] + "_optional")
    print("yes" if v is True else "")
except Exception: print("")' 2>/dev/null)
fi

latest_record() {
  JOURNAL="$JOURNAL" CHECK="$CHECK" CAND="$CAND" python3 -I - <<'PY'
import json, os
check, cand = os.environ["CHECK"], os.environ["CAND"]
j = os.environ["JOURNAL"]
rec = None
try:
    for line in open(j, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except Exception: continue
        if r.get("check") == check and r.get("candidate_sha") == cand:
            rec = r
except OSError:
    pass
print(json.dumps(rec) if rec else "")
PY
}

if [ "$CMD" = "status" ]; then
  REC=$(latest_record)
  if [ -n "$REC" ]; then echo "$REC"; exit 0
  else echo '{"status":"no_record"}'; exit 4; fi
fi

if [ "$CMD" = "verify" ]; then
  REC=$(latest_record)
  if [ -z "$REC" ] && [ "$OPTIONAL" = "yes" ]; then
    # optional + unconfigured + never run = the floor is N/A here,
    # not missing evidence. A recorded failure still fails below.
    echo "gate_run verify: $CHECK optional/unconfigured - N/A"
    exit 0
  fi
  [ -n "$REC" ] || { echo "gate_run verify: no record for $CHECK @ ${CAND:0:8}" >&2; exit 4; }
  echo "$REC" | REC_SHA="$BASE_SHA" REC_BASE_HEAD="$BASE_HEAD" ARGV="${ARGV:-}" python3 -I -c 'import json,os,sys
r = json.loads(sys.stdin.read() or "null") or {}
if r.get("exit_code") != 0:
    print("gate_run verify: %s recorded exit_code=%s" % (r.get("check"), r.get("exit_code")), file=sys.stderr); sys.exit(1)
want = os.environ.get("REC_SHA") or ""
if r.get("runner") == "canon" and want and r.get("script_sha256") != want:
    print("gate_run verify: script_sha256 drift vs base for %s" % r.get("check"), file=sys.stderr); sys.exit(1)
# base binding: the attestation is evidence for the diff window
# (base,candidate]. If the base moved since the run, the verdict was
# computed on a different window - stale evidence must not pass.
# CANON-runner only: a project check (pytest/npm test) evaluates the
# candidate TREE, not the diff window - its base_head is informational
# and must not deadlock task->epic merges where the PR base ref
# legitimately differs from the branch-level base_branch.
cur_base = os.environ.get("REC_BASE_HEAD") or ""
if r.get("runner") == "canon" and r.get("base_head") and cur_base and r["base_head"] != cur_base:
    print("gate_run verify: base moved since attestation for %s "
          "(%s -> %s)" % (r.get("check"), r["base_head"][:12], cur_base[:12]),
          file=sys.stderr); sys.exit(1)
# project runner: the recorded argv must still match project.json -
# a config change after attestation invalidates the record.
if r.get("runner") == "project" and "argv" in r:
    cur = [a for a in os.environ.get("ARGV","").split("\t") if a]
    if r.get("argv") != cur:
        print("gate_run verify: argv drift vs project.json for %s" % r.get("check"), file=sys.stderr); sys.exit(1)
sys.exit(0)' || exit $?
  echo "gate_run verify: $CHECK @ ${CAND:0:8} OK"
  exit 0
fi

if [ "$CMD" != "run" ]; then usage; fi

if [ -z "$RUNNER" ]; then
  if [ "$OPTIONAL" = "yes" ]; then
    RUNNER=project; ARGV=""
  else
    echo "gate_run: check '$CHECK' resolves to nothing (no canon script, no project.json gate_checks.$CHECK; set gate_checks.${CHECK}_optional=true to allow skip)" >&2
    exit 2
  fi
fi

# Binding preconditions: the attested tree is exactly --candidate.
HEAD=$(git rev-parse HEAD 2>/dev/null)
[ "$HEAD" = "$CAND" ] || { echo "gate_run: HEAD($HEAD) != candidate($CAND) - refuse to attest a different tree" >&2; exit 1; }
# The clean-tree requirement binds the attestation to the exact
# candidate content. Runtime journals the harness itself appends
# (gate_runs.jsonl, cycle_log, panel fixtures, signoff stores) are
# bookkeeping, not candidate content - in tracked-canon test
# fixtures they would otherwise dirty the tree reflexively.
DIRTY=$(git status --porcelain 2>/dev/null | grep -v -E \
  'canon/(gate_runs\.jsonl.*|cycle_log\.jsonl.*|actors\.json.*|panel_signals_fixture\.json.*|panel_comments_fixture\.jsonl.*|release_history\.jsonl.*|human_signoffs/|quota_park\.json.*|gateway|harness_log\.jsonl.*|migration_ok|scope_whitelist\.txt|canon_manifest\.json|.*\.(lock|tmp))|.*__pycache__/.*|.*\.pyc' \
  || true)
[ -z "$DIRTY" ] || { echo "gate_run: dirty worktree - refuse to attest" >&2; printf '%s\n' "$DIRTY" >&2; exit 1; }

OUT=$(mktemp); SCRIPT_TMP=""
# The executed check runs whatever code the PR carries (project
# runner) or canon scripts that shell out to project tooling (canon
# runner). Neither may see the caller's credentials: an agent-run
# pytest with access to SSH_AUTH_SOCK could mint human_sign.sh
# envelopes itself, and a forged GH_TOKEN leaks to any child.
# PATH hygiene: the check runs with CWD inside the candidate tree,
# so an inherited relative PATH segment ('.', '.venv/bin',
# 'node_modules/.bin') - or any segment resolving inside the repo
# top - would exec the PR's own planted binaries (a fake python3 /
# radon / lizard) under merge credentials. Drop relative segments
# and anything under $TOP; keep absolute system paths only
# (review_15 #4, same rule as verify_worktree's CLEAN_PATH).
TOP_REAL=$(pwd -P)
CLEAN_PATH=$(TOP_REAL="$TOP_REAL" python3 -I -c 'import os
top = os.environ["TOP_REAL"]
out = []
for seg in os.environ.get("PATH", "").split(os.pathsep):
    if not seg:
        continue
    if not os.path.isabs(seg):
        continue                      # relative - resolves under CWD
    r = os.path.realpath(seg)
    try:
        if os.path.commonpath([r, top]) == top:
            continue                  # inside the candidate tree
    except ValueError:
        pass
    out.append(seg)
print(os.pathsep.join(out))')
CHECK_ENV=(env -u SSH_AUTH_SOCK -u SSH_AGENT_PID -u SSH_ASKPASS \
           -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
           -u GITHUB_ENTERPRISE_TOKEN -u GL_TOKEN -u GITLAB_TOKEN \
           -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
           "PATH=$CLEAN_PATH")
if [ "$RUNNER" = canon ]; then
  SCRIPT_TMP=$(mktemp)
  if [ "$SCRIPT_SRC" = "blob" ]; then
    git show "$BASE_REF:$CANON_PATH" > "$SCRIPT_TMP" 2>/dev/null
  else
    cat "$DEPLOYED" > "$SCRIPT_TMP"
  fi
  CANON_DIR="$CANON_DIR" BASE="$CHILD_BASE" BASE_REF="$BASE_REF" \
    "${CHECK_ENV[@]}" bash "$SCRIPT_TMP" > "$OUT" 2>&1
  RC=$?
elif [ "$OPTIONAL" = "yes" ]; then
  echo "SKIP: $CHECK optional and unconfigured" > "$OUT"; RC=0
else
  IFS=$'\t' read -r -a PARGV <<< "$ARGV"
  "${CHECK_ENV[@]}" "${PARGV[@]}" > "$OUT" 2>&1
  RC=$?
fi
OUT_SHA=$($SHA256_BIN "$OUT" | cut -d' ' -f1)
# Checks may emit structured annotations consumed by other gates:
#   GATE_NOTE: <text>  -> recorded as rec.note (e.g. axes=none)
NOTE=$(grep -m1 '^GATE_NOTE: ' "$OUT" 2>/dev/null | sed 's/^GATE_NOTE: //')

exec 9>"$JOURNAL.lock"
flock 9 || { echo "gate_run: cannot acquire lock" >&2; rm -f "$OUT" "$SCRIPT_TMP"; exit 1; }
CANON_DIR="$CANON_DIR" OUT_SHA="$OUT_SHA" RC="$RC" CHECK="$CHECK" CAND="$CAND" \
  RUNNER="$RUNNER" BASE_SHA="$BASE_SHA" BASE_REF="$BASE_REF" \
  BASE_HEAD="$BASE_HEAD" ARGV="${ARGV:-}" \
  NOTE="${NOTE:-}" python3 -I - 9>&- <<'PY' >> "$JOURNAL"
import datetime, hashlib, json, os, sys
rec = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "check": os.environ["CHECK"],
       "runner": os.environ["RUNNER"],
       "base_ref": os.environ["BASE_REF"] or None,
       "candidate_sha": os.environ["CAND"],
       "exit_code": int(os.environ["RC"]),
       "output_sha256": os.environ["OUT_SHA"]}
if os.environ.get("BASE_HEAD"):
    rec["base_head"] = os.environ["BASE_HEAD"]
if os.environ["RUNNER"] == "canon":
    rec["script_sha256"] = os.environ["BASE_SHA"]
else:
    rec["argv"] = [a for a in os.environ["ARGV"].split("\t") if a]
if os.environ.get("NOTE"):
    rec["note"] = os.environ["NOTE"]
print(json.dumps(rec))
PY

tail -n 20 "$OUT" >&2
rm -f "$OUT" "$SCRIPT_TMP"
exit $RC
