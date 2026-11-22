#!/usr/bin/env bash
# verify_constraints.sh - mechanical pre-completion checks.
# PASS / FAIL (exit 1) / ESCALATE (exit 3: protected paths need
# cited authorization).
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

GH=$("$CANON_DIR/bin/gh_id.sh" merge)
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP" 2>/dev/null || { echo "FAIL: not a git repo"; exit 1; }

fails=0; escalates=0
fail()     { echo "FAIL: $1"; echo "  fix: $2"; fails=$((fails+1)); }
escalate() { echo "ESCALATE: $1"; echo "  required: $2"; escalates=$((escalates+1)); }
pass()     { echo "PASS: $1"; }

PJ="$CANON_DIR/project.json"

# --- env input validation (fail closed, never silent-skip) ---
# VERIFY_PR: PR number or full https URL - anything else could be a
# gh flag injection.
VERIFY_PR="${VERIFY_PR:-}"
if [ -n "$VERIFY_PR" ]; then
  case "$VERIFY_PR" in
    *[!0-9]*)
      # URL form must name THIS repository's pull request - an
      # unanchored glob would let a foreign repo's open PR satisfy
      # the link/label gates, and any whitespace/flag tails inject
      # into the gh argv below. The slug comes from the github
      # remote, never from the supplied URL itself.
      REPO_SLUG=$(git remote -v 2>/dev/null \
        | awk '$2 ~ /^https:\/\/github\.com[:/]|^git@github\.com:/ {print $2; exit}' \
        | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')
      [ -n "$REPO_SLUG" ] || { echo "FAIL: VERIFY_PR is a URL but no github remote is configured"; exit 1; }
      case "$VERIFY_PR" in
        "https://github.com/$REPO_SLUG/pull/"[0-9]*)
          VERIFY_PR="${VERIFY_PR##*/}"
          case "$VERIFY_PR" in *[!0-9]*|'') echo "FAIL: VERIFY_PR URL has no numeric PR id"; exit 1 ;; esac ;;
        *) echo "FAIL: VERIFY_PR must be a PR number or an https PR URL of $REPO_SLUG"; exit 1 ;;
      esac ;;
    '') echo "FAIL: VERIFY_PR is empty"; exit 1 ;;
  esac
fi
# ISSUE_NUMS: space/comma separated integers only - commas are
# separators, never digits: "12,34" means {12,34}, not #1234.
ISSUE_NUMS=$(printf '%s' "${ISSUE_NUMS:-}" | tr ',' ' ')
for tok in $ISSUE_NUMS; do
  [ -z "$tok" ] && continue
  case "$tok" in
    *[!0-9]*|'') echo "FAIL: ISSUE_NUMS token '$tok' is not a positive integer"; exit 1 ;;
  esac
  [ "$tok" = "0" ] && { echo "FAIL: ISSUE_NUMS token '0' is not a valid issue number"; exit 1; }
done
# FRAG_ISSUES: same charset contract - fragment-only allowed set.
FRAG_ISSUES=$(printf '%s' "${FRAG_ISSUES:-}" | tr ',' ' ')
for tok in $FRAG_ISSUES; do
  [ -z "$tok" ] && continue
  case "$tok" in
    *[!0-9]*|'') echo "FAIL: FRAG_ISSUES token '$tok' is not a positive integer"; exit 1 ;;
  esac
  [ "$tok" = "0" ] && { echo "FAIL: FRAG_ISSUES token '0' is not a valid issue number"; exit 1; }
done
# VERIFY_BRANCH: ref-name charset only - it becomes git input below.
VERIFY_BRANCH="${VERIFY_BRANCH:-}"
if [ -n "$VERIFY_BRANCH" ]; then
  case "$VERIFY_BRANCH" in
    *[!A-Za-z0-9._/-]*|''|.*|..*|-*) echo "FAIL: VERIFY_BRANCH is not a valid ref name"; exit 1 ;;
  esac
fi

