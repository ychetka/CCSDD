#!/usr/bin/env bash
# pipeline_tests.sh - negative tests for the deploy/merge/release
# layer (complements gate_tests.sh, which covers commit-wrapper
# gates).
#
# Proves in isolated scratch workspaces:
#   D1  real deploy: check_setup green on a fresh start_project.sh run
#   D2  unlisted file inside canon/bin/ breaks integrity (fail closed)
#   D3  unlisted file at the canon/ ROOT breaks integrity too
#   D4  tampered manifest-listed gate script breaks integrity
#   D5  tampered adapter-managed file (AGENTS.md) breaks integrity
#       via the adapters_sha256 pin
#   D6  runtime exceptions (partner_journal) do NOT break integrity
#   G1  partner_call refuses secret-looking args
#   G2  GATEWAY_AUDIT_MAX env cannot RAISE the policy limit
#   G3  GATEWAY_AUDIT_MAX env may TIGHTEN the policy limit
#   G4  consult daily limit refusal (quota_limited)
#   G5  concurrent calls are all counted (flock)
#   G6  hung partner times out (upstream_timeout)
#   G7  audit verdict is journaled before returning
#   M1  repo_merge fails closed without review.reviewer_logins
#   M2  REVIEWERS env cannot substitute for reviewer_logins
#   M3  configured reviewers reach the approval gate (alice missing)
#   M4  approval on a stale head sha does not count
#   M5  approval on head + green required check passes the verdict
#       stage (fails later at verify/release, never at review)
#   M6  pending reviewRequest strips the standing approval
#   M7  required check missing from rollup -> missing_required_checks
#   M8  regular PR bumping the version source -> version_drift
#   M9  full path: on-head approval + green check -> real
#       `gh pr merge --match-head-commit` + post-merge release
#   M10 required checks union: ruleset-only requirement is enforced
#       even when classic protection 404s
#   G8  corrupt gateway counter file fails closed
#   G9  audit keys auto-derive from payload + share/differ correctly
#   G10 global daily audit cap blocks fresh-key spraying
#   CP1 canon_pub refuses to sweep a foreign --canon-root
#   CP2 canon_pub writes the canonical manifest schema
#   PR1 repo_pr_review refuses a stale commit_id
#   PR2/3 a bound commit_id submits pinned to the head
#   R1  release PR with provenance-clean diff skips .changes gate
#   R2  release PR with an out-of-allowlist file is a REGULAR PR
#       (missing_changes_entry blocks it)
#   F1  migration deletion covered by tracked
#       docs/migration_rollforward.md passes in the DEPLOYED layout
#       (canon/ untracked)
#   F2  same deletion without the note fails closed
#
# Exits non-zero if any expectation fails. Run from anywhere:
#   canon/bin/pipeline_tests.sh
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
PRODUCT="$(cd "$CANON_DIR/../../.." && pwd)"   # canon/root/canon -> product root
DEPLOY="$PRODUCT/tools/start_project.sh"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
pass=0; fail=0
expect() { # name expected_rc actual_rc [pattern_in_out_file]
  local name="$1" want="$2" got="$3" pat="${4:-}"
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: expected exit $want, got $got"; fail=$((fail+1)); return
  fi
  if [ -n "$pat" ] && ! grep -q "$pat" "$SCRATCH/out"; then
    echo "FAIL $name: output missing '$pat'"; fail=$((fail+1)); return
  fi
  echo "PASS $name"; pass=$((pass+1))
}

# ---------- D: deploy integrity ------------------------------------
WS="$SCRATCH/ws"
mkdir -p "$WS"
git -C "$WS" init -q -b main 2>/dev/null || { git -C "$WS" init -q && git -C "$WS" symbolic-ref HEAD refs/heads/main; }
git -C "$WS" config user.email t@t; git -C "$WS" config user.name t
git -C "$WS" commit -q --allow-empty -m init

"$DEPLOY" --workspace "$WS" --adapter generic --repo test/pipe \
  --allow-untagged-canon >"$SCRATCH/out" 2>&1
expect D1a-deploy 0 $? "DEPLOY OK"
(cd "$WS" && canon/bin/check_setup.sh) >"$SCRATCH/out" 2>&1
expect D1b-check-setup 0 $? "SETUP OK"

echo bad > "$WS/canon/bin/evil.sh"
(cd "$WS" && canon/bin/check_setup.sh) >"$SCRATCH/out" 2>&1
expect D2-extra-bin-file 1 $?
rm "$WS/canon/bin/evil.sh"

echo bad > "$WS/canon/evil.md"
(cd "$WS" && canon/bin/check_setup.sh) >"$SCRATCH/out" 2>&1
expect D3-extra-root-file 1 $?
rm "$WS/canon/evil.md"

echo "# tampered" >> "$WS/canon/bin/ship_commit.sh"
(cd "$WS" && canon/bin/check_setup.sh) >"$SCRATCH/out" 2>&1
expect D4-tampered-gate 1 $?
git -C "$WS" checkout -- canon/bin/ship_commit.sh 2>/dev/null \
  || cp "$PRODUCT/canon/root/canon/bin/ship_commit.sh" "$WS/canon/bin/ship_commit.sh"
(cd "$WS" && canon/bin/check_setup.sh) >"$SCRATCH/out" 2>&1
expect D4b-restored 0 $? "SETUP OK"

# Pinned adapter hook: canon/tools/* helpers live outside the shipped
# manifest but are sha-pinned in the deploy stamp. Plant one, re-pin
# via a second deploy run, then tamper -> drift must be caught.
mkdir -p "$WS/canon/tools" && printf '#!/bin/sh\necho ok\n' > "$WS/canon/tools/helper.sh" && chmod +x "$WS/canon/tools/helper.sh"
"$DEPLOY" --workspace "$WS" --adapter generic --repo test/pipe \
  --allow-untagged-canon >"$SCRATCH/out" 2>&1
