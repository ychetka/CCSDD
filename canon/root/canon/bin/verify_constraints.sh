#!/usr/bin/env bash
# verify_constraints.sh - mechanical pre-completion checks.
# PASS / FAIL (exit 1) / ESCALATE (exit 3: protected paths need
# cited authorization).
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
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
    gh issue view "$ISSUE_NUM" --json number >/dev/null 2>&1 \
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
      gh pr view "$VERIFY_PR" --json labels --jq '.labels[].name' 2>/dev/null \
        | grep -qx 'no-changes-entry' && EXEMPT="no-changes-entry label"
    fi
    [ -n "$EXEMPT" ] \
      && pass "no .changes fragment - exempt via $EXEMPT" \
      || fail "no .changes fragment on branch" \
              "add .changes/<slug>.md with bump:/user_visible:/issue:, or use the documented no-changes-entry PR label path"
  fi
fi

# 7. Spec impact anchors resolve (issue #107): every pending
#    .changes entry must declare a Spec impact section whose
#    adds/modifies anchors exist in docs/specs/ and whose removes
#    anchors are gone (the PR applies its own spec delta). Pending
#    = added/modified in the branch diff when a base is known, else
#    all fragments in the worktree.
if compgen -G "$TOP/.changes/*.md" >/dev/null 2>&1; then
  PENDING_FRAGS=$( { [ -n "$BASE" ] && git -c core.quotepath=false diff --name-only --diff-filter=ACMR "$BASE"...HEAD 2>/dev/null; } \
                   | grep -E '^\.changes/[^/]+\.md$' | grep -v '/README\.md$' || true)
  [ -z "$PENDING_FRAGS" ] && PENDING_FRAGS=$(cd "$TOP" && ls .changes/*.md 2>/dev/null | grep -v 'README\.md$' || true)
  # 7a. Mandatory fragment fields (bump / user_visible / issue) and a
  #     non-empty '## Spec impact' (adds/modifies/removes lines or the
  #     bare '-' none-marker). This check is CANONICAL contract, not
  #     adapter policy - it must run even when tools/check_spec_anchors.sh
  #     owns anchor resolution, or an adapter-only repo can merge
  #     fragments missing required metadata. Fields are read from the
  #     leading frontmatter zone only.
  FIELD_BAD=$(TOP="$TOP" PENDING_FRAGS="$PENDING_FRAGS" ISSUE_LIST="$ISSUE_LIST $FRAG_LIST" python3 - <<'PY'
import os, re
top = os.environ["TOP"]
frags = [l.strip() for l in os.environ.get("PENDING_FRAGS","").splitlines() if l.strip()]
issue_list = set(os.environ.get("ISSUE_LIST","").split())
bad = []

def front_fields(body):
    # Leading YAML-ish zone only: an optional opening '---' fence, then
    # key: value lines until a non-field line or the closing '---'.
    # Parsing must STOP at the closing delimiter - body text that
    # happens to look like 'key: value' is not frontmatter.
    fields = {}
    lines = body.splitlines()
    start = 1 if lines and lines[0].strip() == "---" else 0
    for ln in lines[start:]:
        s = ln.strip()
        if not s:
            continue
        if s == "---":
            break
        m = re.match(r"^([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*)$", s)
        if not m:
            break
        fields[m.group(1).lower()] = m.group(2).strip().strip('"').strip("'")
    return fields

for rel in frags:
    path = os.path.join(top, rel)
    if not os.path.isfile(path):
        continue
    body = open(path, encoding="utf-8", errors="replace").read()
    name = os.path.basename(path)
    flds = front_fields(body)
    if flds.get("bump") not in ("patch","minor","major"):
        bad.append(f"{name}: missing/invalid 'bump: patch|minor|major'")
    if flds.get("user_visible") not in ("true","false"):
        bad.append(f"{name}: missing 'user_visible: true|false'")
    iss = flds.get("issue","")
    if not re.fullmatch(r"\d+(\s*,\s*\d+)*", iss or ""):
        bad.append(f"{name}: missing 'issue: <N>'")
    elif issue_list and not set(re.findall(r"\d+", iss)) & issue_list:
        bad.append(f"{name}: 'issue:' {iss} does not match the branch/linked issues")
    m = re.search(r"(?im)^#+\s*spec impact\s*$", body)
    if not m:
        bad.append(f"{name}: missing mandatory '## Spec impact' section")
        continue
    sec = body[m.end():]
    nxt = re.search(r"(?m)^#", sec)
    if nxt:
        sec = sec[:nxt.start()]
    has_lines = re.search(
        r"(?im)^\s*(?:-\s*)?(adds|modifies|removes)\s*:\s*\S", sec)
    if not has_lines and not re.search(
            r"(?im)^\s*-\s*(none|n/a)?\s*$", sec):
        bad.append(f"{name}: '## Spec impact' declares no "
                   f"adds/modifies/removes lines and no '-' none-marker")
for b in bad:
    print(b)
PY
)
  if [ -n "$FIELD_BAD" ]; then
    printf '%s\n' "$FIELD_BAD" | sed 's/^/  fragment: /'
    fail "changes fragment field validation" \
         "fix the listed .changes fields / Spec impact section"
  else
    pass "changes fragment fields"
  fi
  # 7b. Anchor resolution - the repo adapter (if present and taken
  #     from the BASE ref, never the PR/worktree copy) first, then the
  #     canonical fallback below.
  ADAPTER_OUT=""
  ADAPTER_RC=127
  if [ -n "$BASE" ] && git cat-file -e "$BASE_REF:tools/check_spec_anchors.sh" 2>/dev/null; then
    ADP=$(mktemp)
    git show "$BASE_REF:tools/check_spec_anchors.sh" > "$ADP" 2>/dev/null
    ADAPTER_OUT=$(cd "$TOP" && PENDING_FRAGS="$PENDING_FRAGS" bash "$ADP" 2>&1 | tail -n 5)
    ADAPTER_RC=$?
    rm -f "$ADP"
  elif [ -x "$CANON_DIR/tools/check_spec_anchors.sh" ]; then
    ADAPTER_OUT=$(cd "$TOP" && PENDING_FRAGS="$PENDING_FRAGS" bash "$CANON_DIR/tools/check_spec_anchors.sh" 2>&1 | tail -n 5)
    ADAPTER_RC=$?
  fi
  if [ $ADAPTER_RC -ne 127 ]; then
    if [ $ADAPTER_RC -eq 0 ]; then
      pass "spec anchors (repo adapter)"
    else
      printf '%s\n' "$ADAPTER_OUT" | sed 's/^/  adapter: /'
      fail "Spec impact anchors do not resolve" \
           "fix the listed refs per tools/check_spec_anchors.sh"
    fi
  else
    # Canonical fallback (no repo adapter): every pending fragment's
    # Spec impact anchors are checked here - adds/modifies targets
    # must exist under docs/specs/ in the working tree after the
    # change; removes targets must be gone (file or anchor) and must
    # have existed at the base.
    TOP="$TOP" PENDING_FRAGS="$PENDING_FRAGS" BASE="$BASE" BASE_REF="$BASE_REF" python3 - <<'PY'
import os, re, subprocess, sys
top = os.environ["TOP"]
base_ref = os.environ.get("BASE_REF") or ""
frags = [l.strip() for l in os.environ.get("PENDING_FRAGS","").splitlines() if l.strip()]
bad = []

def gh_anchor(heading):
    # GitHub-style anchor: lowercase, drop punctuation, spaces->dash.
    return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")

def strip_fenced(body):
    # headings inside ``` fenced blocks are not real anchors
    return re.sub(r"```[\s\S]*?```", "", body)

def collect_anchors(body):
    # Full anchor set of a markdown body: GitHub-style heading slugs
    # (with -1/-2 duplicate suffixes), <a name|id="x"> and {#id}.
    anchors = set()
    seen = {}
    for l in body.splitlines():
        if l.startswith("#"):
            h = gh_anchor(l.lstrip("# ").strip())
            n = seen.get(h, 0)
            seen[h] = n + 1
            anchors.add(h if n == 0 else "%s-%d" % (h, n))
    anchors |= set(re.findall(r'(?:name|id)\s*=\s*["\']([^"\']+)["\']', body))
    anchors |= set(re.findall(r"\{#([^}\s]+)\}", body))
    return {a.lower() for a in anchors}

def anchor_resolves(path, anchor):
    if not os.path.isfile(path):
        return False
    body = strip_fenced(open(path, encoding="utf-8", errors="replace").read())
    return anchor.lower() in collect_anchors(body)

def existed_at_base(rel, anchor):
    if not base_ref:
        return True   # no base known - cannot prove; do not fail on this
    r = subprocess.run(["git","show",base_ref+":"+rel],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return False
    if not anchor:
        return True
    # Same collection rules as the worktree check - an {#id} or
    # duplicate-suffixed anchor must resolve at base too.
    return anchor.lower() in collect_anchors(strip_fenced(r.stdout))

for rel in frags:
    path = os.path.join(top, rel)
    if not os.path.isfile(path):
        continue
    body = open(path, encoding="utf-8", errors="replace").read()
    name = os.path.basename(path)
    m = re.search(r"(?im)^#+\s*spec impact\s*$", body)
    if not m:
        continue
    sec = body[m.end():]
    nxt = re.search(r"(?m)^#", sec)
    if nxt:
        sec = sec[:nxt.start()]
    lines = re.findall(
        r"(?im)^\s*(?:-\s*)?(adds|modifies|removes)\s*:\s*(.+)$", sec)
    for kind, targets in lines:
        for t in re.split(r"[,\s]+", targets.strip()):
            t = t.strip().strip("`")
            if not t or t.lower() in ("none", "-", "n/a"):
                continue
            file_part, _, anchor = t.partition("#")
            # Spec anchors live under docs/specs/ by contract - and
            # stay there after normalization: 'docs/specs/../x.md'
            # must not reach outside via a text-level prefix match.
            norm_fp = os.path.normpath(file_part)
            if (not file_part.startswith("docs/specs/")
                    or not norm_fp.startswith("docs/specs/")
                    or os.path.isabs(file_part)):
                bad.append(f"{name}: {kind} target outside docs/specs/: {t}")
                continue
            p = os.path.join(top, norm_fp)
            if kind in ("adds", "modifies"):
                if not os.path.isfile(p):
                    bad.append(f"{name}: {kind} target missing: {t}")
                elif os.path.isdir(p):
                    bad.append(f"{name}: {kind} target is a directory: {t}")
                elif not anchor:
                    bad.append(f"{name}: {kind} needs an explicit '#anchor': {t}")
                elif not anchor_resolves(p, anchor):
                    bad.append(f"{name}: {kind} anchor '#{anchor}' "
                               f"does not resolve in {file_part}")
                elif kind == "modifies" and not existed_at_base(norm_fp, anchor):
                    bad.append(f"{name}: modifies anchor '#{anchor}' "
                               f"never existed at base in {norm_fp}")
            if kind == "removes":
                still = (anchor_resolves(p, anchor) if anchor
                         else os.path.exists(p))
                if still:
                    bad.append(f"{name}: removes target still present: {t}")
                elif not existed_at_base(norm_fp, anchor):
                    bad.append(f"{name}: removes target never existed at base: {t}")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
    case $? in
      0) pass "spec anchors (canonical fallback)" ;;
      *) fail "Spec impact anchors do not resolve" \
              "fix the listed adds/modifies/removes targets in .changes fragments" ;;
    esac
  fi
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
