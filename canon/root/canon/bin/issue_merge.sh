#!/usr/bin/env bash
# issue_merge.sh - merge an issue_<N>-<slug> PR behind the objective
# gate. Invoked by repo_merge.sh (the head-branch dispatcher); call
# repo_merge.sh, never this script directly - epic_issue_<N>-<slug>
# heads carry an extra completeness gate in epic_merge.sh.
# Usage: issue_merge.sh <pr_number> <expected_head_sha> [squash|merge|rebase]
# Gate: APPROVED review by EVERY expected reviewer on the head sha +
# all required checks green + head sha match + .changes entry/bump +
# no manual_gate fragment + blood-sign (canonical verify scripts on
# the PR tree) + RoM version-drift check. Output JSON:
# {status: merged|blocked|error, gate_report?}
set -uo pipefail
# CANON_DIR resolves from the script location, not the git top: in
# nested workspaces the git top may be a subdir like code/ while
# canon/ lives at the workspace root.
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"

json_error() {
  python3 -I -c 'import json,sys;print(json.dumps({"status":"error","failure_class":sys.argv[1],"message":sys.argv[2]}))' "$1" "$2"
  exit 1
}

PR="${1:-}"
EXPECTED="${2:-}"
METHOD="${3:-squash}"
[[ "$PR" =~ ^[0-9]+$ ]] || json_error malformed_input "pr_number must be a positive integer"
[[ "$EXPECTED" =~ ^[0-9a-f]{40}$ ]] || json_error malformed_input "expected head sha must be a 40-char hex string"
case "$METHOD" in
  squash|merge|rebase) ;;
  *) json_error malformed_input "merge method must be squash|merge|rebase" ;;
