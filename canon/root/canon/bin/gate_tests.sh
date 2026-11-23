#!/usr/bin/env bash
# gate_tests.sh - negative tests for the commit-wrapper gates.
# Proves each gate blocks its bypass path in an isolated scratch repo:
#   T1  scope gate: file outside whitelist is rejected (exit 2)
#   T2  scope gate: dir-prefix whitelist entry allows the file
#   T3  migration gate: uncovered staged migration is rejected (exit 3)
#   T4  migration gate: rollback-covered migration verifies + commits
#   T5  migration gate: coverage lost on edit is blocked on next commit
#   T6  migration gate: rename+strip of a verified migration is blocked
#   T7  migration gate: staged up+down pair verifies via paired coverage
#   T8  migration gate: rollback-only commit passes (its own coverage)
#   T9  re-grounding output is emitted on every call
#   T10 hygiene gate rejects cyrillic message (en-language repo)
#   T11 forged sentinel + fake diff + secret in message is rejected
#   T12 forged sentinel + exempt-path cyrillic in message is rejected
#   T13 basename merely containing "down" is not rollback coverage
#   T14 correctly-hashed forged migration_ok stamp does not unlock gate
#   T15 staged whitelist edit must be the only staged file (exit 2)
#   T15b a whitelist-only commit is allowed
#   T16 unstaged whitelist widening does not bypass the scope gate
#   T17 unstaged whitelist deletion does not disable the scope gate
#   T18 staged whitelist deletion + payload is rejected (exit 2)
#   T19 unstaged symlink at the whitelist path cannot feed fake rules
#   T20 staged whitelist rename + payload is rejected (exit 2)
#   T20b standalone whitelist rename-away and rename-back are allowed
#   T21 a standalone staged whitelist removal is allowed
#   T22 roll-forward note: untracked/wrong-path/.bak-substring rejected,
#       HEAD-tracked own-line path accepted
#   T23 staged migration deletion needs a naming roll-forward note
#   T24 prose rollback comment is not coverage
#   T25 empty paired rollback file is not coverage
#   T26 'task-' wording does not trip the sk- secret rule (exit 0)
#   T27 a real sk- key in staged content is still blocked (exit 2)
#   T28 lockfile added-lines are skipped by hygiene (exit 0)
#   T29 --diff-base cannot be desynced by forged subjects
#   T30 --diff-base on an unresolvable ref fails closed
#   T31 API-key patterns actually fire (xoxb, AKIA, sk- bodies)
#   T32 scope gate inspects the OLD path of a rename too
#   T33 cyrillic under an exempt path (canon/agents/) is allowed
#   T34 malformed project.json fails closed
#   T36 canon/ paths exempt from attribution class only (canon
#       self-trip fix); secret still fires there
#   T35 DRY_RUN_CMD env var is ignored; only the project.json-declared
#       migration_dry_run_cmd runs
#   T37 staged symlink is rejected (mode scan)
#   T38 U+2028 line separator cannot smuggle cyrillic
#   T39 placeholder credential value is not flagged
#   T40 tx.rollback() code line is not rollback coverage
#   T41-T43 cycle_log auth: unauthenticated close/resolve denied,
#       escalated self-close denied, sequential fold reopen works
#   T44-T47 reader_digest: bool range, gap ranges, path mismatch,
#       missing file distinctions
# Exits non-zero if any expectation fails. Run from anywhere:
#   canon/bin/gate_tests.sh
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/repo" "$SCRATCH/canon/bin"
cd "$SCRATCH/repo" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
cp "$CANON_DIR/bin/ship_commit.sh" "$CANON_DIR/bin/migration_gate.sh" \
   "$CANON_DIR/bin/migration_pattern.sh" "$CANON_DIR/bin/hygiene_check.sh" \
   "$CANON_DIR/bin/cycle_log.sh" "$CANON_DIR/bin/reader_digest.sh" \
   "$SCRATCH/canon/bin/"
echo '{"text_language":"en"}' > "$SCRATCH/canon/project.json"

pass=0; fail=0
expect() { # name expected_rc actual_rc [pattern_in_output]
  local name="$1" want="$2" got="$3" pat="${4:-}"
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: expected exit $want, got $got"; fail=$((fail+1)); return
  fi
  if [ -n "$pat" ] && ! grep -q "$pat" "$SCRATCH/out"; then
    echo "FAIL $name: output missing '$pat'"; fail=$((fail+1)); return
  fi
  echo "PASS $name"; pass=$((pass+1))
}

SHIP="$SCRATCH/canon/bin/ship_commit.sh"
GATE="$SCRATCH/canon/bin/migration_gate.sh"
HYG="$SCRATCH/canon/bin/hygiene_check.sh"

# --- T1: scope gate blocks out-of-whitelist staged file
echo 'docs/x.md' > "$SCRATCH/canon/scope_whitelist.txt"
mkdir -p src && echo x > src/evil.py && git add src/evil.py
"$SHIP" "test msg" >"$SCRATCH/out" 2>&1; expect T1-scope-block 2 $? "SCOPE_GATE"
git reset -q

# --- T2: dir-prefix entry allows the file
printf 'src/\ndocs/x.md\n' > "$SCRATCH/canon/scope_whitelist.txt"
git add src/evil.py
"$SHIP" "test msg" >"$SCRATCH/out" 2>&1; expect T2-scope-prefix 0 $?

# --- T3: migration gate blocks a staged migration with no coverage
rm "$SCRATCH/canon/scope_whitelist.txt"
mkdir -p db/migrations && printf 'CREATE TABLE t(id int);\n' > db/migrations/001_up.sql
git add db/migrations/001_up.sql
"$SHIP" "add migration" >"$SCRATCH/out" 2>&1; expect T3-migration-block 3 $? "MIGRATION_GATE"
git reset -q

# --- T4: rollback-covered migration verifies live and commits
printf 'CREATE TABLE t(id int);\n-- rollback: DROP TABLE t;\n' > db/migrations/001_up.sql
git add db/migrations/001_up.sql
"$GATE" >"$SCRATCH/out" 2>&1; expect T4a-gate-verifies 0 $? "embedded rollback"
"$SHIP" "add migration" >"$SCRATCH/out" 2>&1; expect T4b-commit-ok 0 $?
# The stamp is informational only: it may exist, but is never consulted.
[ -f "$SCRATCH/canon/migration_ok" ] \
  && { echo "PASS T4c-stamp-informational"; pass=$((pass+1)); } \
  || { echo "FAIL T4c-stamp-informational"; fail=$((fail+1)); }

# --- T5: a migration that loses its rollback coverage is blocked on
# the next commit - the gate re-verifies staged blobs live each time.
printf 'ALTER TABLE t ADD COLUMN c int;\n' > db/migrations/001_up.sql
git add db/migrations/001_up.sql
"$SHIP" "change migration" >"$SCRATCH/out" 2>&1; expect T5-coverage-lost 3 $? "MIGRATION_GATE"
git reset -q --hard HEAD 2>/dev/null || git reset -q

# --- T6: rename + strip coverage cannot smuggle a migration - the
# gate verifies staged blob content, not the pre-edit filename.
git mv db/migrations/001_up.sql db/migrations/002_up.sql
printf 'ALTER TABLE t ADD COLUMN c2 int;\n' > db/migrations/002_up.sql
git add db/migrations/002_up.sql
"$SHIP" "rename+strip migration" >"$SCRATCH/out" 2>&1; expect T6-rename-strip-block 3 $? "MIGRATION_GATE"
git reset -q --hard HEAD 2>/dev/null || git reset -q

