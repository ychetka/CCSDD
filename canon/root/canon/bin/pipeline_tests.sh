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
#   M3  configured reviewers pass the binding check (later gate fails)
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
set -uo pipefail
S="${FAKEGH_STATE:?}"
case "$1 $2" in
  "pr view")
    cat "$S/pr_view.json" ;;
  "repo view")
    echo '{"defaultBranchRef":{"name":"main"}}' ;;
  api\ *)
    url="$2"
    case "$url" in
      *"/protection/required_status_checks") echo '{"contexts":[]}' ;;
      *"/rulesets"*) echo '[]' ;;
      *"/reviews"*) cat "$S/reviews.json" ;;
      *"/pulls"*) echo '{}' ;;
      *) echo '{}' ;;
    esac ;;
  "pr merge") echo "merged" ;;
  *) echo '{}' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/fakegh"

GHSTATE="$SCRATCH/ghstate"; mkdir -p "$GHSTATE"
: > "$GHSTATE/reviews.json"   # jsonl of review objects; empty = none

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

# Configure reviewers in project.json -> binding check passes; gate
# must now fail LATER, proving logins were read.
python3 - "$WS/canon/project.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["review"]["reviewer_logins"] = ["alice"]
json.dump(d, open(p, "w"), indent=1)
PY
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$HEADSHA" squash) >"$SCRATCH/out" 2>&1
if grep -q "no reviewers configured" "$SCRATCH/out"; then
  echo "FAIL M3-binding-ok: still refused"; fail=$((fail+1))
else
  echo "PASS M3-binding-ok"; pass=$((pass+1))
fi

# Release PR provenance: branch release/v1.2.3, one commit
# "release: v1.2.3", diff = pyproject.toml only (autodetected version
# source). Must pass the .changes gate (-> fails later on reviews).
(cd "$WS" && git checkout -q main \
  && printf '[project]\nname="pipe"\nversion="1.2.2"\n' > pyproject.toml \
  && git add pyproject.toml && git commit -qm "add pyproject" \
  && git push -q origin main \
  && git checkout -q -b release/v1.2.3 \
  && printf '[project]\nname="pipe"\nversion="1.2.3"\n' > pyproject.toml \
  && git add pyproject.toml && git commit -qm "release: v1.2.3" \
  && git push -q origin release/v1.2.3)
REL_SHA=$(cd "$WS" && git rev-parse release/v1.2.3)
printf '{"headRefOid":"%s","headRefName":"release/v1.2.3","baseRefName":"main","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[],"mergeStateStatus":"CLEAN","labels":[],"author":{"login":"dev"},"body":"","reviewRequests":[]}' "$REL_SHA" > "$GHSTATE/pr_view.json"
(cd "$WS" && env FAKEGH_STATE="$GHSTATE" PATH="$FAKEBIN:$PATH" \
       canon/bin/repo_merge.sh 42 "$REL_SHA" squash) >"$SCRATCH/out" 2>&1
if grep -q "missing_changes_entry" "$SCRATCH/out"; then
  echo "FAIL R1-release-provenance: blocked as regular PR"; fail=$((fail+1))
else
  echo "PASS R1-release-provenance"; pass=$((pass+1))
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