esac

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/repo-merge.XXXXXX")
WT=""
cleanup() {
  [ -n "$WT" ] && { git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT" 2>/dev/null; }
  rm -rf "$TMPD" 2>/dev/null
}
trap cleanup EXIT INT TERM

# GitHub CLI resolution: merge.gh_bin from the deployed project.json
# may name an alternate basename (wrapper binary); anything else -
# paths, undeclared names - would run an arbitrary binary under the
# merge credentials. Resolution happens BEFORE any gh use.
GH=$("$CANON_DIR/bin/gh_id.sh" merge)
[ -n "$GH" ] || json_error malformed_input "merge.gh_bin in project.json is not a bare binary basename"
command -v "$GH" >/dev/null 2>&1 || json_error upstream_error "github cli '$GH' not found on PATH"

# Fetch PR metadata once; stdout/stderr kept separate so a warning on
# stderr can never corrupt the JSON payload. reviewRequests comes
# along: a reviewer whose review was re-requested holds no standing
# approval.
INFO_ERR="$TMPD/info.err"
INFO=$("$GH" pr view "$PR" --json headRefOid,headRefName,baseRefName,mergeable,reviews,statusCheckRollup,mergeStateStatus,labels,author,body,reviewRequests 2>"$INFO_ERR") || {
  json_error upstream_error "$(cat "$INFO_ERR" 2>/dev/null | head -c 300)"
}
# A nonzero exit kills the gate; stderr alone does not - gh prints
# periodic upgrade notices there while still succeeding.
printf '%s' "$INFO" > "$TMPD/info.json"
INFO_FILE="$TMPD/info.json"

BASE=$(INFO_FILE="$INFO_FILE" python3 -I -c 'import json,os;print(json.load(open(os.environ["INFO_FILE"])).get("baseRefName") or "")')
HEAD_BRANCH=$(INFO_FILE="$INFO_FILE" python3 -I -c 'import json,os;print(json.load(open(os.environ["INFO_FILE"])).get("headRefName") or "")')
PR_AUTHOR=$(INFO_FILE="$INFO_FILE" python3 -I -c 'import json,os;print(((json.load(open(os.environ["INFO_FILE"])).get("author") or {}).get("login")) or "")')
# Epic heads carry the completeness gate in epic_merge.sh - a direct
# call here would silently skip it. Route through repo_merge.sh;
# epic_merge.sh marks the delegated call with EPIC_GATE_PASSED.
[[ "$HEAD_BRANCH" =~ ^epic_issue_ ]] && [ "${EPIC_GATE_PASSED:-}" != "1" ] \
  && json_error gate_blocked "epic head '$HEAD_BRANCH' must merge via repo_merge.sh -> epic_merge.sh"
[[ "$BASE" =~ ^[A-Za-z0-9._/-]+$ ]] || json_error malformed_input "unexpected base ref name: $BASE"
[ -n "$BASE" ] || json_error upstream_error "baseRefName missing from PR metadata"

# Resolve remote + fetch base (explicit refspec so single-branch
# clones update remote-tracking too) and the expected head BEFORE any
# diff gate: every three-dot diff below must run against the fetched
# $REMOTE/$BASE, never a stale local ref or a hard-coded 'origin'.
# The gate must fetch/diff against the forge repo.
# Remote: prefer the remote whose URL ends with the project.json
# repo slug (forge-agnostic - works for github/gitlab/custom hosts),
# then any forge-looking URL; 'origin' is only the last resort.
REPO_SLUG=$(CANON_DIR="$CANON_DIR" python3 -I -c 'import json,os
try: print((json.load(open(os.path.join(os.environ["CANON_DIR"],"project.json"))).get("repo") or "").strip("/"))
except Exception: print("")' 2>/dev/null)
REMOTE=""
if [ -n "$REPO_SLUG" ]; then
  REMOTE=$(git remote -v | awk -v s="$REPO_SLUG" '$2 ~ ("(^|[:/])" s "(\\.git)?$") {print $1; exit}')
fi
[ -z "${REMOTE:-}" ] && REMOTE=$(git remote -v | awk '$2 ~ /github\.com|gitlab\./ {print $1; exit}')
[ -z "${REMOTE:-}" ] && REMOTE=$(git remote get-url origin >/dev/null 2>&1 && echo origin)
[ -n "${REMOTE:-}" ] || json_error upstream_error "no forge remote for project repo slug"
git fetch "$REMOTE" "+refs/heads/$BASE:refs/remotes/$REMOTE/$BASE" --tags >/dev/null 2>&1 || {
  json_error upstream_error "fetch of base failed - refusing to gate on stale refs"
}
git fetch "$REMOTE" "$EXPECTED" >/dev/null 2>&1 || {
  json_error upstream_error "cannot fetch PR head sha"
}

# Capture the pre-merge base head BEFORE merging.
PRE_MERGE_SHA=$(git rev-parse --verify -q "$REMOTE/$BASE" 2>/dev/null || true)
[ -n "$PRE_MERGE_SHA" ] || \
  json_error upstream_error "cannot resolve pre-merge base sha - refusing to merge"

# Repo default branch (for ~DEFAULT_BRANCH ruleset matching).
DEFAULT_BRANCH=$("$GH" repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo "")

# Stack-neutral version probe - shared canonical resolver.
VER_AT() { bash "$CANON_DIR/bin/repo_version_at.sh" "$1" 2>/dev/null; }

# Version file declared in project.json (version.file); used for the
# release-PR provenance allowlist.
VFILE_CFG=$(CANON_DIR="$CANON_DIR" python3 -I -c 'import json,os
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
    print(((pj.get("version") or {}).get("file")) or "")
except Exception:
    print("")' 2>/dev/null)

# release/v<X.Y.Z> PRs are produced by repo_release.sh when the base
# is protected. A branch NAME alone is attacker-controlled, so the
# exemption requires provenance: head commit subject is exactly
# "release: vX.Y.Z" and the PR diff touches only {version file,
# CHANGELOG.md, .changes/**}.
IS_RELEASE_PR=0
if [[ "$HEAD_BRANCH" =~ ^release/v([0-9]+\.[0-9]+\.[0-9]+)(-r[0-9a-zA-Z]+)?$ ]]; then
  REL_VER="${BASH_REMATCH[1]}"
  HEAD_SUBJ=$(git log -1 --format=%s "$EXPECTED" 2>/dev/null || true)
  # Provenance must cover the WHOLE PR: the head subject alone is
  # forgeable - the release PR is exactly ONE commit on top of the
  # pre-merge base. Extra commits (tampered helper commits riding on
  # a release PR) disqualify the exemption.
  REL_N_COMMITS=$(git rev-list --count "$PRE_MERGE_SHA..$EXPECTED" 2>/dev/null || echo 0)
  if [ "$HEAD_SUBJ" = "release: v$REL_VER" ] && [ "$REL_N_COMMITS" = "1" ]; then
    PROV_OK=$(TOP="$TOP" PRE_MERGE_SHA="$PRE_MERGE_SHA" EXPECTED="$EXPECTED" \
              VFILE_CFG="$VFILE_CFG" python3 -I - <<'PY'
import os, subprocess
top = os.environ["TOP"]
vfile = os.environ.get("VFILE_CFG") or ""
names = subprocess.run(
    ["git","-C",top,"diff","--name-only",
     os.environ["PRE_MERGE_SHA"]+"..."+os.environ["EXPECTED"]],
    capture_output=True, text=True)
if names.returncode != 0:
    print("no"); raise SystemExit(0)
allowed_prefixes = (".changes/",)
allowed_exact = {"CHANGELOG.md"}
if vfile:
    allowed_exact.add(vfile)
else:
    # No declared version.file: the release commit touches the file
    # the version resolver would autodetect (repo_version_set.sh §3,
    # same candidate order). Resolve it against the PRE-MERGE base
    # content - presence alone is not enough, the version pattern
    # must match, exactly like the writer checks.
    import re
    pre = os.environ["PRE_MERGE_SHA"]
    candidates = [
        ("pyproject.toml", r'(?ms)^\[project\](?:(?!^\[).)*?^\s*version\s*=\s*["\'][^"\']+["\']'),
        ("package.json",   r'"version"\s*:\s*"[^"]+"'),
        ("Cargo.toml",     r'(?ms)^\[package\](?:(?!^\[).)*?^\s*version\s*=\s*["\'][^"\']+["\']'),
    ]
    found = ""
    for path, pat in candidates:
        body = subprocess.run(
            ["git","-C",top,"show",pre+":"+path],
            capture_output=True, text=True)
        if body.returncode == 0 and re.search(pat, body.stdout):
            found = path
            break
    if not found:
        body = subprocess.run(["git","-C",top,"cat-file","-e",pre+":VERSION"],
                              capture_output=True)
        if body.returncode == 0:
            found = "VERSION"
        else:
            body = subprocess.run(["git","-C",top,"show",pre+":setup.cfg"],
                                  capture_output=True, text=True)
            if body.returncode == 0 and re.search(
                    r'(?ms)^\[metadata\](?:(?!^\[).)*?^\s*version\s*=\s*\S+',
                    body.stdout):
                found = "setup.cfg"
    if found:
        allowed_exact.add(found)
    # A repo adapter (canon/version_source.sh) makes the written file
    # opaque to this gate - such repos must declare version.file in
    # project.json for the release-PR provenance to resolve
    # (fail-closed otherwise).
bad = [f.strip() for f in names.stdout.splitlines()
       if f.strip()
       and f.strip() not in allowed_exact
       and not f.strip().startswith(allowed_prefixes)]
print("yes" if not bad else "no")
PY
)
    [ "$PROV_OK" = "yes" ] && IS_RELEASE_PR=1
  fi
  if [ "$IS_RELEASE_PR" != "1" ]; then
    # A non-provenance release/v* PR is treated as a REGULAR PR: the
    # fragment/issue scans apply in full (fail-closed).
    IS_RELEASE_PR=0
  fi
fi

# Required checks lookup: classic branch protection AND rulesets are
# independent sources - the gate must union both, never fall back
# only when classic returns 404 (mixed-protection repos enforce
# checks that live only in rulesets). A failed lookup for another
# reason (auth/5xx) fails CLOSED.
BASE_ENC=$(python3 -I -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1], safe=""))' "$BASE")
REQUIRED=""
REQUIRED_LOOKUP_FAILED=0
PROT_ERR="$TMPD/prot.err"
if ! REQUIRED=$("$GH" api "repos/{owner}/{repo}/branches/${BASE_ENC}/protection/required_status_checks" \
  --jq '[.contexts[]?, .checks[]?.context] | unique | .[]' 2>"$PROT_ERR"); then
  PROT_MSG=$(cat "$PROT_ERR" 2>/dev/null)
  case "$PROT_MSG" in
    *404*|*"Not Found"*|*"Branch not protected"*|*"Branch is not protected"*)
      REQUIRED="" ;;
    *) REQUIRED_LOOKUP_FAILED=1; REQUIRED="" ;;
  esac