# --- T7: staged up+down pair verifies via paired-rollback coverage
printf 'CREATE TABLE u(id int);\n' > db/migrations/003_up.sql
printf 'DROP TABLE u;\n' > db/migrations/003_down.sql
git add db/migrations/003_up.sql db/migrations/003_down.sql
"$GATE" >"$SCRATCH/out" 2>&1; expect T7a-paired-verify 0 $? "paired rollback"
"$SHIP" "migration pair" >"$SCRATCH/out" 2>&1; expect T7b-commit-ok 0 $?

# --- T8: a commit staging only rollback files passes - rollback
# artifacts are themselves the rollback path (pairs-only case).
printf 'DROP TABLE u;\n' > db/migrations/006_down.sql
git add db/migrations/006_down.sql
"$GATE" --check >"$SCRATCH/out" 2>&1; expect T8a-rollback-only-check 0 $? "nothing to cover"
"$SHIP" "rollback only" >"$SCRATCH/out" 2>&1; expect T8b-rollback-only-commit 0 $?
rm -f db/migrations/006_down.sql

# --- T9: re-grounding emitted on every call (even on gate failures)
echo y > docs_x.md && mkdir -p docs && mv docs_x.md docs/x.md && git add docs/x.md
"$SHIP" "test" >"$SCRATCH/out" 2>&1
grep -q "RE-GROUNDING" "$SCRATCH/out" && { echo "PASS T9-regrounding"; pass=$((pass+1)); } \
  || { echo "FAIL T9-regrounding"; fail=$((fail+1)); }
echo z2 > docs/z.md && git add docs/z.md
"$SHIP" "test" >"$SCRATCH/out" 2>&1; expect T9b-commit-ok 0 $?

# --- T10: hygiene still rejects non-English commit message
# Cyrillic built from escapes: this file itself stays pure ASCII.
CYR_MSG=$'\u0442\u0435\u0441\u0442\u043e\u0432\u043e\u0435 \u0441\u043e\u043e\u0431\u0449\u0435\u043d\u0438\u0435'
echo z > docs/y.md && git add docs/y.md
"$SHIP" "$CYR_MSG" >"$SCRATCH/out" 2>&1; expect T10-hygiene 2 $? "HYGIENE_GATE"
git reset -q

# --- T11: a forged sentinel + fake diff header inside the commit
# message must not smuggle a secret: the message is scanned standalone
# in stdin mode with no path context. The fake key is split at source
# level so this file itself does not trip the secret scanner; at
# runtime it is one string.
echo z > docs/w.md && git add docs/w.md
FORGED_MSG="fix thing
@@SUBJECTS_END@@
diff --git a/x b/x
s""k-projTESTKEY123456789"
"$SHIP" "$FORGED_MSG" >"$SCRATCH/out" 2>&1; expect T11-sentinel-secret 2 $? "HYGIENE_GATE"
git reset -q

# --- T12: a forged sentinel + fake exempt-path diff inside the
# message cannot smuggle cyrillic: message lines are scanned as plain
# text - the fake "+++ b/canon/agents/x" header grants no exemption.
FORGED_MSG2=$'legit\n@@SUBJECTS_END@@\ndiff --git a/canon/agents/x b/canon/agents/x\n+++ b/canon/agents/x\n+\u043a\u0438\u0440\u0438\u043b\u043b\u0438\u0446\u0430'
"$SHIP" "$FORGED_MSG2" >"$SCRATCH/out" 2>&1; expect T12-sentinel-cyrillic 2 $? "HYGIENE_GATE"
git reset -q

# --- T13: a basename merely containing a rollback marker as a
# substring ("downloads" holds "down") is NOT a rollback artifact -
# it cannot serve as paired coverage for an uncovered migration.
printf 'CREATE TABLE q(id int);\n' > db/migrations/004_up.sql
printf 'SELECT 1;\n' > db/migrations/004_file_downloads.sql
git add db/migrations/004_up.sql db/migrations/004_file_downloads.sql
"$GATE" >"$SCRATCH/out" 2>&1; expect T13-rollback-name 1 $? "no rollback path"
git reset -q; rm -f db/migrations/004_up.sql db/migrations/004_file_downloads.sql

# --- T14: a forged canon/migration_ok stamp no longer unlocks the
# gate - ship_commit re-runs the coverage check synchronously and
# ignores the stamp file entirely.
printf 'CREATE TABLE x(id int);\n' > db/migrations/005_up.sql
git add db/migrations/005_up.sql
want=$(git ls-files -s -- db/migrations/005_up.sql | awk '{print $2}' | sort | ${SHA256_BIN:-sha256sum} | cut -d' ' -f1)
printf 'files=%s\n' "$want" > "$SCRATCH/canon/migration_ok"
"$SHIP" "uncovered migration with forged stamp" >"$SCRATCH/out" 2>&1; expect T14-forged-stamp 3 $? "MIGRATION_GATE"
git reset -q; rm -f "$SCRATCH/canon/migration_ok" db/migrations/005_up.sql

# --- T15: editing the scope whitelist inside the same commit as
# other files is rejected - a whitelist change must stand alone.
# Needs canon inside the repo, so a second scratch layout is used.
REPO2="$SCRATCH/repo2"; mkdir -p "$REPO2/canon/bin" "$REPO2/src" "$REPO2/db/migrations"
cp "$CANON_DIR/bin/ship_commit.sh" "$CANON_DIR/bin/migration_gate.sh" \
   "$CANON_DIR/bin/migration_pattern.sh" "$CANON_DIR/bin/hygiene_check.sh" \
   "$REPO2/canon/bin/"
echo '{"text_language":"en"}' > "$REPO2/canon/project.json"
printf 'docs/\n' > "$REPO2/canon/scope_whitelist.txt"
(cd "$REPO2" && git init -q && git config user.email t@t && git config user.name t \
  && git add . && git commit -qm init)
(cd "$REPO2" && printf 'src/\n' >> canon/scope_whitelist.txt \
  && echo x > src/e.py && git add src/e.py canon/scope_whitelist.txt \
  && "$REPO2/canon/bin/ship_commit.sh" "widen+payload" >"$SCRATCH/out" 2>&1); \
  expect T15-whitelist-selfedit 2 $? "SCOPE_GATE"
(cd "$REPO2" && git reset -q && git add canon/scope_whitelist.txt \
  && "$REPO2/canon/bin/ship_commit.sh" "widen only" >"$SCRATCH/out" 2>&1); \
  expect T15b-whitelist-alone 0 $?

# --- T16: an unstaged whitelist edit must not widen scope - the gate
# evaluates the index version (what is actually committed), so a
# worktree-only widening has no effect on the staged payload.
(cd "$REPO2" && printf 'evil/\n' >> canon/scope_whitelist.txt \
  && mkdir -p evil && echo x > evil/e.py && git add evil/e.py \
  && "$REPO2/canon/bin/ship_commit.sh" "sneak payload" >"$SCRATCH/out" 2>&1); \
  expect T16-unstaged-widen 2 $? "SCOPE_GATE"
(cd "$REPO2" && git checkout -q -- canon/scope_whitelist.txt && git reset -q; rm -rf "$REPO2/evil")

# --- T17: an unstaged deletion of the whitelist must not disable the
# gate - while the blob is still tracked in the index, the index
# version governs and the payload is rejected.
(cd "$REPO2" && rm canon/scope_whitelist.txt \
  && mkdir -p evil && echo x > evil/e.py && git add evil/e.py \
  && "$REPO2/canon/bin/ship_commit.sh" "sneak payload" >"$SCRATCH/out" 2>&1); \
  expect T17-unstaged-delete 2 $? "SCOPE_GATE"
(cd "$REPO2" && git checkout -q -- canon/scope_whitelist.txt && git reset -q; rm -rf "$REPO2/evil")