# 1. Branch name = issue_<issue_id>-<slug> for a task/item branch or
#    epic_issue_<issue_id>-<slug> for an epic branch (skip on base);
#    Release-on-Merge: version is NOT carried in the branch name.
#    release/v<X.Y.Z> is created by repo_release.sh when the base
#    is protected - it carries no item issue and no .changes
#    fragment (the release commit consumes them).
# VERIFY_BRANCH overrides the name check when the script runs on a
# detached verify worktree (repo_merge.sh blood-sign). Spoofing a
# base-branch name via VERIFY_BRANCH must NOT skip the item gates -
# the "on base branch" SKIP only applies to a real checkout with no
# VERIFY_BRANCH override.
BRANCH="${VERIFY_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
ISSUE_N=""
ON_BASE=0
if [[ "$BRANCH" =~ ^(epic_)?issue_([0-9]+)-[a-z0-9][a-z0-9_-]*$ ]]; then
  pass "branch $BRANCH"
  ISSUE_N="${BASH_REMATCH[2]}"
elif [[ "$BRANCH" =~ ^release/v[0-9]+\.[0-9]+\.[0-9]+(-r[0-9a-zA-Z]+)?$ ]]; then
  pass "release branch $BRANCH"
elif [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  if [ -n "$VERIFY_BRANCH" ]; then
    # A detached verify claiming to be the base gets no free pass:
    # the item gates still run, and the spoof is caught below when
    # VERIFY_PR names a real PR whose head branch does not match.
    echo "NOTE: VERIFY_BRANCH=$BRANCH (base name on detached verify) - item gates still run"
  else
    echo "SKIP: on base branch $BRANCH (no item branch)"
    ON_BASE=1
  fi
else
  fail "branch '$BRANCH' != issue_<N>-<slug> | epic_issue_<N>-<slug>" \
       "rename via git-agent, or state the task is branchless"
fi

# 2. Issue exists and is linked from the open PR. A branch covering
# several items may close several issues: extra numbers come from
# env ISSUE_NUMS (space/comma separated) - every one must exist and
# be linked in the PR body, the branch-name issue included.
# env FRAG_ISSUES (same format) - extra numbers allowed in the
# .changes fragment's 'issue:' field only (e.g. an epic PR carries
# task fragments named after the task issues); no existence or
# Closes-link requirement is attached to FRAG_ISSUES entries.
ISSUE_LIST=""
if [ -n "$ISSUE_N" ]; then
  # Branch zero-pads the number (issue_044) but GitHub numbers have no
  # leading zeros - normalize or every check below false-fails
  ISSUE_LIST=$((10#$ISSUE_N))
fi
for extra in ${ISSUE_NUMS:-}; do
  [ -z "$extra" ] && continue
  extra=$((10#$extra))   # normalize leading zeros for dedupe
  case " $ISSUE_LIST " in *" $extra "*) ;; *) ISSUE_LIST="$ISSUE_LIST $extra";; esac
done
FRAG_LIST=""
for extra in ${FRAG_ISSUES:-}; do
  [ -z "$extra" ] && continue
  extra=$((10#$extra))
  case " $FRAG_LIST " in *" $extra "*) ;; *) FRAG_LIST="$FRAG_LIST $extra";; esac
done
# Fetch PR metadata whenever an explicit VERIFY_PR or any issue is
# in play: VERIFY_BRANCH is bound to the PR's real headRefName so a
# detached worktree cannot name 'main' or a fake release/v* branch
# to slip past the item gates.
if [ -n "$ISSUE_LIST" ] || [ -n "$VERIFY_PR" ]; then
  PR_ERR=$(mktemp)
  PR_ARGS=(pr view)
  [ -n "$VERIFY_PR" ] && PR_ARGS+=("$VERIFY_PR")
  PR_ARGS+=(--json body,state,headRefName)
  PR_JSON=$(gh "${PR_ARGS[@]}" 2>"$PR_ERR")
  PR_RC=$?
  PR_BODY="" PR_STATE="" PR_HEAD=""
  if [ $PR_RC -eq 0 ]; then
    PR_BODY=$(PR_JSON="$PR_JSON" python3 -c 'import json,os;print(json.loads(os.environ["PR_JSON"]).get("body") or "")' 2>/dev/null)
    PR_STATE=$(PR_JSON="$PR_JSON" python3 -c 'import json,os;print(json.loads(os.environ["PR_JSON"]).get("state") or "")' 2>/dev/null)
    PR_HEAD=$(PR_JSON="$PR_JSON" python3 -c 'import json,os;print(json.loads(os.environ["PR_JSON"]).get("headRefName") or "")' 2>/dev/null)
  fi
  if [ -n "$VERIFY_PR" ] && [ -n "$VERIFY_BRANCH" ] && [ -n "$PR_HEAD" ] && [ "$PR_HEAD" != "$VERIFY_BRANCH" ]; then
    fail "VERIFY_BRANCH=$VERIFY_BRANCH does not match PR #$VERIFY_PR head ($PR_HEAD)" \
         "pass the real head branch - a spoofed base/release name cannot skip item gates"
  fi
  if [ -n "$VERIFY_PR" ] && [ $PR_RC -ne 0 ]; then
    # Explicit PR requested but the fetch errored - that is a FAIL,
    # not a SKIP: the link check must not silently degrade.
    fail "cannot fetch PR $VERIFY_PR metadata" \
         "check gh auth/network; the Closes-link gate cannot run"
  elif [ -n "$PR_STATE" ] && [ "$PR_STATE" != "OPEN" ]; then
    fail "PR ${VERIFY_PR:-<inferred>} is not OPEN (state=$PR_STATE)" \
         "link the issue from an open PR"
  fi
  for ISSUE_NUM in $ISSUE_LIST; do
    # --json number: a plain `gh issue view` queries the deprecated
    # projectCards field and exits 1 on every issue (gh 2.46+), which
    # this check would misread as "not found"
    "$GH" issue view "$ISSUE_NUM" --json number >/dev/null 2>&1 \
      && pass "issue #$ISSUE_NUM exists" \
      || fail "issue #$ISSUE_NUM not found" \
              "create it via repository-agent"
    if [ -n "$PR_BODY" ]; then
      # boundary on the number: `closes #16` must not satisfy `#163`;
      # and only auto-close verbs count - 'relates to' does not close.
      printf '%s' "$PR_BODY" | grep -qiE "(closes|fixes|resolves)[[:space:]]*:?[[:space:]]*#$ISSUE_NUM([^0-9]|$)" \
        && pass "PR links issue #$ISSUE_NUM" \
        || fail "PR body lacks 'Closes #$ISSUE_NUM' link" \
                "add the link via repository-agent"
    elif [ $PR_RC -eq 0 ] && [ -n "$VERIFY_PR" ]; then
      echo "SKIP: PR $VERIFY_PR has an empty body - link check cannot pass" \
        && fail "PR body is empty - no 'Closes #$ISSUE_NUM' link" \
                "add the link via repository-agent"
    else
      echo "SKIP: no open PR yet - link check deferred for #$ISSUE_NUM"
    fi
  done
fi
[ -f "${PR_ERR:-/nonexistent}" ] && rm -f "$PR_ERR"

# 3. Hygiene over outbound text (commit subjects + diff vs base).
# VERIFY_BASE carries the PR's real target branch when the script
# runs under repo_merge.sh blood-sign - guessing main/master on a
# repo whose base differs silently skips the diff gates.
BASE=""
BASE_REF=""
if [ -n "${VERIFY_BASE:-}" ]; then
  case "$VERIFY_BASE" in
    *[!A-Za-z0-9._/-]*|''|-*|*..*) echo "FAIL: VERIFY_BASE is not a valid ref name"; exit 1 ;;
  esac
  # Probe every configured remote - the github remote is not always
  # named 'origin' (repo_merge accepts any github.com remote name).
  for cand in $(git remote 2>/dev/null | sed "s#\$#/$VERIFY_BASE#") "$VERIFY_BASE"; do
    BASE=$(git merge-base HEAD "$cand" 2>/dev/null) && { BASE_REF="$cand"; break; } || BASE=""
  done
else
  for cand in origin/main origin/master github/main github/master main master; do
    BASE=$(git merge-base HEAD "$cand" 2>/dev/null) && { BASE_REF="$cand"; break; } || BASE=""
  done
fi
if [ -n "$BASE" ]; then
  # An item branch whose merge-base IS its HEAD has no branch diff at
  # all - every diff-based gate below would vacuously pass on zero
  # delta. That shape is not an item branch.
  if [ -n "$ISSUE_N" ] && [ "$BASE" = "$(git rev-parse HEAD)" ]; then
    fail "branch $BRANCH has no diff vs base (merge-base = HEAD)" \
         "nothing to verify - commit the change or drop the branch"
  fi
  "$CANON_DIR/bin/hygiene_check.sh" --diff-base "$BASE" \
    && pass "hygiene" \
    || fail "hygiene violations in outbound text" "fix flagged lines"
else
  fail "cannot resolve merge-base with base branch${VERIFY_BASE:+ ($VERIFY_BASE)}" \
       "fetch the base branch or state the task is branchless"
fi

# 4. Forbidden secrets/files = hard FAIL; protected_paths = ESCALATE
# Committed branch changes count too: this gate runs AFTER the work
# is committed, so scanning only the index/worktree would pass a
# committed secret or a protected-path edit. BASE (merge-base vs the
# base branch) is already resolved above. Deleted files never count:
# removing a file is not a secret leak.
CHANGED=$( { git -c core.quotepath=false diff --name-only --diff-filter=ACMR --cached;
             git -c core.quotepath=false diff --name-only --diff-filter=ACMR HEAD;
             [ -n "$BASE" ] && git -c core.quotepath=false diff --name-only --diff-filter=ACMR "$BASE"...HEAD; } 2>/dev/null | sort -u )
# Protected-path hits need DELETED entries too: deleting a protected
# file is as much an escalation as editing it. Secret scanning keeps
# the ACMR set - removing a file is not a secret leak.
PROT_CHANGED=$( { git -c core.quotepath=false diff --name-only --diff-filter=ACMRD --cached;
                  git -c core.quotepath=false diff --name-only --diff-filter=ACMRD HEAD;
                  [ -n "$BASE" ] && git -c core.quotepath=false diff --name-only --diff-filter=ACMRD "$BASE"...HEAD; } 2>/dev/null | sort -u )
# Boundary-correct secret detection: 'token' as a bare substring
# false-flags tokenizer.py - require it as a basename or separated
# word, and cover the canonical secret filenames.
SECRETS=$(printf '%s' "$CHANGED" | grep -iE '\.(env|pem|key|pat|p12|pfx)$|(^|/)(\.env\..*|\.?env|\.envrc|ENV|id_rsa|id_dsa|id_ecdsa|id_ed25519|\.aws/credentials|\.npmrc|\.pypirc|\.netrc|secrets?|tokens?|credentials?|api_?key)$|(^|/)[^/]*[_.-]?(token|secret|credentials?|apikey|api_key)[_.-][^/]*$|(^|/)[^/]*(token|secret)s?\.(txt|json|ya?ml)$' || true)
if [ -n "$SECRETS" ]; then
  fail "secret/sensitive files in change: $SECRETS" \
       "unstage immediately - secrets never enter the repository"
else
  pass "no secret files in change"
fi

if [ -f "$PJ" ]; then
  # Malformed project.json protected_paths must escalate, not parse
  # to an empty allowlist - a broken config is itself the escalation.
  PJ_PROT_ERR=$(mktemp)
  PROT_HITS=$(PROT_CHANGED="$PROT_CHANGED" PJ="$PJ" python3 - "$PJ_PROT_ERR" <<'PY'
import json, os, sys
changed = [l for l in os.environ["PROT_CHANGED"].splitlines() if l.strip()]
try:
    protected = json.load(open(os.environ["PJ"])).get("protected_paths", [])
    if not isinstance(protected, list) or not all(isinstance(p, str) for p in protected):
        open(sys.argv[1], "w").write("protected_paths is not a list of strings")
        protected = None
except Exception as e:
    open(sys.argv[1], "w").write(str(e))
    protected = None
if protected is None:
    raise SystemExit(0)
def stripdot(p):
    # remove a literal "./" prefix only - lstrip("./") would also
    # eat leading dots and slashes (".env" -> "env").
    return p[2:] if p.startswith("./") else p
hits = []
for pp in protected:
    pp = stripdot(pp.strip().rstrip("/"))
    if not pp:
        continue
    for f in changed:
        f_norm = stripdot(f)
        # Root-relative rules only: exact path or dir/ prefix. An
        # infix (/dir/) match would let src/canon-notes trip on the
        # "canon/" rule and vice versa. Paths are LITERAL - glob
        # metacharacters match themselves.
        if f_norm == pp or f_norm.startswith(pp + "/"):
            hits.append(f)
# Exception: canon/migration_rollforward.md is a canon-sanctioned
# working file the migration gate itself requires - it does not
# escalate under the blanket "canon/" protection entry.
hits = sorted({h for h in hits if h != "canon/migration_rollforward.md"})
for h in hits:
    print(h)
PY
)
  if [ -s "$PJ_PROT_ERR" ]; then
    escalate "project.json protected_paths unreadable: $(cat "$PJ_PROT_ERR")" \
             "fix canon/project.json - protected_paths must be a JSON list of strings"
  fi
  rm -f "$PJ_PROT_ERR"
  # process substitution, NOT a pipe: a piped while runs in a
  # subshell and the escalate() counter would never reach the parent
  while IFS= read -r hit; do
    [ -n "$hit" ] && escalate "protected path modified: $hit" \
      "cite the user instruction/task that authorized this change"
  done <<< "$PROT_HITS"
fi

# 5. No stray untracked files (mid-migration scratch docs are exempt;
#    true local-only canon state is covered by .gitignore, so a new
#    untracked canon canon file still surfaces here)
UNTRACKED=$(git status --porcelain | sed -n 's/^?? //p' \
            | grep -vE '(^|/)scope_whitelist\.txt$|(^|/)migration_rollforward\.md$|(^|/)\canon/[^/]*\.lock$' || true)
[ -z "$UNTRACKED" ] \
  && pass "tree clean (no untracked)" \
  || fail "untracked files present" "commit intended ones, remove leftovers"

# 6. No open FAILURE in cycle_log. Three close conventions exist:
#    cycle_log.sh close appends a 'close' event, agent-git.md
#    documents appended resolve_<*> records, both with
#    status=closed / non-failure verdict. A historical open+failure
#    line closed by a later resolve/close event clears ONLY for the
#    same actor AND only when that event carries a non-failure
#    verdict - a second failure verdict must never mask the first.
#    Cross-actor closes count too: an orchestrator/director close
#    event (closed_by field) may clear any actor's open failure.
if [ -f "$CANON_DIR/cycle_log.jsonl" ]; then
  CYC_ERRF=$(mktemp)
  CYC_OUT=$(LOG="$CANON_DIR/cycle_log.jsonl" python3 - <<'PY' 2>"$CYC_ERRF"
import json, os, sys
open_fails = {}
corrupt = 0
for line in open(os.environ["LOG"], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        corrupt += 1
        continue
    if not isinstance(rec, dict):
        corrupt += 1
        continue
    key = (rec.get("actor"), rec.get("item"))
    verdict = rec.get("verdict")
    # failure AND escalated open records block: an unresolved
    # escalation is an open incident, not a pass.
    if rec.get("status") == "open" and verdict in ("failure", "escalated"):
        open_fails[key] = rec
        continue
    act = rec.get("action") or ""
    if act.startswith("resolve_") or act == "close":
        # Only token-authenticated clearing events count - anything
        # else can be forged via a plain append. A clearing event
        # must itself carry verdict=ok: a failure verdict must never
        # mask the first failure, and an "escalated" close means the
        # incident is still awaiting the developer, not resolved.
        if rec.get("token_authenticated") is not True:
            continue
        if verdict in ("failure", "escalated"):
            continue
        # A close/resolve event clears exactly the record it names
        # (actor,item) - for cross-actor closes the writer already
        # stamped the target actor into the record's actor field,
        # so no extra sweep is needed here.
        open_fails.pop(key, None)
for rec in open_fails.values():
    print(json.dumps(rec))
if corrupt:
    print("__CORRUPT_LINES__%d" % corrupt, file=sys.stderr)
PY
)
  if grep -q __CORRUPT_LINES__ "$CYC_ERRF" 2>/dev/null; then
    echo "NOTE: cycle_log has $(grep -o 'CORRUPT_LINES__[0-9]*' "$CYC_ERRF" | tail -c +17) corrupt line(s)"
  fi
  rm -f "$CYC_ERRF"
  [ -z "$CYC_OUT" ] \
    && pass "cycle_log has no open failures" \
    || fail "open failure events in cycle_log" "resolve or close them"
elif [ -n "$VERIFY_PR" ]; then
  # Detached PR verification without a local log: note it instead of
  # silently skipping - a check that cannot run is not a check that
  # passed.
  echo "NOTE: no cycle_log in this worktree - open-failure gate has nothing to fold"
fi

# 6b. RoM fragment presence (issue #135): an issue_<N> branch must
#     carry a NEW .changes fragment in its diff vs base. The only
#     exempt branches are release/v* (the release commit consumed
#     fragments) and the documented no-changes-entry label path,
#     which repo_merge.sh validates on the PR side. Deletion-only
#     diffs do not count - the fragment must exist in the result.
if [ -n "$ISSUE_N" ] && [ -n "$BASE" ]; then
  NEW_FRAGS=$(git -c core.quotepath=false diff --name-only --diff-filter=A "$BASE"...HEAD 2>/dev/null \
              | grep -E '^\.changes/[^/]+\.md$' | grep -v '/README\.md$' || true)
  if [ -n "$NEW_FRAGS" ]; then
    pass ".changes fragment present on branch"
  else
    # The documented no-fragment paths repo_merge accepts must also
    # clear blood-sign: the PR carries a no-changes-entry label, or
    # the diff touches CHANGELOG.md.
    EXEMPT=""
    git -c core.quotepath=false diff --name-only "$BASE"...HEAD 2>/dev/null \
      | grep -qx 'CHANGELOG.md' && EXEMPT="changelog-diff"
    if [ -z "$EXEMPT" ] && [ -n "$VERIFY_PR" ] && [ "${VERIFY_PR:-0}" != "0" ]; then
      "$GH" pr view "$VERIFY_PR" --json labels --jq '.labels[].name' 2>/dev/null \
        | grep -qx 'no-changes-entry' && EXEMPT="no-changes-entry label"
    fi
    [ -n "$EXEMPT" ] \
      && pass "no .changes fragment - exempt via $EXEMPT" \
      || fail "no .changes fragment on branch" \
              "add .changes/<slug>.md with bump:/user_visible:/issue: (bump: patch|minor|major), or use the documented no-changes-entry PR label path"
  fi
fi

# 7. Spec impact anchors + fragment fields (issue #107): delegated
#    to canon/bin/spec_anchor_check.sh - the same check powers the
#    `specs` review-panel floor via gate_run.sh. Env inputs are
#    inherited: BASE/BASE_REF (diff base + base-existence proofs),
#    ISSUE_LIST/FRAG_LIST (allowed issue numbers in fragments).
if compgen -G "$TOP/.changes/*.md" >/dev/null 2>&1; then
  SPEC_OUT=$(ISSUE_LIST="$ISSUE_LIST" FRAG_LIST="${FRAG_LIST:-}" \
             CANON_DIR="$CANON_DIR" bash "$CANON_DIR/bin/spec_anchor_check.sh" 2>&1)
  SPEC_RC=$?
  case $SPEC_RC in
    0) echo "$SPEC_OUT" | grep -q 'repo adapter' \
         && pass "spec anchors (repo adapter)" \
         || pass "changes fragment fields + spec anchors (canonical)" ;;
    *) printf '%s\n' "$SPEC_OUT" | head -n 12
       fail "spec impact fragments/anchors do not resolve" \
            "fix the listed .changes fields / adds-modifies-removes targets" ;;
  esac
else
  echo "SKIP: no pending .changes entries"
fi

echo "---"
# Exit codes: 0 = all pass; 1 = failures; 2 = usage; 3 = escalations
# only. An escalation must STOP the pipeline (a nonzero exit) - the
# previous 'exit 0 with escalations' let callers treat a protected-path
# hit as a clean pass.
[ $fails -gt 0 ] && { echo "VERIFY: $fails FAILURES, $escalates ESCALATIONS"; exit 1; }
[ $escalates -gt 0 ] && { echo "VERIFY: $escalates ESCALATIONS - gate stopped, cite authorization to proceed"; exit 3; }
echo "VERIFY: ALL PASS"