fi
# Rulesets always apply on top of classic protection - including
# org-level rulesets (includes_parents), whose detail documents live
# on the org endpoint (source_type-aware dispatch).
RULESET_REQ=$(BASE="$BASE" DEFAULT_BRANCH="$DEFAULT_BRANCH" GH="$GH" python3 -I - <<'PY'
import json, os, re, subprocess, sys
base = os.environ["BASE"]
default_branch = os.environ.get("DEFAULT_BRANCH") or ""

def gh(path):
    r = subprocess.run([os.environ["GH"], "api", path, "--paginate"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("__LOOKUP_FAILED__")
        sys.exit(2)
    try:
        return json.loads(r.stdout or "[]")
    except Exception:
        print("__LOOKUP_FAILED__")
        sys.exit(2)

def gh_pat_to_regex(pat):
    # GitHub ref_name globs: '**' crosses '/', '*' does not, '?' one
    # char. '**/' also matches zero path segments.
    out, i = [], 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out.append("(?:.*/)?"); i += 3
        elif pat.startswith("**", i):
            out.append(".*"); i += 2
        elif pat[i] == "*":
            out.append("[^/]*"); i += 1
        elif pat[i] == "?":
            out.append("[^/]"); i += 1
        else:
            out.append(re.escape(pat[i])); i += 1
    return "^" + "".join(out) + "$"

def pat_match(p, branch):
    if p.startswith("refs/heads/"):
        p = p[len("refs/heads/"):]
    else:
        return False
    return re.match(gh_pat_to_regex(p), branch) is not None

def ref_matches(cond, branch):
    if not cond:
        return True
    rn = cond.get("ref_name") or {}
    inc = rn.get("include") or ["~ALL"]
    exc = rn.get("exclude") or []
    hit = False
    for p in inc:
        if p == "~ALL":
            hit = True
        elif p == "~DEFAULT_BRANCH":
            hit = hit or (default_branch and branch == default_branch)
        elif p.startswith("~"):
            pass
        elif pat_match(p, branch):
            hit = True
    if not hit:
        return False
    for p in exc:
        if p == "~ALL" or (p == "~DEFAULT_BRANCH" and branch == default_branch) \
           or pat_match(p, branch):
            return False
    return True

contexts = set()
rs_list = gh("repos/{owner}/{repo}/rulesets?includes_parents=true")
if not isinstance(rs_list, list):
    print("__LOOKUP_FAILED__"); sys.exit(2)
for rs in rs_list:
    rid = rs.get("id")
    if not rid:
        continue
    if rs.get("source_type") == "Organization":
        d = gh(f"orgs/{{owner}}/rulesets/{rid}")
    else:
        d = gh(f"repos/{{owner}}/{{repo}}/rulesets/{rid}")
    if not isinstance(d, dict):
        continue
    if d.get("enforcement") in ("disabled", "evaluate"):
        continue   # evaluate = dry-run mode, must not gate
    if d.get("target") not in (None, "branch"):
        continue
    if not ref_matches(d.get("conditions") or {}, base):
        continue
    for rule in d.get("rules") or []:
        if rule.get("type") != "required_status_checks":
            continue
        for c in (rule.get("parameters") or {}).get("required_status_checks") or []:
            ctx = c.get("context")
            if ctx:
                contexts.add(ctx)
for c in sorted(contexts):
    print(c)
PY
)
RC_RULESET=$?
if [ $RC_RULESET -ne 0 ] || printf '%s' "$RULESET_REQ" | grep -q "__LOOKUP_FAILED__"; then
  REQUIRED_LOOKUP_FAILED=1
elif [ -n "$RULESET_REQ" ]; then
  REQUIRED=$(printf '%s\n%s\n' "$REQUIRED" "$RULESET_REQ" | awk NF | sort -u)
fi

# Expected reviewer logins: the repo MUST declare them in
# canon/project.json (review.reviewer_logins). A caller-supplied env
# override would let the merge caller decide whose approvals count -
# the binding must come from project state, not from the caller's
# environment. No project-agnostic default exists: an unset reviewer
# list must never degrade to "zero approvals needed" - the gate
# fails closed instead.
REVIEWERS_RAW=$(CANON_DIR="$CANON_DIR" python3 -I -c 'import json,os
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
    rev = pj.get("review") or {}
    # Union both declarations - same rule as panel_gate.sh: a login
    # present only under reviewer_profiles is still an expected
    # reviewer, or a profiles-only config would zero the gate.
    if "reviewer_logins" in rev or "reviewer_profiles" in rev:
        print("\x01")          # key present marker
        seen = []
        for x in (rev.get("reviewer_logins") or []):
            x = str(x)
            if x not in seen: seen.append(x)
        rp = rev.get("reviewer_profiles") or {}
        if isinstance(rp, dict):
            for x, prof in rp.items():
                # high_risk_only profiles are bound to risk:high
                # fragments via the model-family rule below - they
                # must not become expected reviewers on every PR or
                # a second-family account would deadlock all normal
                # merges on missing_approvals.
                if isinstance(prof, dict) and prof.get("high_risk_only") is True:
                    continue
                if x not in seen: seen.append(x)
        print("\n".join(seen))
except Exception:
    print("")' 2>/dev/null || true)
if printf '%s' "$REVIEWERS_RAW" | head -n1 | grep -q $'\x01'; then
  REVIEWERS=$(printf '%s' "$REVIEWERS_RAW" | tail -n +2 | awk 'NF' | paste -sd, -)
  [ -n "$REVIEWERS" ] || json_error malformed_input "project.json review.reviewer_logins/reviewer_profiles present but empty - no expected reviewers, gate refuses"
else
  json_error malformed_input "no reviewers configured - set review.reviewer_logins or review.reviewer_profiles in canon/project.json"
fi

# Paginated review fetch: gh pr view --json reviews truncates at 100.
# Reviews are keyed by (login, id) - id ordering breaks submittedAt
# ties; commit_id binds the verdict to a head sha.
REVIEWS_ERR="$TMPD/reviews.err"
"$GH" api "repos/{owner}/{repo}/pulls/${PR}/reviews?per_page=100" --paginate \
  --jq '.[] | @json' > "$TMPD/reviews.jsonl" 2>"$REVIEWS_ERR" || {
    json_error upstream_error "reviews fetch failed: $(head -c 200 "$REVIEWS_ERR")"
}
REVIEWS_FILE="$TMPD/reviews.jsonl"

# Blood-sign worktree at the expected head is created early: the
# fragment/flag scans and repo adapters run inside it so every check
# sees the PR tree - while any executable adapter itself is taken
# from deployed canon (canon/tools/) or the BASE ref, never from
# the PR tree (untrusted code must not run in gate context).
WT=$(mktemp -d "${TMPDIR:-/tmp}/repo-merge-verify.XXXXXX")
git worktree add --detach "$WT" "$EXPECTED" >/dev/null 2>&1 || {
  rm -rf "$WT"; WT=""
  json_error upstream_error "verify worktree add failed - merge blocked (blood-sign cannot run)"
}

ADAPTER=""
if [ -x "$CANON_DIR/tools/check_changes_entry.sh" ]; then
  ADAPTER="$CANON_DIR/tools/check_changes_entry.sh"
elif git cat-file -e "$REMOTE/$BASE:tools/check_changes_entry.sh" 2>/dev/null; then
  ADAPTER="$TMPD/check_changes_entry.sh"
  git show "$REMOTE/$BASE:tools/check_changes_entry.sh" > "$ADAPTER" 2>/dev/null || ADAPTER=""
fi

# Frontmatter-style field extraction: contract fields (bump:,
# manual_gate:, ci_bootstrap:) are only honored from the leading
# key:value zone of a fragment - never from body text/code blocks.
ENTRY=""
if [ "$IS_RELEASE_PR" = "1" ]; then
  ENTRY='{"status":"pass","via":"release-pr"}'
elif [ -n "$ADAPTER" ]; then
  ADP_OUT=$(cd "$WT" && bash "$ADAPTER" --pr "$PR" 2>&1 | tail -n 1)
  ENTRY="$ADP_OUT"
  printf '%s' "$ENTRY" | python3 -I -c 'import json,sys
try: json.load(sys.stdin)
except Exception: print("bad")' | grep -q bad && \
    ENTRY='{"status":"error","detail":"adapter returned non-JSON output"}'
else
  FRAG_SCAN=$(TOP="$TOP" REMOTE="$REMOTE" BASE="$BASE" EXPECTED="$EXPECTED" INFO_FILE="$INFO_FILE" HEAD_BRANCH="$HEAD_BRANCH" python3 -I - <<'PY'
import json, os, re, subprocess
top = os.environ["TOP"]
base_ref = os.environ["REMOTE"] + "/" + os.environ["BASE"]
head = os.environ["EXPECTED"]
d = json.load(open(os.environ["INFO_FILE"]))
names = subprocess.run(
    ["git","-C",top,"-c","core.quotepath=false","diff","--name-only",
     "--diff-filter=ACMR", base_ref + "..." + head],
    capture_output=True, text=True)
if names.returncode != 0:
    print(json.dumps({"status":"fail","via":"diff-fallback",
        "detail":"diff %s...%s failed: %s" % (base_ref, head, names.stderr.strip()[:200])}))
    raise SystemExit(0)
files = [ln.strip() for ln in names.stdout.splitlines() if ln.strip()]
frags = [f for f in files
         if f.startswith(".changes/") and f.endswith(".md")
         and not f.endswith("/README.md")]
has_changelog = "CHANGELOG.md" in files
labels = {((l or {}).get("name") or "") for l in (d.get("labels") or [])}

def front_fields(body):
    # leading key:value zone only (optionally --- fenced); stops at
    # the closing '---' or the first non-field line so body/code-block
    # text can't inject contract fields.
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

SEV = {"patch":0,"minor":1,"major":2}
bumps, bad, manual_gate, ci_bootstrap, risk_high = [], [], False, False, False
iss_missing, iss_bad, frag_issues = [], [], {}
for f in frags:
    body = subprocess.run(["git","-C",top,"show",head+":"+f],
                          capture_output=True, text=True).stdout
    flds = front_fields(body)
    b = flds.get("bump","")
    if b in SEV:
        bumps.append(b)
    else:
        bad.append(f)
    iss = (flds.get("issue") or "").strip()
    # Natural forms (harness.md): 'issue: 10', 'issue: #10',
    # 'issue: 10, 11', 'issue: "10"' - extract every number
    # independently; a trailing ' #comment' is not an issue ref.
    nums = set(re.findall(r"#?(\d+)",
                          re.sub(r"\s+#(?!\d).*$", "", iss)))
    if not nums:
        iss_missing.append(f)
    else:
        frag_issues.setdefault(f, nums)
    manual_gate = manual_gate or flds.get("manual_gate") == "true"
    ci_bootstrap = ci_bootstrap or flds.get("ci_bootstrap") == "true"
    risk_high = risk_high or flds.get("risk") == "high"

# Correspondence check: the fragment's issue: field must name an
# issue this PR is about. Allowed set = the issue_<N>/epic_issue_<N>
# of the head branch UNION every #N ref in the PR body (an epic PR
# legitimately carries fragments whose issue: names the merged task
# issues). A fragment pointing outside the set is a release/journal
# forgery; a missing field violates the mandatory fragment contract
# (harness.md branch/fragment section).
allowed = set()
m = re.match(r"^(?:epic_)?issue_(\d+)(?:[-_]|$)", os.environ.get("HEAD_BRANCH") or "")
if m:
    allowed.add(m.group(1))
allowed.update(re.findall(r"#(\d+)", d.get("body") or ""))
if allowed:
    # every issue number the fragment names must be in the allowed
    # set (a list like 'issue: 10, 11' is legal only when BOTH are
    # covered by the branch/body)
    iss_bad = [f for f, nums in frag_issues.items()
               if not nums <= allowed]

flags = {"bumps": bumps,
         "manual_gate": manual_gate,
         "ci_bootstrap": ci_bootstrap,
         "risk_high": risk_high}
if bad:
    entry = {"status":"blocked","failure_class":"malformed_input",
             "message":"changes fragment(s) lack a valid 'bump: patch|minor|major' field",
             "fragments": bad}
elif iss_missing:
    entry = {"status":"blocked","failure_class":"missing_issue_field",
             "message":"changes fragment(s) lack the mandatory 'issue:' field",
             "fragments": iss_missing}
elif iss_bad:
    entry = {"status":"blocked","failure_class":"issue_mismatch",
             "message":"fragment issue: is not the head-branch issue nor referenced in the PR body",
             "fragments": iss_bad}
elif frags:
    entry = {"status":"pass","via":"fragment"}
elif "no-changes-entry" in labels:
    entry = {"status":"pass","via":"label","implicit_bump":"patch"}
elif has_changelog:
    entry = {"status":"pass","via":"changelog","implicit_bump":"patch"}
else:
    entry = {"status":"fail","via":"diff-fallback",
             "detail":"no .changes fragment, CHANGELOG.md diff, "
                      "or no-changes-entry label"}
entry["flags"] = flags
print(json.dumps(entry))
PY
)
  ENTRY="$FRAG_SCAN"
fi

# Fragment flags are canonical contract fields - scanned from
# .changes/* in the PR diff unconditionally for non-release PRs, even
# when a repo adapter owns the entry verdict (an adapter returning
# flags:{} must not bypass manual_gate).
if [ "$IS_RELEASE_PR" != "1" ]; then
  FLAGS_SCAN=$(TOP="$TOP" REMOTE="$REMOTE" BASE="$BASE" EXPECTED="$EXPECTED" python3 -I - <<'PY'
import json, os, re, subprocess
top = os.environ["TOP"]
base_ref = os.environ["REMOTE"] + "/" + os.environ["BASE"]
head = os.environ["EXPECTED"]
names = subprocess.run(
    ["git","-C",top,"-c","core.quotepath=false","diff","--name-only",
     "--diff-filter=ACMR", base_ref + "..." + head],
    capture_output=True, text=True)
frags = [f.strip() for f in names.stdout.splitlines()
         if f.strip().startswith(".changes/") and f.strip().endswith(".md")
         and not f.strip().endswith("/README.md")]
manual_gate = ci_bootstrap = risk_high = False
bumps = []
def _fields(body):
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
for f in frags:
    body = subprocess.run(["git","-C",top,"show",head+":"+f],
                          capture_output=True, text=True).stdout
    fields = _fields(body)
    manual_gate = manual_gate or fields.get("manual_gate") == "true"
    ci_bootstrap = ci_bootstrap or fields.get("ci_bootstrap") == "true"
    risk_high = risk_high or fields.get("risk") == "high"
    if fields.get("bump") in ("patch","minor","major"):
        bumps.append(fields["bump"])
print(json.dumps({"bumps": bumps,
                  "manual_gate": manual_gate,
                  "ci_bootstrap": ci_bootstrap,
                  "risk_high": risk_high}))
PY
)
  ENTRY=$(ENTRY="$ENTRY" FLAGS_SCAN="$FLAGS_SCAN" python3 -I -c 'import json,os
raw = os.environ.get("ENTRY", "")
try: entry = json.loads(raw)
except Exception: entry = {"status": "error", "detail": raw}
try:
    fs = json.loads(os.environ["FLAGS_SCAN"])
    old = entry.get("flags") or {}
    merged = {"bumps": sorted(set(old.get("bumps") or []) | set(fs.get("bumps") or [])),
              "manual_gate": bool(old.get("manual_gate")) or bool(fs.get("manual_gate")),
              "ci_bootstrap": bool(old.get("ci_bootstrap")) or bool(fs.get("ci_bootstrap")),
              "risk_high": bool(old.get("risk_high")) or bool(fs.get("risk_high"))}
    entry["flags"] = merged
except Exception: pass
print(json.dumps(entry))')
fi

ENTRY_VIA=$(printf '%s' "$ENTRY" | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("via") or "")
except Exception: print("")')
ENTRY_OK=$(printf '%s' "$ENTRY" | python3 -I -c 'import json,sys
try: print("yes" if json.load(sys.stdin).get("status") == "pass" else "no")
except Exception: print("no")')
if [ "$ENTRY_OK" != "yes" ]; then
  ENTRY="$ENTRY" python3 -I -c 'import json,os,sys
raw = os.environ.get("ENTRY", "")
try: report = json.loads(raw)
except Exception: report = {"status": "error", "detail": raw}
print(json.dumps({"status": "blocked", "failure_class": "missing_changes_entry",
                  "gate_report": {"changes_entry": report}}))'
  exit 1
fi

# manual_gate: a fragment declaring manual_gate: true means this PR
# waits for the developer. The legal path is a human signoff
# envelope: `human_sign.sh sign --verdict approve
# --artifact <head_sha> --out canon/human_signoffs/<branch>.json`
# or the compact form `sign ... --out -` whose CCSDD-SIGNOFF-1|
# line the human pastes into the chat (remote-laptop workflow);
# either content at ENV_FILE verifies identically - the line is a
# signed envelope, not a text approval. The ssh-signed envelope
# must verify against the exact head the gate would merge (7-day
# freshness, nonce anti-replay). No envelope or a
# stale/mismatched/replayed one = blocked.
MANUAL_GATE=$(printf '%s' "$ENTRY" | python3 -I -c 'import json,sys
try:
    f = (json.load(sys.stdin).get("flags") or {})
    # risk: high implies the human-confirmation envelope too
    # (methodology: two model families PLUS developer approval).
    print("yes" if f.get("manual_gate") or f.get("risk_high") else "no")
except Exception: print("no")')
if [ "$MANUAL_GATE" = "yes" ]; then
  ENVELOPE_OK="no"
  ENV_FILE="$CANON_DIR/human_signoffs/${HEAD_BRANCH}.json"
  if [ -f "$ENV_FILE" ] \
      && "$CANON_DIR/bin/human_sign.sh" verify --envelope "$ENV_FILE" \
           --artifact "$EXPECTED" --verdict approve >/dev/null 2>&1; then
    ENVELOPE_OK="yes"
  fi
  if [ "$ENVELOPE_OK" != "yes" ]; then
    ENTRY="$ENTRY" ENV_FILE="$ENV_FILE" EXPECTED="$EXPECTED" python3 -I -c 'import json,os
raw = os.environ.get("ENTRY", "")
try: report = json.loads(raw)
except Exception: report = {}
print(json.dumps({"status": "blocked", "failure_class": "manual_gate",
                  "message": "fragment declares manual_gate: true or risk: high - developer approval required. Sign with: human_sign.sh sign --verdict approve --artifact %s --out %s (or --out - and paste the CCSDD-SIGNOFF-1 line into the chat; save it to %s)" % (os.environ.get("EXPECTED",""), os.environ.get("ENV_FILE",""), os.environ.get("ENV_FILE","")),
                  "gate_report": {"changes_entry": report}}))'
    exit 1
  fi
fi

CI_BOOTSTRAP=$(printf '%s' "$ENTRY" | python3 -I -c 'import json,sys
try: print("yes" if (json.load(sys.stdin).get("flags") or {}).get("ci_bootstrap") else "no")
except Exception: print("no")')
# Bootstrap allowance only counts when the base truly has no CI yet.
if [ "$CI_BOOTSTRAP" = "yes" ]; then
  if git ls-tree -d --name-only "$REMOTE/$BASE" .github/workflows 2>/dev/null | grep -q .; then
    CI_BOOTSTRAP="no"
  fi
fi

# mergeable=UNKNOWN is transient: GitHub computes it lazily. Retry a
# few seconds before treating it as a block.
MERGEABLE=$(INFO_FILE="$INFO_FILE" python3 -I -c 'import json,os;print(json.load(open(os.environ["INFO_FILE"])).get("mergeable") or "")')
if [ "$MERGEABLE" = "UNKNOWN" ]; then
  for _i in 1 2 3; do
    sleep 3
    MERGEABLE=$("$GH" pr view "$PR" --json mergeable --jq .mergeable 2>/dev/null || echo "")
    [ "$MERGEABLE" = "UNKNOWN" ] || break
  done
fi

# risk: high (methodology): the approval set must span TWO distinct
# model families. reviewer_profiles.<login>.model_family names the
# family; logins without a declared family share the implicit
# "default" family so two unlabeled accounts never satisfy the rule.
RISK_HIGH=$(printf '%s' "$ENTRY" | python3 -I -c 'import json,sys
try: print("yes" if (json.load(sys.stdin).get("flags") or {}).get("risk_high") else "no")
except Exception: print("no")')
FAMILY_MAP=$(CANON_DIR="$CANON_DIR" python3 -I -c 'import json,os
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
    rp = ((pj.get("review") or {}).get("reviewer_profiles") or {})
    for login, prof in rp.items():
        fam = (prof or {}).get("model_family") or "default"
        print("%s\t%s" % (str(login).strip().lower(), fam))
except Exception: pass' 2>/dev/null)
# high_risk_only logins vote on risk:high PRs only: excluded from
# expected_reviewers (an ordinary PR must not wait on them) but
# their APPROVED must reach the family set - excluding them from
# counting entirely would deadlock every risk:high merge on
# family_deficit.
HIGH_RISK_REVIEWERS=$(CANON_DIR="$CANON_DIR" python3 -I -c 'import json,os
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
    rp = ((pj.get("review") or {}).get("reviewer_profiles") or {})
    print(",".join(str(l).strip().lower() for l, p in rp.items()
                   if isinstance(p, dict) and p.get("high_risk_only") is True))
except Exception: pass' 2>/dev/null)

GATE=$(INFO_FILE="$INFO_FILE" REVIEWS_FILE="$REVIEWS_FILE" REQUIRED="$REQUIRED" \
       REQUIRED_LOOKUP_FAILED="$REQUIRED_LOOKUP_FAILED" REVIEWERS="$REVIEWERS" \
       PR_AUTHOR="$PR_AUTHOR" CI_BOOTSTRAP="$CI_BOOTSTRAP" MERGEABLE="$MERGEABLE" \
       RISK_HIGH="$RISK_HIGH" FAMILY_MAP="$FAMILY_MAP" \
       HIGH_RISK_REVIEWERS="$HIGH_RISK_REVIEWERS" \
       python3 -I - "$EXPECTED" <<'PY'
import json, sys, os
expected = sys.argv[1]
d = json.load(open(os.environ["INFO_FILE"]))
required_lookup_failed = os.environ.get("REQUIRED_LOOKUP_FAILED") == "1"
required = set(filter(None, os.environ.get("REQUIRED", "").splitlines()))
expected_reviewers = {x.strip().lower() for x in
                      os.environ.get("REVIEWERS", "").split(",") if x.strip()}
high_risk_reviewers = {x.strip().lower() for x in
                       os.environ.get("HIGH_RISK_REVIEWERS", "").split(",") if x.strip()}
pr_author = (os.environ.get("PR_AUTHOR") or "").lower()
ci_bootstrap = os.environ.get("CI_BOOTSTRAP") == "yes"
report = {}
head = d.get("headRefOid")
report["head_match"] = (head == expected)
report["mergeable"] = os.environ.get("MERGEABLE") == "MERGEABLE"
report["mergeable_state"] = os.environ.get("MERGEABLE")

# Approval binding: EVERY expected reviewer must stand APPROVED on
# the CURRENT head. Reviews by the PR author NEVER count
# (self-approve). A review whose commit_id is null is NOT bound to
# the head. COMMENTED reviews are questions, not verdicts.
# CHANGES_REQUESTED blocks the merge from ANY non-author reviewer,
# expected or not - an unexpected reviewer objecting is still an
# objection.
by_reviewer = {}
self_reviews = []
with open(os.environ["REVIEWS_FILE"]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        login = ((r.get("user") or {}).get("login") or "").lower()
        state = r.get("state") or ""
        rid = r.get("id") or 0
        commit = r.get("commit_id")
        if login == pr_author:
            if state in ("APPROVED", "CHANGES_REQUESTED"):
                self_reviews.append(login)
            continue
        if state not in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            continue
        # Latest verdict per reviewer wins - for expected AND foreign
        # reviewers alike, so a withdrawn CHANGES_REQUESTED (later
        # APPROVED/DISMISSED) does not block forever.
        cur = by_reviewer.get(login)
        if cur is None or rid > (cur.get("id") or 0):
            by_reviewer[login] = {"state": state, "id": rid, "commit_id": commit}

# A reviewer currently in reviewRequests holds no standing verdict -
# their review was re-requested (dismissed/stale), so an earlier
# APPROVED must not count until they actually re-review.
pending_reviewers = {((r.get("login") or "")).lower()
                     for r in (d.get("reviewRequests") or []) if isinstance(r, dict)}

approved_on_head = []
blocking_states = []
for login, r in by_reviewer.items():
    st = r["state"]
    rc = r.get("commit_id")
    if login not in expected_reviewers | high_risk_reviewers:
        # An unexpected reviewer objecting is still an objection -
        # but only while CHANGES_REQUESTED remains their latest state.
        if st == "CHANGES_REQUESTED":
            blocking_states.append("%s:CHANGES_REQUESTED" % login)
        continue
    if st == "APPROVED" and rc == head and login not in pending_reviewers:
        approved_on_head.append(login)
    elif st == "CHANGES_REQUESTED" or (st == "APPROVED" and rc and rc != head):
        blocking_states.append("%s:%s" % (login, st))
missing_approvals = sorted(expected_reviewers - set(approved_on_head))
# risk: high - approvals must come from >=2 distinct model families.
risk_high = os.environ.get("RISK_HIGH") == "yes"
family_map = {}
for ln in (os.environ.get("FAMILY_MAP") or "").splitlines():
    if "\t" in ln:
        k, v = ln.split("\t", 1)
        family_map[k.strip()] = v.strip() or "default"
approved_families = {family_map.get(l, "default") for l in approved_on_head}
family_ok = (not risk_high) or len(approved_families) >= 2
report["approved"] = (not missing_approvals) and not blocking_states and family_ok
report["approved_by"] = approved_on_head
report["missing_approvals"] = missing_approvals
report["blocking_reviews"] = blocking_states
report["self_reviews_ignored"] = self_reviews
report["expected_reviewers"] = sorted(expected_reviewers)
report["risk_high"] = risk_high
report["approved_model_families"] = sorted(approved_families)
if risk_high and not family_ok:
    report["family_deficit"] = (
        "risk: high requires APPROVED reviews from >=2 distinct "
        "model families (review.reviewer_profiles.<login>."
        "model_family); got %d" % len(approved_families))

checks = d.get("statusCheckRollup") or []

def check_names(c):
    n = c.get("name") or ""
    ctx = c.get("context") or ""
    return {n, ctx} - {""}

def check_green(c):
    concl = c.get("conclusion") or c.get("state") or ""
    return concl in ("SUCCESS", "success")

def req_matched(req, c):
    # Exact match on name/context, or a trailing-segment match for
    # composite check-run names ("workflow / job" satisfies a
    # required "job"). A prefix check would let "test / subjob"
    # satisfy required "test" - that direction is unsafe.
    return any(req == n or n.endswith(" / " + req) for n in check_names(c))

reported_names = set()
for c in checks:
    reported_names |= check_names(c)
if required_lookup_failed:
    missing = ["<required-status-checks lookup failed>"]
    bad = []
elif required:
    missing = sorted(r for r in required
                     if not any(req_matched(r, c) for c in checks))
    bad = [c for c in checks
           if any(req_matched(r, c) for r in required) and not check_green(c)]
else:
    missing = []
    bad = [c for c in checks if not check_green(c)]
# Fail-closed on an empty rollup EXCEPT the documented bootstrap
# path: a fragment with ci_bootstrap: true in a repo whose base has
# no .github/workflows yet (the PR introduces CI itself).
if ci_bootstrap:
    report["checks_green"] = (len(bad) == 0 and not missing)
    report["ci_bootstrap"] = True
else:
    report["checks_green"] = (len(bad) == 0 and not missing
                              and bool(required or checks))
def primary_name(c):
    return c.get("name") or c.get("context") or "?"
report["failing_checks"] = [primary_name(c) for c in bad]
report["missing_required_checks"] = missing
report["required_checks"] = sorted(required)
report["required_lookup_failed"] = required_lookup_failed
report["required_empty_fallback"] = (not required) or required_lookup_failed
report["actual_head"] = head
print(json.dumps(report))
PY
)

OK=$(printf '%s' "$GATE" | python3 -I -c 'import json,sys
try: g=json.load(sys.stdin)
except Exception: print("no"); raise SystemExit(0)
print("yes" if all([g["head_match"],g["mergeable"],g["approved"],g["checks_green"]]) else "no")')

if [ "$OK" != "yes" ]; then
  printf '%s' "$GATE" | python3 -I -c 'import json,sys
try: g=json.load(sys.stdin)
except Exception: g={"head_match":False,"unparseable_gate_report":True}
fc="stale_head" if not g["head_match"] else "gate_blocked";print(json.dumps({"status":"blocked","failure_class":fc,"gate_report":g}))'
  exit 1
fi

# RoM version-drift gate: a non-release PR must NOT change the
# declared version on head vs base - Release-on-Merge owns bumps.
# A release/v* PR MUST carry exactly the branch version.
if [ "$IS_RELEASE_PR" != "1" ]; then
  VER_HEAD=$(VER_AT "$EXPECTED")
  VER_BASE=$(VER_AT "$PRE_MERGE_SHA")
  # Drift covers removal too: a PR deleting the version source
  # (VER_HEAD empty while base has one) is the same violation.
  if [ -n "$VER_BASE" ] && [ "$VER_HEAD" != "$VER_BASE" ]; then
    python3 -I -c 'import json,sys
print(json.dumps({"status":"blocked","failure_class":"version_drift",
  "message":"PR head changes the version (%s -> %s); Release-on-Merge owns bumps" % (sys.argv[2], sys.argv[1])}))' "$VER_HEAD" "$VER_BASE"
    exit 1
  fi
else
  VER_HEAD=$(VER_AT "$EXPECTED")
  if [ "$VER_HEAD" != "$REL_VER" ]; then
    python3 -I -c 'import json,sys
print(json.dumps({"status":"blocked","failure_class":"version_drift",
  "message":"release PR version file (%s) does not match branch version (%s)" % (sys.argv[1], sys.argv[2])}))' "$VER_HEAD" "$REL_VER"
    exit 1
  fi
fi

# Blood-sign (canonical): the gate verifies the PR tree personally -
# the worktree at the expected head gets the canonical
# verify_constraints.sh run (branch name passed explicitly since the
# worktree is detached) and a signed verify_worktree.sh report.
# A non-zero verify = blocked merge; escalations (exit 3) block too -
# the PR waits for the developer exactly like manual_gate.
# Two issue sets with different contracts:
#  * ISSUE_NUMS - issues the PR CLOSES (close/fix/resolve refs):
#    each must exist AND carry a Closes-link in the body.
#  * FRAG_ISSUES - every #N referenced by the body: the allowed set
#    for the .changes fragment's issue: field (an epic PR carries
#    task fragments named after the task issues). No existence or
#    link requirement - a mention is not a commitment to close.
BLOOD_ISSUES=$(INFO_FILE="$INFO_FILE" python3 -I -c 'import json,os,re
body = json.load(open(os.environ["INFO_FILE"])).get("body") or ""
nums = sorted({m.group(1) for m in re.finditer(
    r"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b\s*:?\s*#(\d+)", body)},
    key=int)
print(" ".join(nums))')
FRAG_ISSUES=$(INFO_FILE="$INFO_FILE" python3 -I -c 'import json,os,re
body = json.load(open(os.environ["INFO_FILE"])).get("body") or ""
nums = sorted({m.group(1) for m in re.finditer(r"#(\d+)", body)},
    key=int)
print(" ".join(nums))')
VC_OUT=$(cd "$WT" && VERIFY_BRANCH="$HEAD_BRANCH" VERIFY_PR="$PR" \
         VERIFY_BASE="$BASE" ISSUE_NUMS="$BLOOD_ISSUES" \
         FRAG_ISSUES="$FRAG_ISSUES" \
         bash "$CANON_DIR/bin/verify_constraints.sh" 2>&1)
VC_RC=$?
VW_OUT=$(cd "$WT" && bash "$CANON_DIR/bin/verify_worktree.sh" 2>&1)
VW_RC=$?
VW_JSON=$(printf '%s' "$VW_OUT" | tail -n 1)
if [ $VC_RC -ne 0 ] || [ $VW_RC -ne 0 ]; then
  VC_OUT="$VC_OUT" VW_JSON="$VW_JSON" VC_RC="$VC_RC" VW_RC="$VW_RC" python3 -I -c 'import json,os
vc = int(os.environ["VC_RC"]); vw = int(os.environ["VW_RC"])
if vw != 0:
    fc = "verify_failed"
    msg = "verify_worktree.sh failed (rc=%d)" % vw
else:
    fc = "verify_escalated" if vc == 3 else "verify_failed"
    msg = "verify_constraints.sh %s" % ("escalated (developer required)" if vc == 3 else "failed")
print(json.dumps({"status":"blocked","failure_class":fc,"message":msg,
  "gate_report":{"verify_constraints_tail":os.environ["VC_OUT"][-2000:],
                 "verify_worktree":os.environ["VW_JSON"][:2000]}}))'
  exit 1
fi
# The worktree signature must itself parse and report a clean run.
VW_OK=$(printf '%s' "$VW_JSON" | python3 -I -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("no"); raise SystemExit(0)
base = d.get("baseline")
if not isinstance(base, dict):
    print("no"); raise SystemExit(0)
print("yes" if (d.get("status") in ("pass","ok","signed")
                and not base.get("error")
                and base.get("exit", 0) == 0) else "no")')
if [ "$VW_OK" != "yes" ]; then
  python3 -I -c 'import json,os
print(json.dumps({"status":"blocked","failure_class":"verify_failed",
  "message":"verify_worktree.sh report invalid or baseline failed"}))'
  exit 1
fi

# Review-panel gate (specs/review_panel.md): mechanical
# floors attested/green on the head sha + every required llm/hybrid
# domain signal `ccsdd/<domain>` == success created by the review
# identity + external_checks green. The gate runs on the SAME
# blood-sign worktree at the expected head. A release/v* PR skips
# the panel: its diff is generated by repo_release.sh (version file
# + CHANGELOG fold) and carries no new review surface - domain
# review already happened on each contributing task PR.
if [ "$IS_RELEASE_PR" != "1" ]; then
PANEL_OUT=$(bash "$CANON_DIR/bin/panel_gate.sh" --sha "$EXPECTED" \
            --worktree "$WT" --info-file "$INFO_FILE" 2>&1)
PANEL_RC=$?
if [ $PANEL_RC -ne 0 ]; then
  PANEL_OUT="$PANEL_OUT" python3 -I -c 'import json,os
try:
    r = json.loads(os.environ["PANEL_OUT"].strip().splitlines()[-1])
except Exception:
    r = {"status":"blocked","failure_class":"gate_blocked",
         "message":"panel_gate.sh failed",
         "raw": os.environ["PANEL_OUT"][-1500:]}
fc = r.pop("failure_class", None) or "gate_blocked"
r["status"] = "blocked"; r["failure_class"] = fc
print(json.dumps({"status":"blocked","failure_class":fc,"gate_report":r}))'
  exit 1
fi
fi

# Pre-merge gates under Release-on-Merge (RoM ruling 2026-11-19):
# a declared version source on the base is required fail-closed -
# without it the release step could not compute the next version.
BASE_VER=$(VER_AT "$PRE_MERGE_SHA")
if [ -z "$BASE_VER" ]; then
  python3 -I -c 'import json
print(json.dumps({"status":"blocked","failure_class":"version_source_missing",
  "message":"no version source found on base (adapter: canon/version_source.sh, project.json version.file+regex, or a known manifest) - release-on-merge cannot compute the next version"}))'
  exit 1
fi

ERR=$("$GH" pr merge "$PR" --"$METHOD" --match-head-commit "$EXPECTED" 2>&1)
rc=$?
if [ $rc -ne 0 ]; then
  python3 -I -c 'import json,sys;print(json.dumps({"status":"error","failure_class":"upstream_error","message":sys.argv[1]}))' "$ERR"
  exit 1
fi

# Consume the manual_gate envelope only NOW: the earlier verify was
# side-effect free, so a merge blocked at CI/panel/constraints never
# burned the human's nonce. Recording after the successful merge
# means the signature certified exactly one completed acceptance.
if [ "${MANUAL_GATE:-no}" = "yes" ] && [ -n "${ENV_FILE:-}" ]; then
  "$CANON_DIR/bin/human_sign.sh" consume --envelope "$ENV_FILE" \
    --artifact "$EXPECTED" --verdict approve >/dev/null 2>&1 \
    || echo "issue_merge: signoff nonce consume failed post-merge" >&2
fi

# Contract envelopes are consumed post-merge the same way: without a
# burn, a 7-day-fresh signature could be replayed on a revert+restore
# cycle reintroducing the identical contract content. For each
# contract path touched by the merged diff, compute the artifact the
# same way verify_constraints does (file sha256 for live contracts,
# sha256("delete|path|HEAD") for deletions) and burn the matching
# contract_<path>.json envelope. Best-effort: a missing envelope is
# not an error (the gate may have accepted $BRANCH.json instead).
CONTRACT_TOUCHED=$(git diff --name-only --no-renames "${PRE_MERGE_SHA:-$REMOTE/$BASE}..$EXPECTED" 2>/dev/null \
  | grep -E '(^|/)contract\.(py|ts)$' || true)
if [ -n "$CONTRACT_TOUCHED" ]; then
  while IFS= read -r cpath; do
    [ -n "$cpath" ] || continue
    if git cat-file -e "$EXPECTED:$cpath" 2>/dev/null; then
      CART=$(git show "$EXPECTED:$cpath" | sha256sum | cut -d' ' -f1)
    else
      CART=$(printf 'delete|%s|%s' "$cpath" "$EXPECTED" | sha256sum | cut -d' ' -f1)
    fi
    # Only the contract-named envelope is burned here - $BRANCH.json
    # is the manual_gate/risk:high PR sign-off (artifact = head sha),
    # already consumed by the manual_gate step above; it is never a
    # contract envelope.
    CENV="$CANON_DIR/human_signoffs/contract_$(printf '%s' "$cpath" | tr '/' '_').json"
    [ -f "$CENV" ] \
      && "$CANON_DIR/bin/human_sign.sh" consume --envelope "$CENV" \
           --artifact "$CART" --verdict approve >/dev/null 2>&1 || true
  done <<< "$CONTRACT_TOUCHED"
fi

# Post-merge release under RoM: release is part of the merge
# operation ONLY on the repository default branch - a merge into a
# non-default base (a task branch merged into its epic branch) is
# integration work, not a publication: no version bump, no tag.
# repo_release.sh computes the
# next version from pending .changes fragments (max bump) applied to
# max(latest tag, version source), writes the release commit (version
# file + CHANGELOG fold + fragment consumption), tags and publishes.
# For a release/v* PR merge the same call hits the resume path and
# tags the resulting head. Merges via the documented no-entry paths
# (label/changelog diff, no fragment) release with implicit patch.
export RELEASE='"skipped"'
REL_ARGS=()
case "$ENTRY_VIA" in
  label|changelog) REL_ARGS=(--bump patch) ;;
esac
if [ -n "$DEFAULT_BRANCH" ] && [ "$BASE" != "$DEFAULT_BRANCH" ]; then
  RELEASE='{"status":"skipped","reason":"non_default_base","base":"'"$BASE"'"}'
elif ! git fetch "$REMOTE" "+refs/heads/$BASE:refs/remotes/$REMOTE/$BASE" --tags >/dev/null 2>&1; then
  RELEASE='{"status":"error","failure_class":"upstream_error","reason":"fetch_failed"}'
elif [ ! -x "$CANON_DIR/bin/repo_release.sh" ]; then
  RELEASE='{"status":"error","failure_class":"release_failed","reason":"repo_release_missing"}'
else
  REL_OUT=$(bash "$CANON_DIR/bin/repo_release.sh" --base "$BASE" "${REL_ARGS[@]}" 2>&1)
  REL_RC=$?
  RELEASE=$(printf '%s' "$REL_OUT" | tail -n 1)
  [ $REL_RC -ne 0 ] && [ -z "$RELEASE" ] && \
    RELEASE='{"status":"error","failure_class":"release_failed","reason":"nonzero_exit_no_json"}'
fi
ENTRY_VIA="$ENTRY_VIA" python3 -I -c 'import json,os,sys
raw = os.environ.get("RELEASE","{}")
try: rel = json.loads(raw)
except Exception: rel = {"status":"error","message":raw}
rs = rel.get("status")
if rs == "skipped":
    # non-default base: integration merge, no release by design
    print(json.dumps({"status":"merged","release":rel}))
    raise SystemExit(0)
if rs == "release_pr_opened":
    print(json.dumps({"status":"merged","release":rel,"release_pending":True}))
    raise SystemExit(0)
if rs == "released":
    print(json.dumps({"status":"merged","release":rel}))
    raise SystemExit(0)
if rs == "nothing_pending" and os.environ.get("ENTRY_VIA") == "release-pr":
    # release-PR already tagged on resume path or released earlier
    print(json.dumps({"status":"merged","release":rel}))
    raise SystemExit(0)
print(json.dumps({"status":"error","failure_class":"release_failed","merged":True,
                  "message":"PR merged but release did not publish - run repo_release.sh to resume",
                  "release":rel}))
raise SystemExit(1)'