# --- T18: a staged deletion of the whitelist + payload in one commit
# is rejected - HEAD still owes the pre-deletion rules to the payload
# and the self-edit rule keeps whitelist changes standalone.
(cd "$REPO2" && git rm -q canon/scope_whitelist.txt \
  && mkdir -p evil && echo x > evil/e.py && git add evil/e.py \
  && "$REPO2/canon/bin/ship_commit.sh" "delete+payload" >"$SCRATCH/out" 2>&1); \
  expect T18-staged-delete 2 $? "SCOPE_GATE"
(cd "$REPO2" && git reset -q && git checkout -q -- canon/scope_whitelist.txt; rm -rf "$REPO2/evil")

# --- T19: an unstaged symlink at the whitelist path cannot feed fake
# rules - only the parent dir is canonicalized, so REL_WL still points
# inside the repo and the index version governs.
(cd "$REPO2" && rm canon/scope_whitelist.txt \
  && printf 'evil/\ndocs/\nsrc/\n' > "$SCRATCH/fake_wl" \
  && ln -s "$SCRATCH/fake_wl" canon/scope_whitelist.txt \
  && mkdir -p evil && echo x > evil/e.py && git add evil/e.py \
  && "$REPO2/canon/bin/ship_commit.sh" "sneak payload" >"$SCRATCH/out" 2>&1); \
  expect T19-symlink-leaf 2 $? "SCOPE_GATE"
(cd "$REPO2" && rm -f canon/scope_whitelist.txt \
  && git checkout -q -- canon/scope_whitelist.txt && git reset -q; rm -rf "$REPO2/evil" "$SCRATCH/fake_wl")

# --- T20: a staged rename-away of the whitelist + payload in one
# commit is rejected - --name-only hides the old path, but the index
# lost the blob while HEAD still holds it (structural detection).
(cd "$REPO2" && mkdir -p docs && git mv canon/scope_whitelist.txt docs/renamed_wl.txt \
  && mkdir -p evil && echo x > evil/e.py && git add evil/e.py \
  && "$REPO2/canon/bin/ship_commit.sh" "rename+payload" >"$SCRATCH/out" 2>&1); \
  expect T20-staged-rename 2 $? "SCOPE_GATE"
(cd "$REPO2" && git reset -q && git checkout -q -- canon/scope_whitelist.txt; \
  rm -f "$REPO2/docs/renamed_wl.txt"; rm -rf "$REPO2/evil")

# --- T20b: standalone whitelist renames are allowed - each is a
# visible, reviewable commit (rename-away, then rename-back).
(cd "$REPO2" && git mv canon/scope_whitelist.txt docs/renamed_wl.txt \
  && "$REPO2/canon/bin/ship_commit.sh" "rename whitelist" >"$SCRATCH/out" 2>&1); \
  expect T20b-rename-alone 0 $?
(cd "$REPO2" && git mv docs/renamed_wl.txt canon/scope_whitelist.txt \
  && "$REPO2/canon/bin/ship_commit.sh" "rename whitelist back" >"$SCRATCH/out" 2>&1); \
  expect T20c-rename-back 0 $?

# --- T21: a standalone staged whitelist removal is allowed - the
# deletion is visible as its own reviewable commit (opt-in boundary).
(cd "$REPO2" && git rm -q canon/scope_whitelist.txt \
  && "$REPO2/canon/bin/ship_commit.sh" "remove whitelist" >"$SCRATCH/out" 2>&1); \
  expect T21-whitelist-remove-alone 0 $?

# --- T22: the roll-forward note binds only when it is tracked in
# HEAD AND lists the covered repo-relative path on its own line.
NOTE="$REPO2/canon/migration_rollforward.md"
(cd "$REPO2" && printf 'CREATE TABLE n(id int);\n' > db/migrations/007_up.sql \
  && git add db/migrations/007_up.sql)
# Worktree-only note (untracked): not reviewed, covers nothing.
printf 'db/migrations/007_up.sql\n' > "$NOTE"
(cd "$REPO2" && ./canon/bin/migration_gate.sh) >"$SCRATCH/out" 2>&1
expect T22a-untracked-note 1 $? "no rollback path"
# Tracked in HEAD but naming a different path: covers nothing.
printf 'db/migrations/099_other.sql\n' > "$NOTE"
(cd "$REPO2" && git add canon/migration_rollforward.md \
  && git commit -qm "note" -- canon/migration_rollforward.md)
(cd "$REPO2" && ./canon/bin/migration_gate.sh) >"$SCRATCH/out" 2>&1
expect T22b-wrong-path-note 1 $? "no rollback path"
# A .bak substring must not cover the real file (whole-line match).
printf 'db/migrations/007_up.sql.bak\n' > "$NOTE"
(cd "$REPO2" && git add canon/migration_rollforward.md \
  && git commit -qm "note" -- canon/migration_rollforward.md)
(cd "$REPO2" && ./canon/bin/migration_gate.sh) >"$SCRATCH/out" 2>&1
expect T22c-bak-substring 1 $? "no rollback path"
# HEAD-tracked note listing the exact path on its own line: covered.
printf 'roll-forward approvals:\ndb/migrations/007_up.sql\n' > "$NOTE"
(cd "$REPO2" && git add canon/migration_rollforward.md \
  && git commit -qm "note" -- canon/migration_rollforward.md)
(cd "$REPO2" && ./canon/bin/migration_gate.sh) >"$SCRATCH/out" 2>&1
expect T22d-bound-note 0 $? "roll-forward"
(cd "$REPO2" && ./canon/bin/ship_commit.sh "rollforward 007" >"$SCRATCH/out" 2>&1); \
  expect T22e-commit-ok 0 $?

# --- T23: a staged migration DELETION is covered only by the
# HEAD-tracked note naming the deleted path.
(cd "$REPO2" && printf 'CREATE TABLE d(id int);\n-- rollback: DROP TABLE d;\n' \
    > db/migrations/008_up.sql && git add db/migrations/008_up.sql \
  && ./canon/bin/ship_commit.sh "add 008" >"$SCRATCH/out" 2>&1); \
  expect T23a-covered-add 0 $?
(cd "$REPO2" && git rm -q db/migrations/008_up.sql \
  && ./canon/bin/migration_gate.sh) >"$SCRATCH/out" 2>&1
expect T23b-delete-blocked 1 $? "no rollback path\|roll-forward"
(cd "$REPO2" && ./canon/bin/ship_commit.sh "drop 008" >"$SCRATCH/out" 2>&1); \
  expect T23c-ship-blocked 3 $? "MIGRATION_GATE"
printf 'db/migrations/008_up.sql\n' > "$NOTE"
(cd "$REPO2" && git add canon/migration_rollforward.md \
  && git commit -qm "note" -- canon/migration_rollforward.md)
(cd "$REPO2" && ./canon/bin/migration_gate.sh) >"$SCRATCH/out" 2>&1
expect T23d-note-covers-delete 0 $? "roll-forward"
(cd "$REPO2" && ./canon/bin/ship_commit.sh "drop 008" >"$SCRATCH/out" 2>&1); \
  expect T23e-delete-commit-ok 0 $?

# --- T24: a passing comment mentioning "rollback" is not coverage -
# the keyword must act as a directive (':'/'('/'=' follows) or be a
# "down" word inside a comment line.
printf 'CREATE TABLE c(countdown int);\n-- no rollback needed\n' > db/migrations/004_prose.sql
git add db/migrations/004_prose.sql
"$GATE" >"$SCRATCH/out" 2>&1; expect T24a-gate-rejects-prose 1 $? "no rollback path"
"$SHIP" "prose migration" >"$SCRATCH/out" 2>&1; expect T24b-ship-block 3 $? "MIGRATION_GATE"
git reset -q && rm -f db/migrations/004_prose.sql