expect D5a-repin-deploy 0 $? "pinned adapter hooks"
echo "# tampered" >> "$WS/canon/tools/helper.sh"
(cd "$WS" && canon/bin/check_setup.sh) >"$SCRATCH/out" 2>&1
expect D5-tampered-hook 1 $? "drifted"
printf '#!/bin/sh\necho ok\n' > "$WS/canon/tools/helper.sh"
(cd "$WS" && canon/bin/check_setup.sh) >"$SCRATCH/out" 2>&1
expect D5b-restored 0 $? "SETUP OK"

mkdir -p "$WS/canon/partner_journal" && echo '{}' > "$WS/canon/partner_journal/x.json"
(cd "$WS" && canon/bin/check_setup.sh) >"$SCRATCH/out" 2>&1
expect D6-runtime-exempt 0 $? "SETUP OK"

# Commit the deploy-written .gitignore onto main: without it a later
# `git add -A` on a branch that lacks the file swallows canon/ into
# the index and `git checkout main` then wipes the deployed tree.
# pyproject.toml gives main a detectable version source (v1.2.2) so
# the version-drift gate has a base to compare against.
(cd "$WS" && git add .gitignore \
  && printf '[project]\nname="pipe"\nversion="1.2.2"\n' > pyproject.toml \
  && git add pyproject.toml \
  && git commit -qm "track .gitignore + version source")

# ---------- G: gateway limits/timeout/journal ----------------------
IMPL="$SCRATCH/partner_impl"
mkdir -p "$IMPL/core"
cat > "$IMPL/core/server.py" <<'PY'
import os, time
class PartnerMCPServer:
    def __init__(self, partner_id=None): self.partner_id = partner_id
    def call_tool(self, tool, args):
        if tool == "sleep":
            time.sleep(float(args.get("seconds", 10)))
            return "slept"
        return {"ok": True, "partner": self.partner_id, "tool": tool}
PY

PC="$WS/canon/bin/partner_call.sh"
PJ="$WS/canon/partner_journal"
CNTR="$WS/canon/gateway_counters.json"
export PARTNER_IMPL_DIR="$IMPL"

PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --args '{"api_key": "sk-1234567890abcdefghij1234567890"}' \
  >"$SCRATCH/out" 2>&1
expect G1-secret-refused 3 $? "REFUSED"

# Policy default audit_max_per_key=20. Seed counter at the limit, then
# try to raise it via env: must still refuse at 20.
echo '{"audit:k":20}' > "$CNTR"
GATEWAY_AUDIT_MAX=9999 PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --audit-key k --class audit --args '{}' >"$SCRATCH/out" 2>&1
expect G2-env-cannot-raise 4 $? "iteration limit"

# Tightening is allowed: seed below policy but at env limit.
echo '{"audit:k":5}' > "$CNTR"
GATEWAY_AUDIT_MAX=5 PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --audit-key k --class audit --args '{}' >"$SCRATCH/out" 2>&1
expect G3-env-tightens 4 $? "iteration limit"

# Consult daily limit via env tighten: one call passes, next refused.
rm -f "$CNTR"
GATEWAY_CONSULT_DAILY_MAX=1 PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --args '{}' >"$SCRATCH/out" 2>&1
expect G4a-first-consult-ok 0 $?
GATEWAY_CONSULT_DAILY_MAX=1 PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --args '{}' >"$SCRATCH/out" 2>&1
expect G4b-second-refused 4 $? "quota_limited"

# Concurrency: 10 parallel audit calls under the policy limit must all
# be counted exactly (flock on the counter file).
rm -f "$CNTR"
for i in $(seq 1 10); do
  PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
    --audit-key conc --class audit --args '{}' >/dev/null 2>&1 &
done
wait
N=$(python3 -c 'import json;print(json.load(open("'$CNTR'"))["audit:conc"])')
[ "$N" = "10" ] && { echo "PASS G5-flock-counted"; pass=$((pass+1)); } \
  || { echo "FAIL G5-flock-counted: counter=$N, expected 10"; fail=$((fail+1)); }

# Timeout: policy call_timeout_seconds=1, partner sleeps 5s -> refused.
python3 - "$WS/canon/config/policy.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["gateway"]["call_timeout_seconds"] = 1
json.dump(d, open(p, "w"), indent=1)
PY
PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool sleep \
  --args '{"seconds":5}' >"$SCRATCH/out" 2>&1
expect G6-timeout 4 $? "upstream_timeout"
python3 - "$WS/canon/config/policy.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["gateway"]["call_timeout_seconds"] = 300
json.dump(d, open(p, "w"), indent=1)
PY

# Journal: a successful call must leave a journal entry.
BEFORE=$(ls "$PJ" 2>/dev/null | wc -l)
PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --audit-key j --class audit --args '{}' >"$SCRATCH/out" 2>&1
AFTER=$(ls "$PJ" 2>/dev/null | wc -l)
[ "$AFTER" -gt "$BEFORE" ] && { echo "PASS G7-journaled"; pass=$((pass+1)); } \
  || { echo "FAIL G7-journaled"; fail=$((fail+1)); }

# ---------- M/R: repo_merge via a fake gh --------------------------
FAKEBIN="$SCRATCH/fakebin"; mkdir -p "$FAKEBIN"
# Fake gh: answers every call repo_merge makes with canned data.
# Scripted via FAKEGH_STATE files so each test tunes the PR head/branch.
cat > "$FAKEBIN/fakegh" <<'SH'
#!/usr/bin/env bash
# Faithful-enough gh: canned RAW JSON per endpoint + the --jq filters
# repo_merge relies on. Without --jq handling every check silently
# flips fail-closed and tests could never reach past the review gate.
set -uo pipefail
S="${FAKEGH_STATE:?}"
# Log merge invocations verbatim (before flag stripping) - the gate's
# --match-head-commit binding is what we are testing.
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then
  printf '%s\n' "$*" >> "$S/merge_calls"
fi
METHOD=""; JQ=""; INPUT_F=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) JQ="$2"; shift 2 ;;
    --paginate|--squash|--merge|--rebase|--delete-branch|--auto|--draft) shift ;;
    --match-head-commit|--subject|--body|-t|-b|-X) [ "$1" = "-X" ] && METHOD="$2"; shift 2 ;;
    --input) INPUT_F="$2"; [ "$INPUT_F" = "-" ] && cat > "$S/post_body"; shift 2 ;;
    --json|--fields|--field|-f|-F|-H) shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"
RAW='{}'
case "$1" in
  api)
    url="${2:-}"
    case "$url" in
      *protection/required_status_checks*)
        if [ -f "$S/protection_contexts" ]; then
          RAW=$(python3 -c 'import json,sys
print(json.dumps({"contexts": json.load(open(sys.argv[1]))}))' "$S/protection_contexts")
        else
          echo "HTTP 404: Branch not protected" >&2; exit 1
        fi ;;
      *rulesets/*)
        rid="${url##*rulesets/}"; RAW=$(cat "$S/ruleset_$rid.json" 2>/dev/null || echo '{}') ;;
      *rulesets*)
        RAW=$(cat "$S/rulesets.json" 2>/dev/null || echo '[]') ;;
      */reviews*)
        if [ "$METHOD" = "POST" ]; then
          f="$INPUT_F"; [ "$f" = "-" ] && f="$S/post_body"
          cat "$f" >> "$S/review_posts.jsonl" 2>/dev/null || true
          RAW='{"id":1}'
        else
          RAW=$(cat "$S/reviews.json" 2>/dev/null || echo '[]')
        fi ;;
      *) RAW='[]' ;;
    esac ;;
  repo)
    RAW='{"defaultBranchRef":{"name":"main"}}' ;;
  pr)
    case "${2:-}" in
      view) RAW=$(cat "$S/pr_view.json") ;;
      list) RAW='[]' ;;
      create) RAW='"https://example/pr/7"' ;;
      merge)
        if [ "${FAKEGH_MERGE_FAIL:-0}" = "1" ]; then
          echo "the pull request is not mergeable" >&2; exit 1
        fi
        # Apply the merge: land the PR head on the base ref on the
        # remote so the post-merge release sees the merged fragments.
        python3 - "$S/pr_view.json" "$FAKEGH_REPO" <<'PY' || {
import json, subprocess, sys
d = json.load(open(sys.argv[1]))
subprocess.run(["git", "-C", sys.argv[2], "push", "-q", "origin",
                d["headRefOid"] + ":refs/heads/" + d["baseRefName"]],
               check=True)
PY
          echo "merge apply failed" >&2; exit 1; }
        RAW='"merged"' ;;
      *) RAW='[]' ;;
    esac ;;
  release)
    case "${2:-}" in
      view) echo "release not found" >&2; exit 1 ;;
      create) printf '%s\n' "$*" >> "$S/release_calls"; RAW='"created"' ;;
      *) RAW='[]' ;;
    esac ;;
  issue)
    case "${2:-}" in
      view)
        # per-number state map: $S/issues.json {"<num>":{"state":"..."}};
        # unknown numbers default to OPEN (existence never fails).
        RAW=$(python3 -c 'import json,os,sys
n = sys.argv[2]
st = {}
p = os.path.join(sys.argv[1], "issues.json")
if os.path.exists(p):
    st = json.load(open(p))
d = st.get(str(n)) or st.get(int(n)) or {}
print(json.dumps({"number": int(n), "state": d.get("state", "open")}))' "$S" "${3:-0}") ;;
      *) RAW='{"number":1,"state":"open"}' ;;
    esac ;;
  *) echo "fakegh: unhandled $*" >&2; exit 1 ;;
esac
if [ -n "$JQ" ]; then
  printf '%s' "$RAW" | JQ="$JQ" python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read() or "null")
jq = os.environ["JQ"]
if jq.startswith("[.contexts[]?"):
    ctx = list((d or {}).get("contexts") or [])
    ctx += [c.get("context") for c in (d or {}).get("checks") or [] if c.get("context")]
    print("\n".join(sorted(set(ctx))))
elif jq == ".[] | @json":
    for it in (d or []):
        print(json.dumps(it))
elif jq.startswith(".labels"):
    for it in (d or {}).get("labels") or []:
        print(it.get("name") or "")
else:
    cur = d
    for k in jq.lstrip(".").split("."):
        cur = cur.get(k) if isinstance(cur, dict) else None
    print(json.dumps(cur) if isinstance(cur, (dict, list)) else ("" if cur is None else cur))
'
else
  printf '%s\n' "$RAW"
fi
exit 0
SH
chmod +x "$FAKEBIN/fakegh"
# verify_constraints/repo_release call a BARE `gh` inside blood-sign
# and the release step - the same fake answers both names.
cp "$FAKEBIN/fakegh" "$FAKEBIN/gh" && chmod +x "$FAKEBIN/gh"

GHSTATE="$SCRATCH/ghstate"; mkdir -p "$GHSTATE"
echo '[]' > "$GHSTATE/reviews.json"   # array of review objects
echo '[]' > "$GHSTATE/rulesets.json"

# A second scratch repo acting as the "github remote" (local path whose
# string contains github.com so repo_merge's remote regex matches).
GHREMOTE="$SCRATCH/github.com/test/pipe"
git -C "$WS" remote add origin "$GHREMOTE" 2>/dev/null || true
mkdir -p "$GHREMOTE" && git -C "$GHREMOTE" init -q --bare
git -C "$WS" push -q origin main 2>/dev/null

# project.json gets review.gh_bin=fakegh but NO reviewer_logins -> M1.
python3 - "$WS/canon/project.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["review"] = {"gh_bin": "fakegh"}
json.dump(d, open(p, "w"), indent=1)
PY
HEADSHA=$(cd "$WS" && git rev-parse main)
printf '{"headRefOid":"%s","headRefName":"feature/x","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"","reviewRequests":[]}' "$HEADSHA" > "$GHSTATE/pr_view.json"
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$HEADSHA" squash) >"$SCRATCH/out" 2>&1
expect M1-no-reviewers 1 $? "no reviewers configured"