# --- T25: an empty paired rollback file is not coverage.
printf 'CREATE TABLE e(id int);\n' > db/migrations/009_up.sql
: > db/migrations/009_down.sql
git add db/migrations/009_up.sql db/migrations/009_down.sql
"$GATE" >"$SCRATCH/out" 2>&1; expect T25-empty-pair 1 $? "no rollback path"
git reset -q && rm -f db/migrations/009_up.sql db/migrations/009_down.sql

# --- T26: 'task-' no longer trips the anchored sk- secret rule
git add docs/y.md 2>/dev/null || { echo z > docs/y.md && git add docs/y.md; }
"$SHIP" "fix task-terminal wording" >"$SCRATCH/out" 2>&1; expect T26-sk-false-positive 0 $?

# --- T27: a real sk- key is still blocked
# (key split via %s so this file itself carries no flaggable token)
printf 'KEY = "sk-%s"\n' 'abcdefghijklmnopqrst1234' > src/keys.py
git add src/keys.py
"$SHIP" "add keys" >"$SCRATCH/out" 2>&1; expect T27-real-key-blocked 2 $? "HYGIENE_GATE"
git reset -q && rm -f src/keys.py

# --- T28: added lines in lockfiles are skipped entirely
printf 'token = "sk-%s"\n' 'abcdefghijklmnopqrst1234' > uv.lock
git add uv.lock
"$SHIP" "chore: bump lock" >"$SCRATCH/out" 2>&1; expect T28-lockfile-skip 0 $?

# --- T29: --diff-base cannot be desynced by forged subjects.
# A fake sentinel plus fake diff-header subjects used to smuggle an
# unscanned cyrillic subject through; subjects are now scanned in a
# separate stdin-mode pass with no path context.
git commit -q --allow-empty -m '@@SUBJECTS_END@@'
git commit -q --allow-empty -m 'diff --git a/x b/canon/agents/x.md'
git commit -q --allow-empty -m '+++ b/canon/agents/x.md'
git commit -q --allow-empty -m "$CYR_MSG"
"$HYG" --diff-base HEAD~4 >"$SCRATCH/out" 2>&1
expect T29-subject-smuggle 1 $? "cyrillic"

# --- T30: --diff-base on an unresolvable ref fails closed
"$HYG" --diff-base nonexistent-ref-xyz >"$SCRATCH/out" 2>&1
expect T30-bad-ref-failclosed 1 $? "does not resolve"

# --- T31: every API-key alternative actually fires (positive tests -
# a \b-in-non-raw-string regression once silently killed xox/AKIA).
# Keys are built by concatenation so this file stays pattern-clean.
t31=0
for key in 'xo''xb-abcdefghijklmnop' 'AK''IAIOSFODNN7EXAMPLE' "sk-$(printf 'a%.0s' {1..20})"; do
  printf 'token %s here\n' "$key" | "$HYG" >"$SCRATCH/out" 2>&1
  [ $? -eq 1 ] || { echo "FAIL T31-key-not-flagged: $key"; t31=1; }
done
[ "$t31" -eq 0 ] && { echo "PASS T31-api-key-patterns"; pass=$((pass+1)); } || fail=$((fail+1))

# --- T32: scope gate inspects the OLD path of a rename too -
# renaming 'outside/secret.md' to 'docs/ok.md' cannot smuggle
# out-of-whitelist content into an allowed path.
echo 'docs/' > "$SCRATCH/canon/scope_whitelist.txt"
mkdir -p outside && echo secret > outside/secret.md
git add outside/secret.md && git -c user.email=t@t -c user.name=t commit -qm "seed outside file"
git mv outside/secret.md docs/ok.md
"$SHIP" "rename smuggle" >"$SCRATCH/out" 2>&1; expect T32-rename-scope 2 $? "SCOPE_GATE"
git reset -q --hard HEAD 2>/dev/null || git reset -q
rm -f "$SCRATCH/canon/scope_whitelist.txt"

# --- T33: path exemption still works - cyrillic added under
# canon/agents/ in the real staged diff is allowed.
mkdir -p canon/agents && printf '%s\n' "$CYR_MSG" > canon/agents/ru_profile.md
git add canon/agents/ru_profile.md
"$SHIP" "add ru agent profile" >"$SCRATCH/out" 2>&1; expect T33-exempt-path-ok 0 $?

# --- T34: a malformed project.json fails closed (infra violation)
cp "$SCRATCH/canon/project.json" "$SCRATCH/pj.bak"
echo '{not valid json' > "$SCRATCH/canon/project.json"
echo hi | "$HYG" >"$SCRATCH/out" 2>&1; expect T34-malformed-pj 1 $? "fail closed"
cp "$SCRATCH/pj.bak" "$SCRATCH/canon/project.json"

# --- T35: a caller-controlled DRY_RUN_CMD env var is ignored; only
# the project.json-declared migration_dry_run_cmd runs.
printf 'CREATE TABLE dr(id int);\n-- rollback: DROP TABLE dr;\n' > db/migrations/010_up.sql
git add db/migrations/010_up.sql
DRY_RUN_CMD=false "$GATE" >"$SCRATCH/out" 2>&1; expect T35a-env-ignored 0 $?
echo '{"text_language":"en","migration_dry_run_cmd":"false"}' > "$SCRATCH/canon/project.json"
"$GATE" >"$SCRATCH/out" 2>&1; expect T35b-declared-dryrun-fails 1 $? "dry-run"
cp "$SCRATCH/pj.bak" "$SCRATCH/canon/project.json"
git reset -q && rm -f db/migrations/010_up.sql

# --- T36: canon/ attribution exemption (canon self-trip fix).
# Rule-source files under canon/ carry attribution-pattern examples
# and must not trip the attribution class; secret class still scans
# them, and attribution still fires outside canon/.
ATTR='generated'' with'
printf 'diff --git a/canon/agents/git.md b/canon/agents/git.md\n+++ b/canon/agents/git.md\n@@ -1,1 +1,1 @@\n+do not add "%s Devin" footer\n' "$ATTR" \
  | "$HYG" --diff >"$SCRATCH/out" 2>&1
expect T36a-canon_dir-attribution-exempt 0 $?
printf 'diff --git a/canon/agents/git.md b/canon/agents/git.md\n+++ b/canon/agents/git.md\n@@ -1,1 +1,1 @@\n+KEY = "sk-%s"\n' 'abcdefghijklmnopqrst1234' \
  | "$HYG" --diff >"$SCRATCH/out" 2>&1
expect T36b-canon_dir-secret-still-fails 1 $? "secret"
printf 'diff --git a/docs/x.md b/docs/x.md\n+++ b/docs/x.md\n@@ -1,1 +1,1 @@\n+%s Devin\n' "$ATTR" \
  | "$HYG" --diff >"$SCRATCH/out" 2>&1
expect T36c-attribution-outside-canon_dir 1 $? "attribution"

# --- T37: a staged symlink (mode 120000) is rejected - it cannot
# smuggle out-of-tree content past the diff/content gates.
ln -s /etc/passwd src/passwd_link
git add src/passwd_link
"$SHIP" "add link" >"$SCRATCH/out" 2>&1; expect T37-symlink-block 2 $?
git reset -q; rm -f src/passwd_link

# --- T38: U+2028/U+2029/NEL cannot smuggle cyrillic - scanners split
# only on \n, so the hidden "line" is still checked.
printf 'fix thing\xe2\x80\xa8\xd0\xba\xd0\xb8\xd1\x80\xd0\xb8\xd0\xbb\n' | "$HYG" >"$SCRATCH/out" 2>&1
expect T38-unicode-sep 1 $? "cyrillic"

# --- T39: placeholder credential values are not flagged - docs and
# examples must not trip the secret class.
printf 'api_key = "your_key_here"\ntoken = "redacted"\n' | "$HYG" >"$SCRATCH/out" 2>&1
expect T39-placeholder-ok 0 $?

# --- T40: a tx.rollback()/session.rollback() expression in an upgrade
# is not rollback coverage - only directives (down:, downgrade(),
# explicit comment markers) count.
printf 'CREATE TABLE z(id int);\n# tx.rollback() on failure\n' > db/migrations/011_up.sql
git add db/migrations/011_up.sql
"$GATE" >"$SCRATCH/out" 2>&1; expect T40-tx-rollback 1 $? "no rollback path"
git reset -q; rm -f db/migrations/011_up.sql

# --- T41: cycle_log auth - unauthenticated close and resolve_*
# appends are denied (exit 3).
CL="$SCRATCH/canon/bin/cycle_log.sh"
REG=$("$CL" register --actor exec-1 --role executor)
EX_TOKEN=$(printf '%s' "$REG" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
"$CL" append --item i_1 --actor exec-1 --action commit \
  --expected e --result r --status open --verdict failure \
  --failure-class gate_blocked >/dev/null
"$CL" close --actor exec-1 --item i_1 >"$SCRATCH/out" 2>&1
expect T41a-close-no-token 3 $?
"$CL" append --item i_1 --actor exec-1 --action resolve_fix \
  --expected e --result r --status closed --verdict ok >"$SCRATCH/out" 2>&1
expect T41b-resolve-no-token 3 $?

# --- T42: an escalated record cannot be self-closed by its owner -
# privileged role required even for own records.
"$CL" append --item i_2 --actor exec-1 --action gate \
  --expected e --result r --status open --verdict escalated \
  --failure-class manual_gate >/dev/null
"$CL" close --actor exec-1 --token "$EX_TOKEN" --item i_2 >"$SCRATCH/out" 2>&1
expect T42a-esc-self-close 3 $?
REG2=$("$CL" register --actor orc-1 --role orchestrator)
ORC_TOKEN=$(printf '%s' "$REG2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
"$CL" close --actor orc-1 --token "$ORC_TOKEN" --for-actor exec-1 \
  --item i_2 >"$SCRATCH/out" 2>&1
expect T42b-esc-cross-close 0 $?

# --- T43: sequential fold - a NEW open record for a previously
# closed (actor,item) pair is still closeable (not shadowed forever).
"$CL" append --item i_1 --actor exec-1 --action retry \
  --expected e --result r --status open --verdict failure \
  --failure-class ci_failed >/dev/null
"$CL" close --actor exec-1 --token "$EX_TOKEN" --item i_1 >"$SCRATCH/out" 2>&1
expect T43-reopen-close 0 $?

# --- T44-T47: reader_digest attestation validation
RD="$SCRATCH/canon/bin/reader_digest.sh"
printf 'l1\nl2\nl3\nl4\nl5\n' > "$SCRATCH/digest_target.txt"
printf '{"path":"%s","sha256":"x","total_bytes":10,"total_lines":5,"covered_ranges":[[true,5]],"tail_anchor":"l5"}' \
  "$SCRATCH/digest_target.txt" > "$SCRATCH/att_bool.json"
"$RD" --verify "$SCRATCH/digest_target.txt" --attestation "$SCRATCH/att_bool.json" >"$SCRATCH/out" 2>&1
expect T44-bool-range 1 $?
printf '{"path":"%s","sha256":"x","total_bytes":10,"total_lines":5,"covered_ranges":[[1,2],[4,5]],"tail_anchor":"l5"}' \
  "$SCRATCH/digest_target.txt" > "$SCRATCH/att_gap.json"
"$RD" --verify "$SCRATCH/digest_target.txt" --attestation "$SCRATCH/att_gap.json" >"$SCRATCH/out" 2>&1
expect T45-gap-range 1 $?
printf '{"path":"/other/file.txt","sha256":"x","total_bytes":10,"total_lines":5,"covered_ranges":[[1,5]],"tail_anchor":"l5"}' \
  > "$SCRATCH/att_path.json"
"$RD" --verify "$SCRATCH/digest_target.txt" --attestation "$SCRATCH/att_path.json" >"$SCRATCH/out" 2>&1
expect T46-path-mismatch 1 $?
"$RD" --verify "$SCRATCH/nonexistent.txt" --attestation "$SCRATCH/att_path.json" >"$SCRATCH/out" 2>&1
expect T47-missing-file 2 $? "not_found"

# --- T48: migration pairing hardening (iter8 registry) -------------
# a) dot-separated direction markers pair exactly like underscore
(cd "$REPO2" && printf 'CREATE TABLE p(id int);\n' > db/migrations/009.up.sql \
  && printf 'DROP TABLE p;\n' > db/migrations/009.down.sql \
  && git add db/migrations/009.up.sql db/migrations/009.down.sql \
  && ./canon/bin/migration_gate.sh --check) >"$SCRATCH/out" 2>&1
expect T48a-dot-pair 0 $?
(cd "$REPO2" && git reset -q; rm -f db/migrations/009.up.sql db/migrations/009.down.sql)
# b) Flyway versions must match: V1__x must NOT pair with U2__x
(cd "$REPO2" && printf 'CREATE TABLE q(id int);\n' > db/migrations/V1__q.sql \
  && printf 'DROP TABLE q;\n' > db/migrations/U2__q.sql \
  && git add db/migrations/V1__q.sql db/migrations/U2__q.sql \
  && ./canon/bin/migration_gate.sh --check) >"$SCRATCH/out" 2>&1
expect T48b-flyway-version-mismatch 1 $? "no rollback path"
(cd "$REPO2" && git reset -q; rm -f db/migrations/V1__q.sql db/migrations/U2__q.sql)
# c) same-version Flyway V2/U2 DOES pair
(cd "$REPO2" && printf 'CREATE TABLE r(id int);\n' > db/migrations/V2__r.sql \
  && printf 'DROP TABLE r;\n' > db/migrations/U2__r.sql \
  && git add db/migrations/V2__r.sql db/migrations/U2__r.sql \
  && ./canon/bin/migration_gate.sh --check) >"$SCRATCH/out" 2>&1
expect T48c-flyway-version-match 0 $?
(cd "$REPO2" && git reset -q; rm -f db/migrations/V2__r.sql db/migrations/U2__r.sql)
# d) ship_commit with an explicit deleted-file arg must not be
#    rejected by Gate 1 (ls-files cannot see staged deletions)
(cd "$REPO2" && printf 'CREATE TABLE s(id int);\n-- rollback: DROP TABLE s;\n' \
    > db/migrations/010_up.sql && git add db/migrations/010_up.sql \
  && ./canon/bin/ship_commit.sh "add 010" >"$SCRATCH/out" 2>&1 \
  && printf 'db/migrations/010_up.sql\n' > canon/migration_rollforward.md \
  && git add canon/migration_rollforward.md \
  && git commit -qm "note" -- canon/migration_rollforward.md \
  && rm db/migrations/010_up.sql \
  && ./canon/bin/ship_commit.sh "drop 010" db/migrations/010_up.sql) >"$SCRATCH/out" 2>&1
expect T48d-delete-with-args 0 $?

# --- T49: design_spec_check gate (designer -> code_writer) --------
DS="$CANON_DIR/bin/design_spec_check.sh"
cat >"$SCRATCH/contract_full.md" <<'EOF'
## Delegated decisions
- axis: control_placement | constraint: must comply with design system
- axis: control_size | constraint: within grid bounds
EOF
cat >"$SCRATCH/spec_ok.md" <<'EOF'
## Impl spec
### axis: control_placement
- decision: top-right toolbar
- constraint_check: matches design system grid
- alternatives: bottom bar (rejected: thumb reach)
### axis: control_size
- decision: 32px
- constraint_check: inside grid bounds
- alternatives: 40px (rejected: crowds the toolbar)
EOF
# a) contract without delegated axes - designer not required
printf 'plain contract, no axes\n' >"$SCRATCH/contract_none.md"
"$DS" --contract "$SCRATCH/contract_none.md" >"$SCRATCH/out" 2>&1
expect T49a-no-axes 0 $? "not required"
# b) declared axes but no spec file
"$DS" --contract "$SCRATCH/contract_full.md" >"$SCRATCH/out" 2>&1
expect T49b-no-spec 1 $? "no readable impl spec"
# c) all axes covered -> pass
"$DS" --contract "$SCRATCH/contract_full.md" --spec "$SCRATCH/spec_ok.md" >"$SCRATCH/out" 2>&1
expect T49c-covered 0 $? "covered"
# d) a declared axis left out of the spec -> fail naming the axis
sed '/^### axis: control_size/,$d' "$SCRATCH/spec_ok.md" >"$SCRATCH/spec_missing.md"
"$DS" --contract "$SCRATCH/contract_full.md" --spec "$SCRATCH/spec_missing.md" >"$SCRATCH/out" 2>&1
expect T49d-uncovered-axis 1 $? "control_size"
# e) spec resolving an undeclared axis = improvisation -> fail
cat "$SCRATCH/spec_ok.md" >"$SCRATCH/spec_extra.md"
printf '### axis: colors\n- decision: red\n' >>"$SCRATCH/spec_extra.md"
"$DS" --contract "$SCRATCH/contract_full.md" --spec "$SCRATCH/spec_extra.md" >"$SCRATCH/out" 2>&1
expect T49e-undeclared-axis 1 $? "improvisation"
# f) axis entry present but no decision -> fail
cat >"$SCRATCH/spec_nodec.md" <<'EOF'
## Impl spec
### axis: control_placement
- constraint_check: matches design system
### axis: control_size
- decision: 32px
EOF
"$DS" --contract "$SCRATCH/contract_full.md" --spec "$SCRATCH/spec_nodec.md" >"$SCRATCH/out" 2>&1
expect T49f-undecided-axis 1 $? "control_placement"

# --- T50: branch-name gate accepts epic_issue_, rejects malformed --
VC="$CANON_DIR/bin/verify_constraints.sh"
(cd "$SCRATCH/repo" && VERIFY_BRANCH=epic_issue_x-bad \
   bash "$VC") >"$SCRATCH/out" 2>&1
expect T50a-malformed-epic-letter 1 $? "branch 'epic_issue_x-bad' !="
(cd "$SCRATCH/repo" && VERIFY_BRANCH=epicissue_9-x \
   bash "$VC") >"$SCRATCH/out" 2>&1
expect T50b-malformed-epic-nosep 1 $? "branch 'epicissue_9-x' !="
(cd "$SCRATCH/repo" && VERIFY_BRANCH=epic_9-x \
   bash "$VC") >"$SCRATCH/out" 2>&1
expect T50c-malformed-epic-noissue 1 $? "branch 'epic_9-x' !="
# positive: a well-formed epic branch must PASS the branch check
# (later gates may still fail without gh/remotes - the branch line
# is what we assert).
(cd "$SCRATCH/repo" && VERIFY_BRANCH=epic_issue_9-feature \
   bash "$VC") >"$SCRATCH/out" 2>&1
expect T50d-epic-branch-ok 1 $? "PASS: branch epic_issue_9-feature"
(cd "$SCRATCH/repo" && VERIFY_BRANCH=epic_issue_9- \
   bash "$VC") >"$SCRATCH/out" 2>&1
expect T50e-malformed-epic-noslug 1 $? "branch 'epic_issue_9-' !="

# --- T51-T56: review panel mechanics (gate_run attestations,
# panel_verdict signal derivation, panel_gate fail-closed) ---------
PANEL_DIR="$SCRATCH/panel_repo"
mkdir -p "$PANEL_DIR/canon/bin" "$PANEL_DIR/canon/forge" \
         "$PANEL_DIR/canon/config" "$PANEL_DIR/docs/specs" "$PANEL_DIR/.changes"
(cd "$PANEL_DIR" && git init -q -b main . && git config user.email t@t && git config user.name t)
for f in gate_run panel_verdict panel_gate spec_anchor_check docs_check \
         security_check quality_check fidelity_check hygiene_check gh_id; do
  cp "$CANON_DIR/bin/$f.sh" "$PANEL_DIR/canon/bin/"
done
cp "$CANON_DIR/bin/secret_scan.py" "$PANEL_DIR/canon/bin/"
cp "$CANON_DIR/forge/test.sh" "$CANON_DIR/forge/github.sh" \
   "$CANON_DIR/forge/gitlab.sh" "$PANEL_DIR/canon/forge/"
cp "$CANON_DIR/config/review_panel.json" "$PANEL_DIR/canon/config/"
chmod +x "$PANEL_DIR"/canon/bin/*.sh "$PANEL_DIR"/canon/forge/*.sh
cat > "$PANEL_DIR/canon/project.json" <<'EOF'
{"repo":"t/panel","text_language":"en","protected_paths":[],
 "forge":"test","base_branch":"main",
 "gate_checks":{"test_suite_optional":true},
 "review":{"reviewer_logins":["panel-test"]}}
EOF
printf 'canon/gate_runs.jsonl\ncanon/gate_runs.jsonl.lock\ncanon/panel_*\n' \
  > "$PANEL_DIR/.gitignore"
printf '## Req A\nBody.\n' > "$PANEL_DIR/docs/specs/spec.md"
(cd "$PANEL_DIR" && git add -A && git commit -qm init && \
 git checkout -qb issue_1-t && echo x > a.txt && \
 printf -- '---\nbump: patch\nuser_visible: "false"\nissue: 1\n---\n## Spec impact\n- adds: docs/specs/spec.md#req-a\n' \
   > .changes/1-t.md && git add -A && git commit -qm work)
PSHA=$(cd "$PANEL_DIR" && git rev-parse HEAD)
GR="$PANEL_DIR/canon/bin/gate_run.sh"
PV="$PANEL_DIR/canon/bin/panel_verdict.sh"
PG="$PANEL_DIR/canon/bin/panel_gate.sh"

# T51: floor run attests + status/verify round-trip
(cd "$PANEL_DIR" && bash "$GR" run --check docs_check --candidate $PSHA) >"$SCRATCH/out" 2>&1
expect T51a-floor-run 0 $?
(cd "$PANEL_DIR" && bash "$GR" verify --check docs_check --candidate $PSHA) >"$SCRATCH/out" 2>&1
expect T51b-floor-verify 0 $? "OK"
# wrong sha -> HEAD binding refuses to attest
(cd "$PANEL_DIR" && bash "$GR" run --check docs_check --candidate 0000000000000000000000000000000000000000) >"$SCRATCH/out" 2>&1
expect T51c-head-binding 1 $? "!="

# T52: verdict set derives state mechanically (CRITICAL -> failure)
cat > "$SCRATCH/vsec.json" <<EOF
{"domain":"security","head":"$PSHA","summary":"s","receipt":["a.txt"],
 "findings":[{"severity":"CRITICAL","text":"x"}]}
EOF
(cd "$PANEL_DIR" && bash "$PV" set --pr 1 --sha $PSHA --record "$SCRATCH/vsec.json") >"$SCRATCH/out" 2>&1
expect T52a-critical-failure 0 $? '"state": "failure"'
cat > "$SCRATCH/vdocs.json" <<EOF
{"domain":"docs","head":"$PSHA","summary":"s","receipt":["a.txt"],"findings":[]}
EOF
(cd "$PANEL_DIR" && bash "$PV" set --pr 1 --sha $PSHA --record "$SCRATCH/vdocs.json") >"$SCRATCH/out" 2>&1
expect T52b-clean-success 0 $? '"state": "success"'
# a record whose head disagrees with --sha is stale_input
sed "s/\"head\":\"$PSHA\"/\"head\":\"0000000000000000000000000000000000000000\"/" \
  "$SCRATCH/vdocs.json" > "$SCRATCH/vbad.json"
(cd "$PANEL_DIR" && bash "$PV" set --pr 1 --sha $PSHA --record "$SCRATCH/vbad.json") >"$SCRATCH/out" 2>&1
expect T52c-stale-head-record 2 $? "stale_input"
# missing receipt is malformed_input
cat > "$SCRATCH/vnr.json" <<EOF
{"domain":"docs","head":"$PSHA","summary":"s","findings":[]}
EOF
(cd "$PANEL_DIR" && bash "$PV" set --pr 1 --sha $PSHA --record "$SCRATCH/vnr.json") >"$SCRATCH/out" 2>&1
expect T52d-no-receipt 2 $? "receipt"

# T53: panel gate fail-closed on missing domains, then passes
(cd "$PANEL_DIR" && bash "$PG" --sha $PSHA --worktree . --info-file /dev/null) >"$SCRATCH/out" 2>&1
expect T53a-missing-domains 1 $? "missing_review_domain"
for d in quality design tester fidelity; do
cat > "$SCRATCH/v_$d.json" <<EOF
{"domain":"$d","head":"$PSHA","summary":"s","receipt":["a.txt"],"findings":[]}
EOF
(cd "$PANEL_DIR" && bash "$PV" set --pr 1 --sha $PSHA --record "$SCRATCH/v_$d.json" >/dev/null 2>&1)
done
# security still failing -> gate stays blocked
(cd "$PANEL_DIR" && bash "$PG" --sha $PSHA --worktree . --info-file /dev/null) >"$SCRATCH/out" 2>&1
expect T53b-failed-domain 1 $? "security:failure"
cat > "$SCRATCH/vsec2.json" <<EOF
{"domain":"security","head":"$PSHA","summary":"fixed","receipt":["a.txt"],"findings":[]}
EOF
(cd "$PANEL_DIR" && bash "$PV" set --pr 1 --sha $PSHA --record "$SCRATCH/vsec2.json" >/dev/null 2>&1)
(cd "$PANEL_DIR" && bash "$PG" --sha $PSHA --worktree . --info-file /dev/null) >"$SCRATCH/out" 2>&1
expect T53c-panel-green 0 $? '"ok": true'

# T54: a different head sha invalidates everything (stale signals)
(cd "$PANEL_DIR" && echo y >> a.txt && git add a.txt && git commit -qm bump)
NSHA=$(cd "$PANEL_DIR" && git rev-parse HEAD)
(cd "$PANEL_DIR" && bash "$PG" --sha $NSHA --worktree . --info-file /dev/null) >"$SCRATCH/out" 2>&1
expect T54-stale-signals 1 $? "missing_review_domain"

# T55: UNCERTAIN maps to failure (fail-closed), floor enforced for
# hybrid domains: fidelity with a blocking floor cannot pass.
cat > "$SCRATCH/vunc.json" <<EOF
{"domain":"docs","head":"$NSHA","summary":"s","receipt":["a.txt"],
 "findings":[{"severity":"UNCERTAIN","text":"cannot verify X"}]}
EOF
(cd "$PANEL_DIR" && bash "$PV" set --pr 1 --sha $NSHA --record "$SCRATCH/vunc.json") >"$SCRATCH/out" 2>&1
expect T55-uncertain-failure 0 $? '"state": "failure"'

# --- T56: a secret inside a binary/invalid-UTF-8 file is still
# caught (--text forces the added lines through the scanner; before,
# git printed 'Binary files differ' and the secret never appeared).
(cd "$PANEL_DIR" && printf 'token = "sk-%s"\n\x00\xff\x80 binary tail\n' \
   'abcdefghijklmnopqrst1234' > blob.bin && git add blob.bin && git commit -qm "add blob")
(cd "$PANEL_DIR" && BASE=main bash canon/bin/security_check.sh) >"$SCRATCH/out" 2>&1
expect T56-binary-secret 1 $? "secret"
(cd "$PANEL_DIR" && git reset -q --hard HEAD~1 >/dev/null 2>&1)
# malformed UTF-8 in the stream must neither crash nor slip past the
# scanner: errors=replace decodes it and the ASCII key body still trips.
printf 'x = "sk-%s" \xff\xfe\n' 'abcdefghijklmnopqrst1234' \
  | python3 "$CANON_DIR/bin/secret_scan.py" >/dev/null 2>&1
[ $? -eq 1 ] && { echo "PASS T56b-nonutf8-scanned"; pass=$((pass+1)); } \
  || { echo "FAIL T56b-nonutf8-scanned: scanner must flag rc=1"; fail=$((fail+1)); }

# --- T57: git_ro refuses execution-capable flags (arbitrary command
# via diff drivers/textconv/pager was audit finding #4).
GIT_RO="$CANON_DIR/bin/git_ro.sh"
t57=0
for flag in --ext-diff --textconv -Ofoo --paginate --output=/tmp/x \
            --git-dir=/tmp/x --work-tree=/tmp --no-index --find-object=x; do
  (cd "$PANEL_DIR" && bash "$GIT_RO" diff "$flag" HEAD~1 HEAD) >/dev/null 2>&1
  [ $? -eq 2 ] || { echo "FAIL T57-gitro-flag: '$flag' not refused"; t57=1; }
done
# a global -c config injection must die as an unknown op as well
(cd "$PANEL_DIR" && bash "$GIT_RO" -c diff.external=id diff HEAD~1 HEAD) >/dev/null 2>&1
[ $? -eq 2 ] || { echo "FAIL T57-gitro-dashc: '-c' not refused"; t57=1; }
[ "$t57" -eq 0 ] && { echo "PASS T57-gitro-flags"; pass=$((pass+1)); } || fail=$((fail+1))

# --- T58: '## Impl spec' smuggled into a code comment must NOT
# satisfy delegated axes - only tracked docs/impl_specs/<stem>.md
# bound to the declaring file counts.
(cd "$PANEL_DIR" && mkdir -p src docs/impl_specs \
  && printf '## Delegated decisions\n- axis: control_placement | constraint: in grid\n' \
       > docs/specs/contract_t58.md \
  && printf '# ## Impl spec\n# ### axis: control_placement\n# - decision: top\n' \
       > src/evil.py \
  && git add -A && git commit -qm "axes + injected spec")
(cd "$PANEL_DIR" && BASE=main bash canon/bin/fidelity_check.sh) >"$SCRATCH/out" 2>&1
expect T58a-injected-spec 1 $? "control_placement"
# honest impl spec at the bound location fixes the failure
cat > "$PANEL_DIR/docs/impl_specs/contract_t58.md" <<'EOF'
## Impl spec
### axis: control_placement
- decision: top-right
- constraint_check: inside grid bounds
EOF
(cd "$PANEL_DIR" && git add docs/impl_specs/contract_t58.md && git commit -qm "real spec")
(cd "$PANEL_DIR" && BASE=main bash canon/bin/fidelity_check.sh) >"$SCRATCH/out" 2>&1
expect T58b-bound-spec-ok 0 $? "covered"

# --- T59: git_ro branch - a dash-leading arg must die even when a
# list flag is present ('--contains HEAD -D victim' would otherwise
# DELETE a branch inside the read-only path - review_6 #8).
GIT_RO="$CANON_DIR/bin/git_ro.sh"
(cd "$PANEL_DIR" && bash "$GIT_RO" branch --contains HEAD -D victim) >/dev/null 2>&1
expect T59-branch-dashD 2 $?
(cd "$PANEL_DIR" && bash "$GIT_RO" branch -l 'ma*') >"$SCRATCH/out" 2>&1
expect T59b-branch-list-ok 0 $? "main"
# and the pattern slot itself never accepts a leading '-'
(cd "$PANEL_DIR" && bash "$GIT_RO" branch -l '-D') >/dev/null 2>&1
expect T59c-branch-dashpattern 2 $?

# --- T60: fidelity - an impl spec may not decide axes no contract
# delegated (improvisation, review_6 #3).
cat > "$PANEL_DIR/docs/impl_specs/contract_t58.md" <<'EOF'
## Impl spec
### axis: control_placement
- decision: top-right
- constraint_check: inside grid bounds
### axis: color
- decision: neon pink
EOF
(cd "$PANEL_DIR" && git add docs/impl_specs/contract_t58.md \
  && git commit -qm "improvised axis")
(cd "$PANEL_DIR" && BASE=main bash canon/bin/fidelity_check.sh) >"$SCRATCH/out" 2>&1
expect T60-extra-axis 1 $? "never delegated"

# --- T61: same-named axes in TWO contracts - per-file declaration
# must stop contract_b's spec from covering contract_a's axis.
(cd "$PANEL_DIR" \
  && printf '## Delegated decisions\n- axis: layout | c\n' > docs/specs/cx.md \
  && printf '## Delegated decisions\n- axis: layout | c\n' > docs/specs/cy.md \
  && printf '## Impl spec\n### axis: control_placement\n- decision: top-right\n- constraint_check: b\n### axis: layout\n- decision: grid\n' \
       > docs/impl_specs/cx.md \
  && git add -A && git commit -qm "two contracts, same axis, one spec")
(cd "$PANEL_DIR" && BASE=main bash canon/bin/fidelity_check.sh) >"$SCRATCH/out" 2>&1
expect T61-sameaxis-second-uncovered 1 $? "layout"
# the color extra-axis still trips too - fix both at once
cat > "$PANEL_DIR/docs/impl_specs/cy.md" <<'EOF'
## Impl spec
### axis: layout
- decision: stack
EOF
cat > "$PANEL_DIR/docs/impl_specs/contract_t58.md" <<'EOF'
## Impl spec
### axis: control_placement
- decision: top-right
- constraint_check: inside grid bounds
EOF
(cd "$PANEL_DIR" && git add -A && git commit -qm "second spec + drop extra axis")
(cd "$PANEL_DIR" && BASE=main bash canon/bin/fidelity_check.sh) >"$SCRATCH/out" 2>&1
expect T61b-sameaxis-both-covered 0 $? "covered"

# --- T62: ship_commit - docs/impl_specs/* is NOT a blanket scope
# exemption anymore; only an explicit whitelist entry allows it
# (review_6 #4).
(cd "$SCRATCH/repo" \
  && git reset -q --hard HEAD >/dev/null 2>&1 \
  && mkdir -p docs/impl_specs \
  && echo 'docs/x.md' > "$SCRATCH/canon/scope_whitelist.txt" \
  && echo '## Impl spec' > docs/impl_specs/x.md \
  && git add docs/impl_specs/x.md)
(cd "$SCRATCH/repo" && bash "$SHIP" "leak spec") >"$SCRATCH/out" 2>&1
expect T62-implspec-scope-block 2 $? "SCOPE_GATE"
(cd "$SCRATCH/repo" \
  && printf 'docs/x.md\ndocs/impl_specs/\n' > "$SCRATCH/canon/scope_whitelist.txt" \
  && git reset -q && git add docs/impl_specs/x.md)
(cd "$SCRATCH/repo" && bash "$SHIP" "spec in scope") >"$SCRATCH/out" 2>&1
expect T62b-implspec-whitelisted 0 $?
rm -f "$SCRATCH/canon/scope_whitelist.txt"

# --- T63: spec_anchor_check - a delta with no pending fragments is
# a SKIP, not a fail on an empty adapter list (review_6 #5).
PHEAD=$(cd "$PANEL_DIR" && git rev-parse HEAD)
(cd "$PANEL_DIR" && BASE="$PHEAD" bash canon/bin/spec_anchor_check.sh) >"$SCRATCH/out" 2>&1
expect T63-empty-pending-skip 0 $? "SKIP"

# --- T64: panel_verdict receipts - blanks and stop words are
# placeholders, not inspected files (review_6 #12).
t64=0
for r in '"none"' '"  "' '"todo"' '"-"'; do
  printf '{"domain":"docs","head":"%s","summary":"s","receipt":[%s],"findings":[]}\n' \
    "$PHEAD" "$r" > "$SCRATCH/vbad.json"
  (cd "$PANEL_DIR" && bash "$PV" set --pr 1 --sha "$PHEAD" --record "$SCRATCH/vbad.json") \
    >"$SCRATCH/out" 2>&1
  [ $? -eq 2 ] \
    || { echo "FAIL T64-receipt-stopword: receipt [$r] accepted"; t64=1; }
done
[ "$t64" -eq 0 ] && { echo "PASS T64-receipt-stopwords"; pass=$((pass+1)); } \
  || fail=$((fail+1))

# --- T65: docs_check - markdown links with a title still resolve;
# {#id} anchors behave the same in both checkers (review_6 #11).
cat > "$PANEL_DIR/docs/specs/titled.md" <<'EOF'
## Target
See [the guide](spec.md "Spec file") and [anchor](#target) plus
[custom](spec.md#req-a 'Req A').
EOF
(cd "$PANEL_DIR" && git add docs/specs/titled.md && git commit -qm "titled links")
(cd "$PANEL_DIR" && bash canon/bin/docs_check.sh) >"$SCRATCH/out" 2>&1
expect T65-title-links 0 $?
# a title link to a missing file is still a broken link, not noise
cat > "$PANEL_DIR/docs/specs/titled.md" <<'EOF'
## Target
See [gone](nope.md "Missing").
EOF
(cd "$PANEL_DIR" && git add docs/specs/titled.md && git commit -qm "bad link")
(cd "$PANEL_DIR" && bash canon/bin/docs_check.sh) >"$SCRATCH/out" 2>&1
expect T65b-title-link-broken 1 $? "nope.md"
(cd "$PANEL_DIR" && git rm -q docs/specs/titled.md && git commit -qm "cleanup titled")

# --- T66: forbidden_patterns must actually scan the delta file (the
# FORB block once read a removed bash variable - silent fail-open).
cp "$PANEL_DIR/canon/project.json" "$SCRATCH/pj_t66.bak"
python3 - "$PANEL_DIR/canon/project.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["security"] = {"forbidden_patterns": ["dangerous_call\\("]}
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
(cd "$PANEL_DIR" && printf 'dangerous_call(x)\n' > src/forbid.py \
  && git add src/forbid.py && git commit -qm "forbidden api")
(cd "$PANEL_DIR" && BASE=main bash canon/bin/security_check.sh) >"$SCRATCH/out" 2>&1
expect T66-forbidden-scan 1 $? "forbidden"
cp "$SCRATCH/pj_t66.bak" "$PANEL_DIR/canon/project.json"
(cd "$PANEL_DIR" && git reset -q --hard HEAD~1 >/dev/null 2>&1)

echo "---"
echo "gate_tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