(cd "$WS" && env REVIEWERS=alice FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$HEADSHA" squash) >"$SCRATCH/out" 2>&1
expect M2-env-no-substitute 1 $? "no reviewers configured"

# A PR branch that can pass the .changes entry gate: the approval
# gate sits AFTER it, so fragment-less PRs never reach the review
# verdict. issue_42-fix carries a bump fragment.
(cd "$WS" && git checkout -q -b issue_42-fix main \
  && mkdir -p .changes && printf 'bump: patch\nissue: 42\n\nfix\n' > .changes/fix.md \
  && git add -A && git commit -qm "fix" \
  && git push -q origin issue_42-fix)
FIXSHA=$(cd "$WS" && git rev-parse issue_42-fix)
printf '{"headRefOid":"%s","headRefName":"issue_42-fix","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"closes #42","reviewRequests":[]}' "$FIXSHA" > "$GHSTATE/pr_view.json"
echo '["ci"]' > "$GHSTATE/protection_contexts"

# Configure reviewers in project.json -> binding check passes; gate
# must now fail LATER at the APPROVAL gate, naming alice as missing.
python3 - "$WS/canon/project.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["review"]["reviewer_logins"] = ["alice"]
json.dump(d, open(p, "w"), indent=1)
PY
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$FIXSHA" squash) >"$SCRATCH/out" 2>&1
expect M3a-binding-ok 1 $? "missing_approvals"
grep -q '"alice"' "$SCRATCH/out" \
  && { echo "PASS M3b-names-reviewer"; pass=$((pass+1)); } \
  || { echo "FAIL M3b-names-reviewer"; fail=$((fail+1)); }

# Stale-head approval must NOT count: alice APPROVED a different sha.
python3 - "$GHSTATE/reviews.json" <<'PY'
import json, sys
json.dump([{"user": {"login": "alice"}, "id": 7, "state": "APPROVED",
            "commit_id": "0" * 40, "submitted_at": "2026-01-01T00:00:00Z"}],
          open(sys.argv[1], "w"))
PY
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$FIXSHA" squash) >"$SCRATCH/out" 2>&1
expect M4-stale-approval 1 $? "gate_blocked"

# Approved ON the head + a green required check -> must get PAST the
# review/check gates into the later stages (version drift, blood-sign,
# or the merge itself). Proves the verdict path is reachable.
python3 - "$GHSTATE/reviews.json" "$FIXSHA" <<'PY'
import json, sys
json.dump([{"user": {"login": "alice"}, "id": 7, "state": "APPROVED",
            "commit_id": sys.argv[2], "submitted_at": "2026-01-01T00:00:00Z"}],
          open(sys.argv[1], "w"))
PY
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$FIXSHA" squash) >"$SCRATCH/out" 2>&1
if grep -q 'missing_approvals\|"approved":false' "$SCRATCH/out"; then
  echo "FAIL M5-past-review-gate: $SCRATCH/out"; fail=$((fail+1))
elif grep -q 'verify_failed\|version_source_missing\|merged\|release' "$SCRATCH/out"; then
  echo "PASS M5-past-review-gate"; pass=$((pass+1))
else
  echo "FAIL M5-past-review-gate: unexpected $(cat "$SCRATCH/out" | head -3)"; fail=$((fail+1))
fi

# A pending review request on alice strips her standing approval.
python3 - "$GHSTATE/pr_view.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["reviewRequests"] = [{"login": "alice"}]
json.dump(d, open(sys.argv[1], "w"))
PY
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$FIXSHA" squash) >"$SCRATCH/out" 2>&1
expect M6-pending-review 1 $? "gate_blocked"
python3 - "$GHSTATE/pr_view.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["reviewRequests"] = []
json.dump(d, open(sys.argv[1], "w"))
PY

# Required check present in protection but absent from the rollup ->
# missing_required_checks, not a silent pass.
python3 - "$GHSTATE/pr_view.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["statusCheckRollup"] = []
json.dump(d, open(sys.argv[1], "w"))
PY
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$FIXSHA" squash) >"$SCRATCH/out" 2>&1
expect M7-missing-required 1 $? 'missing_required_checks.*ci'
python3 - "$GHSTATE/pr_view.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["statusCheckRollup"] = [{"name": "ci", "conclusion": "SUCCESS"}]
json.dump(d, open(sys.argv[1], "w"))
PY

# Version drift: a regular PR bumping the autodetected version source
# must be blocked even with a valid .changes fragment.
(cd "$WS" && git checkout -q -b issue_7-ver main \
  && printf '[project]\nname="pipe"\nversion="9.9.9"\n' > pyproject.toml \
  && mkdir -p .changes && printf 'bump: patch\nissue: 7\n\nv\n' > .changes/v.md \
  && git add -A && git commit -qm "bump" \
  && git push -q origin issue_7-ver)
VERSHA=$(cd "$WS" && git rev-parse issue_7-ver)
printf '{"headRefOid":"%s","headRefName":"issue_7-ver","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"closes #7","reviewRequests":[]}' "$VERSHA" > "$GHSTATE/pr_view.json"
python3 - "$GHSTATE/reviews.json" "$VERSHA" <<'PY'
import json, sys
json.dump([{"user": {"login": "alice"}, "id": 7, "state": "APPROVED",
            "commit_id": sys.argv[2], "submitted_at": "2026-01-01T00:00:00Z"}],
          open(sys.argv[1], "w"))
PY
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$VERSHA" squash) >"$SCRATCH/out" 2>&1
expect M8-version-drift 1 $? "version_drift"

# Release PR provenance: branch release/v1.2.3, one commit
# "release: v1.2.3", diff = pyproject.toml only (autodetected version
# source). Must pass the .changes gate (-> fails later on reviews).
(cd "$WS" && git checkout -q main \
  && git push -q origin main \
  && git checkout -q -b release/v1.2.3 \
  && printf '[project]\nname="pipe"\nversion="1.2.3"\n' > pyproject.toml \
  && git add pyproject.toml && git commit -qm "release: v1.2.3" \
  && git push -q origin release/v1.2.3)
REL_SHA=$(cd "$WS" && git rev-parse release/v1.2.3)
printf '{"headRefOid":"%s","headRefName":"release/v1.2.3","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"","reviewRequests":[]}' "$REL_SHA" > "$GHSTATE/pr_view.json"
echo '[]' > "$GHSTATE/reviews.json"
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$REL_SHA" squash) >"$SCRATCH/out" 2>&1
# Provenance-clean release PR skips the .changes gate and reaches the
# approval gate (missing_approvals) - not a mere absence of the block.
if grep -q "missing_changes_entry" "$SCRATCH/out"; then
  echo "FAIL R1-release-provenance: blocked as regular PR"; fail=$((fail+1))
elif grep -q "missing_approvals" "$SCRATCH/out"; then
  echo "PASS R1-release-provenance"; pass=$((pass+1))
else
  echo "FAIL R1-release-provenance: unexpected $(head -3 "$SCRATCH/out")"; fail=$((fail+1))
fi

# Same branch shape but the diff also touches src/evil.py -> NOT
# provenance -> treated as regular PR -> missing_changes_entry.
(cd "$WS" && git checkout -q -b release/v9.9.9 main \
  && printf '[project]\nname="pipe"\nversion="9.9.9"\n' > pyproject.toml \
  && mkdir -p src && echo bad > src/evil.py \
  && git add -A && git commit -qm "release: v9.9.9" \
  && git push -q origin release/v9.9.9)
BAD_SHA=$(cd "$WS" && git rev-parse release/v9.9.9)
printf '{"headRefOid":"%s","headRefName":"release/v9.9.9","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"","reviewRequests":[]}' "$BAD_SHA" > "$GHSTATE/pr_view.json"
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$BAD_SHA" squash) >"$SCRATCH/out" 2>&1
expect R2-tainted-release 1 $? "missing_changes_entry"

# M10: rulesets union — classic protection 404s but an active ruleset
# requires check "sec" which the rollup lacks -> missing_required_checks
# must name it (proving the union path was consulted, not just classic).
rm -f "$GHSTATE/protection_contexts"
cat > "$GHSTATE/rulesets.json" <<'JSON'
[{"id":1,"source_type":"Repository","enforcement":"active"}]
JSON
cat > "$GHSTATE/ruleset_1.json" <<'JSON'
{"id":1,"enforcement":"active","target":"branch",
 "conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},
 "rules":[{"type":"required_status_checks",
           "parameters":{"required_status_checks":[{"context":"sec"}]}}]}
JSON
python3 - "$GHSTATE/pr_view.json" "$REL_SHA" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["headRefOid"] = sys.argv[2]
d["headRefName"] = "release/v1.2.3"
d["statusCheckRollup"] = [{"name": "ci", "conclusion": "SUCCESS"}]
json.dump(d, open(sys.argv[1], "w"))
PY
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$REL_SHA" squash) >"$SCRATCH/out" 2>&1
expect M10-ruleset-union 1 $? 'missing_required_checks.*sec'
echo '[]' > "$GHSTATE/rulesets.json"
echo '["ci"]' > "$GHSTATE/protection_contexts"

# ---------- M9: the full path - real merge + release --------------
# A fragment with ALL mandatory fields, an issue-linked branch, an
# on-head approval and a green required check must reach
# `gh pr merge --match-head-commit` and the post-merge release.
(cd "$WS" && git checkout -q -b issue_43-full main \
  && mkdir -p .changes \
  && printf 'bump: patch\nuser_visible: true\nissue: 43\n\nfix\n\n## Spec impact\n- none\n' \
       > .changes/full.md \
  && echo "fix" > fix.txt \
  && git add -A && git commit -qm "fix" \
  && git push -q origin issue_43-full)
FULLSHA=$(cd "$WS" && git rev-parse issue_43-full)
printf '{"headRefOid":"%s","headRefName":"issue_43-full","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"closes #43","reviewRequests":[]}' "$FULLSHA" > "$GHSTATE/pr_view.json"
python3 - "$GHSTATE/reviews.json" "$FULLSHA" <<'PY'
import json, sys
json.dump([{"user": {"login": "alice"}, "id": 9, "state": "APPROVED",
            "commit_id": sys.argv[2], "submitted_at": "2026-01-01T00:00:00Z"}],
          open(sys.argv[1], "w"))
PY
: > "$GHSTATE/merge_calls"
(cd "$WS" && env FAKEGH_REPO="$WS" FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 43 "$FULLSHA" squash) >"$SCRATCH/out" 2>&1
expect M9a-merge-ok 0 $? '"status": "merged"'
grep -q -- "--match-head-commit $FULLSHA" "$GHSTATE/merge_calls" \
  && { echo "PASS M9b-bound-merge-call"; pass=$((pass+1)); } \
  || { echo "FAIL M9b-bound-merge-call: $(cat "$GHSTATE/merge_calls")"; fail=$((fail+1)); }
grep -q '"release"' "$SCRATCH/out" \
  && { echo "PASS M9c-release-ran"; pass=$((pass+1)); } \
  || { echo "FAIL M9c-release-ran"; fail=$((fail+1)); }

# ---------- M10: fragment issue: correspondence --------------------
# A fragment whose issue: field names another issue is blocked at
# the entry gate - before any review verdict is consulted.
(cd "$WS" && git checkout -q -b issue_44-mismatch main \
  && mkdir -p .changes \
  && printf 'bump: patch\nissue: 99\n\nx\n' > .changes/x.md \
  && git add -A && git commit -qm "x" \
  && git push -q origin issue_44-mismatch)
MISSHA=$(cd "$WS" && git rev-parse issue_44-mismatch)
printf '{"headRefOid":"%s","headRefName":"issue_44-mismatch","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"closes #44","reviewRequests":[]}' "$MISSHA" > "$GHSTATE/pr_view.json"
(cd "$WS" && env FAKEGH_REPO="$WS" FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 44 "$MISSHA" squash) >"$SCRATCH/out" 2>&1
expect M10a-issue-mismatch 1 $? "issue_mismatch"
# and a fragment without the mandatory issue: field at all
(cd "$WS" && git checkout -q -b issue_45-noissue main \
  && mkdir -p .changes \
  && printf 'bump: patch\n\nx\n' > .changes/x.md \
  && git add -A && git commit -qm "x" \
  && git push -q origin issue_45-noissue)
NOISSHA=$(cd "$WS" && git rev-parse issue_45-noissue)
printf '{"headRefOid":"%s","headRefName":"issue_45-noissue","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"closes #45","reviewRequests":[]}' "$NOISSHA" > "$GHSTATE/pr_view.json"
(cd "$WS" && env FAKEGH_REPO="$WS" FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 45 "$NOISSHA" squash) >"$SCRATCH/out" 2>&1
expect M10b-missing-issue 1 $? "missing_issue_field"

# ---------- M11: task -> epic merge releases nothing ---------------
# A merge into a NON-default base (task branch into the epic branch)
# is integration work: it merges, but Release-on-Merge does not run -
# no bump, no tag.
# canon/roadmap.md is a deployed working doc (canon/ is gitignored
# in the workspace) - the completeness gate reads the live copy.
printf '## Item: feature\n- id: feature\n- type: epic\n- issue: 9\n- tasks: [10]\n\n## Item: pay\n- id: pay\n- type: epic\n- issue: 12\n- tasks: [13, 14]\n\n## Item: mix\n- id: mix\n- type: epic\n- issue: 15\n- tasks: [16]\n' > "$WS/canon/roadmap.md"
(cd "$WS" && git checkout -q -b epic_issue_9-feature main \
  && git push -q origin epic_issue_9-feature \
  && git checkout -q -b issue_10-auth epic_issue_9-feature \
  && mkdir -p .changes \
  && printf 'bump: patch\nuser_visible: true\nissue: 10\n\nauth task\n\n## Spec impact\n- none\n' > .changes/auth.md \
  && git add -A && git commit -qm "auth" \
  && git push -q origin issue_10-auth)
TASKSHA=$(cd "$WS" && git rev-parse issue_10-auth)
printf '{"headRefOid":"%s","headRefName":"issue_10-auth","baseRefName":"epic_issue_9-feature","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"closes #10","reviewRequests":[]}' "$TASKSHA" > "$GHSTATE/pr_view.json"
python3 - "$GHSTATE/reviews.json" "$TASKSHA" <<'PY'
import json, sys
json.dump([{"user": {"login": "alice"}, "id": 11, "state": "APPROVED",
            "commit_id": sys.argv[2], "submitted_at": "2026-01-01T00:00:00Z"}],
          open(sys.argv[1], "w"))
PY
TAGS_BEFORE=$(cd "$WS" && git tag | wc -l)
(cd "$WS" && env FAKEGH_REPO="$WS" FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 10 "$TASKSHA" squash) >"$SCRATCH/out" 2>&1
expect M11a-epic-merge-ok 0 $? '"status": "merged"'
grep -q 'non_default_base' "$SCRATCH/out" \
  && { echo "PASS M11b-release-skipped"; pass=$((pass+1)); } \
  || { echo "FAIL M11b-release-skipped: $(cat "$SCRATCH/out")"; fail=$((fail+1)); }
[ "$(cd "$WS" && git tag | wc -l)" = "$TAGS_BEFORE" ] \
  && { echo "PASS M11c-no-tag"; pass=$((pass+1)); } \
  || { echo "FAIL M11c-no-tag: tag created on epic merge"; fail=$((fail+1)); }

# M11d: the epic branch itself (epic_issue_9-feature) merges into
# the default branch and RELEASES - carrying the task fragment
# (issue: 10) which is legal because the epic PR body references
# both #9 and #10 - the task issue enters the fragments' allowed
# set via FRAG_ISSUES ("includes #10" is a mention, not a close).
# The epic is first rebased onto the advanced
# origin/main - the version_drift gate blocks a stale epic head
# (base moved to 1.2.3 via M9's release while the epic carries
# 1.2.2): the epic must be synced before it can merge for release.
(cd "$WS" && git fetch -q origin \
  && git checkout -q -B epic_issue_9-feature origin/epic_issue_9-feature \
  && git rebase -q origin/main \
  && git push -q --force-with-lease origin epic_issue_9-feature)
EPICSHA=$(cd "$WS" && git rev-parse epic_issue_9-feature)
# Convention: the task issue is CLOSED by the repository agent once
# the task lands on the epic branch - the epic completeness gate
# requires CLOSED state for every declared task.
printf '{"10":{"state":"CLOSED"}}' > "$GHSTATE/issues.json"
printf '{"headRefOid":"%s","headRefName":"epic_issue_9-feature","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"closes #9\\nincludes #10","reviewRequests":[]}' "$EPICSHA" > "$GHSTATE/pr_view.json"
python3 - "$GHSTATE/reviews.json" "$EPICSHA" <<'PY'
import json, sys
json.dump([{"user": {"login": "alice"}, "id": 12, "state": "APPROVED",
            "commit_id": sys.argv[2], "submitted_at": "2026-01-01T00:00:00Z"}],
          open(sys.argv[1], "w"))
PY
(cd "$WS" && env FAKEGH_REPO="$WS" FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 9 "$EPICSHA" squash) >"$SCRATCH/out" 2>&1
rc=$?; [ $rc -ne 0 ] && cat "$SCRATCH/out" >&2
expect M11d-epic-releases 0 $rc '"status": "merged"'

# M11e: a body that REFERENCES an issue without closing it must not
# require a 'Closes #N' link for the mention - FRAG_ISSUES feeds the
# fragment allowed set only, ISSUE_NUMS keeps the close contract.
(cd "$WS" && git fetch -q origin \
  && git checkout -q -b issue_46-mention origin/main \
  && mkdir -p .changes \
  && printf 'bump: patch\nuser_visible: true\nissue: 46\n\ny\n\n## Spec impact\n- none\n' > .changes/y.md \
  && git add -A && git commit -qm "y" \
  && git push -q origin issue_46-mention)
MENTSHA=$(cd "$WS" && git rev-parse issue_46-mention)
printf '{"headRefOid":"%s","headRefName":"issue_46-mention","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"closes #46\\nsee also discussion in #20","reviewRequests":[]}' "$MENTSHA" > "$GHSTATE/pr_view.json"
python3 - "$GHSTATE/reviews.json" "$MENTSHA" <<'PY'
import json, sys
json.dump([{"user": {"login": "alice"}, "id": 13, "state": "APPROVED",
            "commit_id": sys.argv[2], "submitted_at": "2026-01-01T00:00:00Z"}],
          open(sys.argv[1], "w"))
PY
(cd "$WS" && env FAKEGH_REPO="$WS" FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 46 "$MENTSHA" squash) >"$SCRATCH/out" 2>&1
expect M11e-unclosed-mention-ok 0 $? '"status": "merged"'

# M11f: epic completeness gate - a declared task that was never
# shipped (no fragment on the epic branch) blocks the epic merge
# with epic_incomplete before any merge mechanics run.
(cd "$WS" && git fetch -q origin \
  && git checkout -q -b epic_issue_12-pay origin/main \
  && git push -q origin epic_issue_12-pay)
PAYSHA=$(cd "$WS" && git rev-parse epic_issue_12-pay)
printf '{"headRefOid":"%s","headRefName":"epic_issue_12-pay","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"closes #12","reviewRequests":[]}' "$PAYSHA" > "$GHSTATE/pr_view.json"
(cd "$WS" && env FAKEGH_REPO="$WS" FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 12 "$PAYSHA" squash) >"$SCRATCH/out" 2>&1
expect M11f-epic-incomplete 1 $? "epic_incomplete"
# and a task that shipped but whose issue was never closed also
# blocks: completeness is fragment AND tracker state.
(cd "$WS" && git fetch -q origin \
  && git checkout -q -b epic_issue_15-mix origin/main \
  && mkdir -p .changes \
  && printf 'bump: patch\nuser_visible: true\nissue: 16\n\nz\n\n## Spec impact\n- none\n' > .changes/z.md \
  && git add -A && git commit -qm "epic + task fragment" \
  && git push -q origin epic_issue_15-mix)
MIXSHA=$(cd "$WS" && git rev-parse epic_issue_15-mix)
printf '{"headRefOid":"%s","headRefName":"epic_issue_15-mix","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"closes #15","reviewRequests":[]}' "$MIXSHA" > "$GHSTATE/pr_view.json"
(cd "$WS" && env FAKEGH_REPO="$WS" FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 15 "$MIXSHA" squash) >"$SCRATCH/out" 2>&1
expect M11g-epic-open-task 1 $? "not CLOSED"

# ---------- G8/G9: counter integrity + audit-key derivation --------
echo 'not json' > "$CNTR"
PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --audit-key k --class audit --args '{}' >"$SCRATCH/out" 2>&1
expect G8-corrupt-counters 4 $? "unreadable"

rm -f "$CNTR"
PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --class audit --args '{"a":1}' >/dev/null 2>&1
PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --class audit --args '{"a":1}' >/dev/null 2>&1
PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --class audit --args '{"b":2}' >/dev/null 2>&1
python3 - "$CNTR" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
auto = {k: v for k, v in c.items() if k.startswith("audit:auto:")}
day = [v for k, v in c.items() if k.startswith("audit_day:")]
assert len(auto) == 2, f"expected 2 distinct auto keys, got {auto}"
assert sorted(auto.values()) == [1, 2], f"same payload must share one budget: {auto}"
assert day == [3], f"global daily counter must total 3: {c}"
print("ok")
PY
[ $? -eq 0 ] && { echo "PASS G9-auto-key-derivation"; pass=$((pass+1)); } \
  || { echo "FAIL G9-auto-key-derivation"; fail=$((fail+1)); }

# Global daily cap: seed the day counter at the policy ceiling ->
# refused even with a fresh audit key.
python3 - "$CNTR" <<'PY'
import datetime, json, sys
c = json.load(open(sys.argv[1]))
c[f"audit_day:{datetime.date.today().isoformat()}"] = 100
json.dump(c, open(sys.argv[1], "w"))
PY
PARTNER_IMPL_DIR="$IMPL" "$PC" --partner acme --tool t \
  --class audit --args '{"fresh":true}' >"$SCRATCH/out" 2>&1
expect G10-daily-cap 4 $? "quota_limited"
rm -f "$CNTR"

# ---------- CP: canon_pub sweep guard + schema ---------------------
# A foreign non-empty --canon-root must be refused BEFORE the stale
# sweep touches it (needs a valid signed envelope to reach stage 5).
CAND="$SCRATCH/candidate"; mkdir -p "$CAND/canon/specs" "$CAND/canon/bin"
cp "$PRODUCT/canon/root/canon/RULES.md" "$CAND/canon/RULES.md"
cp "$PRODUCT/canon/root/canon/specs/harness.md" "$CAND/canon/specs/harness.md"
cp "$PRODUCT/canon/root/canon/bin/check_setup.sh" "$CAND/canon/bin/check_setup.sh"
FOREIGN="$SCRATCH/foreign"; mkdir -p "$FOREIGN/docs" && echo x > "$FOREIGN/docs/keep.md"
ENVF="$SCRATCH/env.json"
export CANON_HUMAN_KEY="test-human-key"
python3 - "$CAND" "$ENVF" <<'PY'
import datetime, hashlib, hmac, json, pathlib, sys, os
cand = pathlib.Path(sys.argv[1])
entries = []
for p in sorted(cand.rglob("*")):
    if p.is_file():
        entries.append((p.relative_to(cand).as_posix(),
                        hashlib.sha256(p.read_bytes()).hexdigest()))
tree_sha = hashlib.sha256(
    "".join(f"{r}={s}" for r, s in entries).encode()).hexdigest()
ts = datetime.datetime.now(datetime.timezone.utc).isoformat()
payload = f"approve|{tree_sha}|human|{ts}|9.9.9"
sig = hmac.new(os.environ["CANON_HUMAN_KEY"].encode(),
               payload.encode(), hashlib.sha256).hexdigest()
json.dump({"verdict": "approve", "artifact_sha": tree_sha,
           "signed_by": "human", "ts": ts, "sig": sig},
          open(sys.argv[2], "w"))
PY
"$PRODUCT/canon/root/canon/bin/canon_pub.sh" publish \
  --candidate "$CAND" --envelope "$ENVF" --version 9.9.9 \
  --canon-root "$FOREIGN" \
  --manifest "$SCRATCH/pub_manifest.json" \
  --history "$SCRATCH/pub_history.jsonl" >"$SCRATCH/out" 2>&1
expect CP1-foreign-sweep-guard 6 $? "refusing to sweep"
[ -f "$FOREIGN/docs/keep.md" ] \
  && { echo "PASS CP1b-foreign-preserved"; pass=$((pass+1)); } \
  || { echo "FAIL CP1b-foreign-preserved: sweep ran anyway"; fail=$((fail+1)); }

# Happy path: same envelope, proper empty canon-root -> publishes and
# writes a manifest in the canonical schema (canon_version + files +
# sha256 map + canary/gitignore keys preserved).
PUBROOT="$SCRATCH/pubroot"
"$PRODUCT/canon/root/canon/bin/canon_pub.sh" publish \
  --candidate "$CAND" --envelope "$ENVF" --version 9.9.9 \
  --canon-root "$PUBROOT" \
  --manifest "$SCRATCH/pub_manifest.json" \
  --history "$SCRATCH/pub_history.jsonl" >"$SCRATCH/out" 2>&1
expect CP2a-publish-ok 0 $?
python3 - "$SCRATCH/pub_manifest.json" <<'PY' \
  && { echo "PASS CP2b-manifest-schema"; pass=$((pass+1)); } \
  || { echo "FAIL CP2b-manifest-schema"; fail=$((fail+1)); }
import json, sys
m = json.load(open(sys.argv[1]))
assert m.get("canon_version") == "9.9.9", m
assert "canon/RULES.md" in m.get("files", []), m.get("files")
assert isinstance(m.get("sha256"), dict) and m["sha256"].get("canon/RULES.md"), m.get("sha256")
for k in ("canon_home", "canary", "gitignore", "description"):
    assert k in m, f"manifest lost required key {k}: {sorted(m)}"
print("ok")
PY
unset CANON_HUMAN_KEY

# ---------- PR: repo_pr_review commit_id binding -------------------
# JSON-file reviews must bind to the CURRENT head: a stale commit_id
# is refused; a matching/absent one submits bound to the head.
python3 - "$GHSTATE/pr_view.json" "$FIXSHA" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["headRefOid"] = sys.argv[2]
json.dump(d, open(sys.argv[1], "w"))
PY
REV="$SCRATCH/review.json"
printf '{"event":"APPROVE","body":"ok","commit_id":"%s"}' "$(printf '0%.0s' {1..40})" > "$REV"
(cd "$WS" && env GH_BIN=fakegh FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_pr_review.sh --pr 42 --json-file "$REV") >"$SCRATCH/out" 2>&1
expect PR1-stale-commit-id 2 $? "stale_input"

printf '{"event":"APPROVE","body":"ok","commit_id":"%s"}' "$FIXSHA" > "$REV"
: > "$GHSTATE/review_posts.jsonl"
(cd "$WS" && env GH_BIN=fakegh FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_pr_review.sh --pr 42 --json-file "$REV") >"$SCRATCH/out" 2>&1
expect PR2-bound-submit 0 $? '"status": "ok"'
grep -q "\"commit_id\": \"$FIXSHA\"" "$GHSTATE/review_posts.jsonl" \
  && { echo "PASS PR3-submitted-bound"; pass=$((pass+1)); } \
  || { echo "FAIL PR3-submitted-bound: $(cat "$GHSTATE/review_posts.jsonl")"; fail=$((fail+1)); }

# ---------- F: migration rollforward in the deployed layout --------
# canon/ is gitignored in the deployed ws, so coverage comes from a
# TRACKED docs/migration_rollforward.md.
(cd "$WS" && git checkout -q main \
  && mkdir -p db/migrations docs \
  && printf 'CREATE TABLE m(id int);\n-- rollback: DROP TABLE m;\n' > db/migrations/001_up.sql \
  && printf 'db/migrations/001_up.sql\n' > docs/migration_rollforward.md \
  && git add -A && git commit -qm "migrations + rollforward note" \
  && rm db/migrations/001_up.sql && git add -A \
  && canon/bin/migration_gate.sh --check) >"$SCRATCH/out" 2>&1
expect F1-rollforward-docs-path 0 $?

# A second migration deleted without a note entry must fail closed.
(cd "$WS" && git commit -qm "delete 001" \
  && printf 'CREATE TABLE m2(id int);\n-- rollback: DROP TABLE m2;\n' > db/migrations/002_up.sql \
  && git add -A && git commit -qm "second migration" \
  && rm db/migrations/002_up.sql && git add -A \
  && canon/bin/migration_gate.sh --check) >"$SCRATCH/out" 2>&1
expect F2-no-note-blocked 1 $?

echo "---"
echo "pipeline_tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
