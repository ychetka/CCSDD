#!/usr/bin/env bash
# repo_release.sh - Release-on-Merge: compute the next version from
# pending .changes fragments, write the release commit (version file +
# CHANGELOG fold + fragment consumption) on the base branch, tag and
# publish a GitHub release.
#
# Usage: repo_release.sh [--bump patch|minor|major] [--notes "<text>"]
#        [--base <branch>] [--dry-run]
#
# RoM model (ruling 2026-11-19, supersedes reserved-version):
#   * branches do NOT carry a version bump (issue_<N>-<slug> /
#     epic_issue_<N>-<slug>);
#   * next = bump(max(latest v* tag merged into base, version source
#     at base head));
#   * bump comes from the pending fragments' `bump:` fields (max
#     severity) or the explicit --bump override;
#   * the release COMMIT (version file + CHANGELOG + fragment
#     deletion) lands on the base via a detached worktree push - the
#     merge commit itself is never mutated;
#   * idempotent: tag/release already existing at the produced commit
#     reports "released"/"already-existed" instead of failing.
#
# Output JSON: {status: released|nothing_pending|error, tag?, ...}
set -uo pipefail
# CANON_DIR resolves from the script location, not the git top: in
# nested workspaces the git top may be a subdir like code/ while
# canon/ lives at the workspace root.
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
json_error() {
  python3 -c 'import json,sys;print(json.dumps({"status":"error","failure_class":sys.argv[1],"message":sys.argv[2]}))' "$1" "$2"
  exit "${3:-1}"
}
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || \
  json_error upstream_error "not a git repo"
cd -P "$TOP" || json_error upstream_error "cannot cd to repo top"

# Repository-agent credential for repository mutations (merge.gh_bin
# -> gh), NEVER the reviewer identity (self-approve
# deadlock + signal forgery).
GH=$("$CANON_DIR/bin/gh_id.sh" merge)
[ -n "$GH" ] || { echo "merge.gh_bin in project.json is not a bare binary basename" >&2; exit 2; }

BUMP="" NOTES="" DRY=0 BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bump)  BUMP="${2:-}"; shift 2 ;;
    --notes) NOTES="${2:-}"; shift 2 ;;
    --base)  BASE="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    patch|minor|major) BUMP="$1"; shift ;;  # legacy positional
    *) json_error malformed_input "unknown option: $1" 2 ;;
  esac
done
if [ -n "$BUMP" ]; then
  case "$BUMP" in
    patch|minor|major) ;;
    *) json_error malformed_input "--bump must be patch|minor|major" 2 ;;
  esac
fi

# The github remote is picked by URL - 'origin' may be a mirror.
REMOTE=$(git remote -v | awk '$2 ~ /github\.com/ {print $1; exit}')
[ -z "${REMOTE:-}" ] && REMOTE=$(git remote get-url origin >/dev/null 2>&1 && echo origin)
[ -z "${REMOTE:-}" ] && json_error upstream_error "no github remote"
# The base is the merged PR's baseRefName when the caller passes it
# (repo_merge.sh does); without it defaultBranchRef is the only
# sane default - but a merge into a non-default base must never
# silently release onto the default branch.
[ -n "$BASE" ] || BASE=$("$GH" repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
[[ "$BASE" =~ ^[A-Za-z0-9._/-]+$ ]] || json_error malformed_input "unexpected base ref name: $BASE"
git fetch "$REMOTE" "+refs/heads/$BASE:refs/remotes/$REMOTE/$BASE" --tags >/dev/null 2>&1 || \
  json_error upstream_error "fetch of base/tags failed - refusing to guess next version"

SHA=$(git rev-parse "$REMOTE/$BASE" 2>/dev/null) || \
  json_error upstream_error "cannot resolve fetched base head $REMOTE/$BASE - refusing to release on a stale local ref"

# --- publish helper: tag + GitHub release on an existing sha ---
# Shared by the normal path and the resume path; idempotent for a
# partially published release (tag pushed but "$GH" release failed, or
# vice versa). A failed tag push removes the local tag so a retry is
# not poisoned by a stale local ref.
publish_tag_release() {
  local tag="$1" sha="$2" note="$3"
  if ! git rev-parse "refs/tags/$tag" >/dev/null 2>&1; then
    git tag -a "$tag" -m "Release $tag" "$sha" || {
      printf '{"status":"error","failure_class":"upstream_error","message":"annotated tag %s could not be created on %s"}' "$tag" "$sha"
      return 11; }
  fi
  if [ "$(git rev-parse "refs/tags/$tag^{commit}")" != "$sha" ]; then
    printf '{"status":"error","failure_class":"conflict","message":"tag %s exists on different sha %s"}' "$tag" "$(git rev-parse "refs/tags/$tag^{commit}")"
    return 12
  fi
  if ! git push "$REMOTE" "refs/tags/$tag" >/dev/null 2>&1; then
    # Lost a publish race (the release workflow or a parallel run
    # pushed first)? Re-fetch before crying: a remote tag already on
    # this sha IS the outcome we wanted.
    git fetch "$REMOTE" --tags >/dev/null 2>&1 || true
    if [ "$(git rev-parse "refs/tags/$tag^{commit}" 2>/dev/null)" != "$sha" ]; then
      git tag -d "$tag" >/dev/null 2>&1 || true
      printf '{"status":"error","failure_class":"upstream_error","message":"tag %s push failed - push it manually on %s"}' "$tag" "$sha"
      return 13
    fi
  fi
  if ! "$GH" release view "$tag" >/dev/null 2>&1; then
    if [ -n "$NOTES" ]; then
      "$GH" release create "$tag" --notes "$NOTES" >/dev/null 2>&1
    else
      "$GH" release create "$tag" --generate-notes >/dev/null 2>&1
    fi || {
      printf '{"status":"error","failure_class":"upstream_error","message":"tag pushed but "$GH" release create failed - create release for %s manually"}' "$tag"
      return 14; }
  fi
  TAG="$tag" SHA_V="$sha" NOTE_V="${note:-}" python3 -c 'import json,os
print(json.dumps({"status":"released","tag":os.environ["TAG"],"sha":os.environ["SHA_V"],
                  **({"note":os.environ["NOTE_V"]} if os.environ["NOTE_V"] else {})}))'
  return 0
}

# --- resume path (idempotency after a partial failure): if the base
# head IS a release commit the version bump already landed; only
# tag/release publication may be missing. Accepted forms: squash
# subject exactly 'release: vX.Y.Z', or a merge commit whose
# 'Merge pull request ... from */release/vX.Y.Z' subject carries the
# version. Anything looser lets a hand-crafted commit hijack the
# release base. ---
HEAD_MSG=$(git log -1 --format=%s "$SHA" 2>/dev/null || true)
RTAG=""
# Squash merges append " (#N)" to the PR title, so the release-commit
# subject arrives as 'release: vX.Y.Z (#45)' - the trailing issue ref
# is part of the canonical form, not an anomaly.
if [[ "$HEAD_MSG" =~ ^release:[[:space:]]*v([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]*\([#0-9]+\))?$ ]]; then
  RTAG="v${BASH_REMATCH[1]}"
# The merge-commit form must be anchored: only a GitHub-generated
# 'Merge pull request #N from <owner>/release/vX.Y.Z' subject proves
# the release branch was merged - a free-floating 'release/vX.Y.Z'
# substring in an attacker-controlled PR title must not mint tags.
elif [[ "$HEAD_MSG" =~ ^Merge[[:space:]]pull[[:space:]]request[[:space:]]#[0-9]+[[:space:]]from[[:space:]][^[:space:]]+/release/v([0-9]+\.[0-9]+\.[0-9]+)(-r[0-9a-zA-Z]+)?$ ]]; then
  RTAG="v${BASH_REMATCH[1]}"
elif [[ "$HEAD_MSG" =~ ^Merge[[:space:]]branch[[:space:]]'release/v([0-9]+\.[0-9]+\.[0-9]+)(-r[0-9a-zA-Z]+)?'([[:space:]]+into[[:space:]][^[:space:]]+)?$ ]]; then
  RTAG="v${BASH_REMATCH[1]}"
fi
if [ -n "$RTAG" ]; then
  # Provenance: the tag version must equal the version source ON the
  # base head - a hand-crafted commit/PR titled 'release: vX.Y.Z'
  # without the matching version file must not mint a tag.
  HEAD_VER=$(bash "$CANON_DIR/bin/repo_version_at.sh" "$REMOTE/$BASE" 2>/dev/null || true)
  if [ "$HEAD_VER" != "${RTAG#v}" ]; then
    json_error conflict "resume candidate $RTAG but version source on base reports '${HEAD_VER:-none}' - refusing to tag an unprovenanced release"
  fi
  [ $DRY -eq 1 ] && { printf '{"status":"dry_run","resume":true,"tag":"%s","base_sha":"%s"}\n' "$RTAG" "$SHA"; exit 0; }
  publish_tag_release "$RTAG" "$SHA" "resumed-release-commit"
  exit $?
fi

# --- base version: max(latest semver tag merged into base, version
# source at base). Neither source -> hard error, never a synthetic
# v0.0.0 baseline. Pre-release tags (v1.2.3-rc.1) are excluded by the
# strict filter; canon-v* live in a separate namespace. ---
LATEST=$(git tag --merged "$SHA" --list 'v*' --sort=-v:refname \
         | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
FILE_VER=$(bash "$CANON_DIR/bin/repo_version_at.sh" "$REMOTE/$BASE" 2>/dev/null || true)
if [ -z "$LATEST" ] && [ -z "$FILE_VER" ]; then
  json_error version_source_missing "no version source on base and no v* tags merged - cannot compute next version"
fi
BASE_VER=$(LATEST="${LATEST#v}" FILE_VER="$FILE_VER" python3 - <<'PY'
import os, sys
def key(v):
    try: return tuple(int(p) for p in v.split(".")[:3])
    except Exception: return None
latest, fver = os.environ["LATEST"], os.environ["FILE_VER"]
cands = [v for v in (latest, fver) if key(v)]
if not cands:
    sys.exit(3)
print(max(cands, key=key))
PY
)
[ $? -eq 0 ] || \
  json_error version_source_missing "no parseable version source on base"

# --- pending fragments: on base head but not under the latest tag ---
FRAGS=$(LATEST="$LATEST" SHA="$SHA" TOP="$TOP" python3 - <<'PY'
import os, subprocess
top, latest, sha = os.environ["TOP"], os.environ["LATEST"], os.environ["SHA"]
def ls(ref):
    r = subprocess.run(["git","-C",top,"ls-tree","-r","-z","--name-only",ref,"--",".changes"],
                       capture_output=True, text=True)
    if r.returncode != 0: return set()
    return {f for f in r.stdout.split("\0") if f.endswith(".md")
            and not f.endswith("/README.md")}
pending = ls(sha) - (set() if not latest else ls(latest))
print("\n".join(sorted(pending)))
PY
)

# --- fragment frontmatter: bump and visibility fields are read from
# the leading key:value zone only - body text/code blocks cannot
# inject contract fields. user_visible: false fragments are consumed
# by the release but never folded into CHANGELOG. ---
FRAG_META=$(FRAGS="$FRAGS" SHA="$SHA" TOP="$TOP" python3 - <<'PY'
import json, os, re, subprocess
top, sha = os.environ["TOP"], os.environ["SHA"]
def front_fields(body):
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
meta = {}
# FRAGS is newline-joined; whitespace-splitting would corrupt
# fragment paths containing spaces.
for f in [x for x in os.environ["FRAGS"].splitlines() if x]:
    body = subprocess.run(["git","-C",top,"show",sha+":"+f],
                          capture_output=True, text=True).stdout
    meta[f] = front_fields(body)
print(json.dumps(meta))
PY
)

# Fragment bumps count even when --bump was passed: the pending
# fragments are consumed by THIS release either way, so the effective
# bump is max(--bump override, max fragment bump). Forcing patch while
# consuming a fragment that declared minor/major would silently
# mis-version the release.
if [ -n "$FRAGS" ]; then
  BUMP=$(FRAG_META="$FRAG_META" BUMP="$BUMP" python3 - <<'PY'
import json, os
sev = {"patch":0,"minor":1,"major":2}
best = os.environ["BUMP"] or None
for f, fields in json.loads(os.environ["FRAG_META"]).items():
    b = fields.get("bump")
    if b in sev and (best is None or sev[b] > sev[best]):
        best = b
print(best or "")
PY
)
fi
if [ -z "$BUMP" ] && [ -z "$FRAGS" ]; then
  echo '{"status":"nothing_pending","message":"no .changes fragments pending and no --bump override"}'
  exit 0
fi
if [ -z "$BUMP" ]; then
  json_error malformed_input "pending fragments carry no valid bump: field (patch|minor|major) and no --bump override given"
fi

NEXT=$(BASE_VER="$BASE_VER" BUMP="$BUMP" python3 - <<'PY'
import os, sys
parts = os.environ["BASE_VER"].split(".")
if len(parts) < 3:
    sys.exit(3)
a,b,c = (int(x) for x in parts[:3])
p = os.environ["BUMP"]
if p == "major": a,b,c = a+1,0,0
elif p == "minor": b,c = b+1,0
else: c += 1
print(f"{a}.{b}.{c}")
PY
)
[ $? -eq 0 ] && [ -n "$NEXT" ] || \
  json_error malformed_input "unparseable base version: $BASE_VER"
TAG="v$NEXT"

if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
  EXISTING=$(git rev-parse "refs/tags/$TAG^{commit}")
  # Idempotent: the tag may sit on the pre-release head itself OR on
  # a release commit this script produced on top of it. A descendant
  # tag is only valid when the tagged commit is provably THIS
  # release's own commit - subject 'release: vX.Y.Z' AND the version
  # source inside it matching the tag. A random descendant or an
  # unmerged branch tip must never read as "already released".
  if [ "$EXISTING" = "$SHA" ]; then
    printf '{"status":"released","tag":"%s","sha":"%s","note":"already-existed"}\n' "$TAG" "$EXISTING"
    exit 0
  fi
  if git merge-base --is-ancestor "$SHA" "$EXISTING" 2>/dev/null \
     && [ "$(git log -1 --format=%s "$EXISTING" 2>/dev/null)" = "release: $TAG" ] \
     && [ "$(git rev-list --count "$SHA..$EXISTING" 2>/dev/null || echo 9)" = "1" ] \
     && [ "$(bash "$CANON_DIR/bin/repo_version_at.sh" "$EXISTING" 2>/dev/null || true)" = "$NEXT" ]; then
    printf '{"status":"released","tag":"%s","sha":"%s","note":"already-existed"}\n' "$TAG" "$EXISTING"
    exit 0
  fi
  json_error conflict "tag $TAG already exists on different sha $EXISTING"
fi

[ $DRY -eq 1 ] && {
  FRAGS="$FRAGS" NEXT="$NEXT" TAG="$TAG" BUMP="$BUMP" BASE_VER="$BASE_VER" SHA="$SHA" python3 - <<'PY'
import json, os
print(json.dumps({"status":"dry_run","next":os.environ["NEXT"],
  "tag":os.environ["TAG"],"bump":os.environ["BUMP"],
  "base_version":os.environ["BASE_VER"],
  "fragments":[f for f in os.environ["FRAGS"].splitlines() if f],
  "base_sha":os.environ["SHA"]}))
PY
  exit 0
}

# --- release commit on a detached worktree ---
WT=$(mktemp -d "${TMPDIR:-/tmp}/rom_release.XXXXXX")
IN_WT=0
cleanup() {
  [ "$IN_WT" = "1" ] && cd "$TOP" 2>/dev/null
  git worktree remove --force "$WT" 2>/dev/null
  rm -rf "$WT" 2>/dev/null
}
trap cleanup EXIT INT TERM
git worktree add --detach "$WT" "$SHA" >/dev/null 2>&1 || \
  json_error upstream_error "release worktree add failed"

# 1. version file - the DEPLOYED control plane scripts do the write.
# Copying canon into the release worktree would ship workspace-
# mutable config (project.json, adapters) inside the release
# provenance chain; the deployed canon resolves config from its own
# location while the version file write lands in the worktree CWD.
VFILE=$(cd "$WT" && bash "$CANON_DIR/bin/repo_version_set.sh" "$NEXT" 2>/dev/null) || \
  json_error version_source_missing "repo_version_set.sh could not write the version file on base"
[ -n "$VFILE" ] || \
  json_error version_source_missing "repo_version_set.sh returned an empty version file path"

# 2. fold fragments into CHANGELOG.md (create if absent). Only
# user_visible fragments produce entries; metadata fields, the Spec
# impact section and leading bullet markers are stripped so entries
# do not come out as '- - text'.
FRAG_META="$FRAG_META" FRAGS="$FRAGS" NEXT="$NEXT" WT="$WT" python3 - <<'PY' || json_error upstream_error "changelog fold failed"
import json, os, re, sys
wt, ver = os.environ["WT"], os.environ["NEXT"]
import datetime
date = datetime.date.today().isoformat()
meta = json.loads(os.environ["FRAG_META"])
entries = []
for f in os.environ["FRAGS"].splitlines():
    if not f: continue
    fields = meta.get(f) or {}
    if fields.get("user_visible") == "false":
        continue   # consumed, but invisible to the changelog
    p = os.path.join(wt, f)
    if not os.path.isfile(p): continue
    body = open(p, encoding="utf-8", errors="replace").read()
    # strip the whole '## Spec impact' section (up to the next heading)
    body = re.sub(r"(?im)^\s*#+\s*spec impact\s*$[\s\S]*?(?=^\s*#|\Z)",
                  "", body)
    lines = [l for l in body.splitlines()
             if not re.match(
                 r"^\s*(bump|user_visible|issue|manual_gate|ci_bootstrap)\s*:",
                 l, re.I)
             and not re.match(r"^\s*---\s*$", l)
             and not re.match(r"^\s*#", l)]
    txt = "\n".join(lines).strip()
    # avoid double bullet markers
    txt = re.sub(r"(?m)^\s*-\s+", "", txt).strip()
    if txt: entries.append(txt)
cl = os.path.join(wt, "CHANGELOG.md")
old = open(cl, encoding="utf-8").read() if os.path.isfile(cl) else "# Changelog\n"
if old and not old.endswith("\n"):
    old += "\n"
section = f"\n## v{ver} - {date}\n\n" + "\n\n".join(f"- {e}" for e in entries) + "\n"
m = re.match(r"^\s*#[^\n]*\n", old)
if m:
    new = old[:m.end()] + section + old[m.end():]
else:
    new = section + "\n" + old
open(cl, "w", encoding="utf-8").write(new)
PY

cd -P "$WT" && IN_WT=1
# The version file is the point of the release: a failed add must
# abort, not silently fall back to a release commit without a bump.
git add "$VFILE" CHANGELOG.md 2>/dev/null || \
  json_error malformed_input "git add of version file/CHANGELOG failed - release commit aborted"
# Fragment removal must succeed: a failed rm means the fragment is
# folded into the release yet stays pending for the next one.
if [ -n "$FRAGS" ]; then
  while IFS= read -r frag; do
    [ -n "$frag" ] && git rm -q -- "$frag" 2>/dev/null || {
      echo "$frag"; }
  done <<< "$FRAGS" | grep . && \
    json_error upstream_error "git rm of consumed fragments failed - release commit aborted"
fi
git add -A .changes 2>/dev/null || true
git -c user.name="release-bot" -c user.email="release-bot@local" commit -q -m "release: $TAG" || \
  json_error upstream_error "release commit failed - nothing to commit?"
REL_SHA=$(git rev-parse HEAD)

# Push the release commit to the base. Branch protection may reject a
# direct push - fall back to a release branch + PR instead of dying:
# the PR lands the identical release commit, and the NEXT
# repo_release.sh run (resume path above) finishes tag+release.
if git push "$REMOTE" "HEAD:$BASE" >/dev/null 2>&1; then
  :
else
  RBR="release/$TAG"
  # An open release PR for this tag is only reusable when its head
  # content STILL matches the release we just generated - a stale PR
  # from an earlier attempt carries the wrong base state or misses
  # newer fragments, and merging it would tag the wrong tree.
  # Search ALL open release/v* PRs, not just this tag: a leftover
  # release/v<older> PR from a superseded bump must be closed, or two
  # competing release PRs race the same version namespace.
  RELEASE_PRS=$("$GH" pr list --base "$BASE" --state open \
    --json headRefName,headRefOid,url --jq '.[] | select(.headRefName | startswith("release/v")) | .headRefName + " " + .headRefOid + " " + .url' 2>/dev/null || true)
  EXISTING_PR=$(printf '%s\n' "$RELEASE_PRS" | grep -F "release/$TAG" | head -n1 || true)
  # Superseded release PRs (different tag): close them so they cannot
  # be merged later and tag a stale tree. Best-effort, never fatal.
  printf '%s\n' "$RELEASE_PRS" | grep -vF "release/$TAG" | while read -r ob _osha ourl; do
    [ -n "$ob" ] || continue
    "$GH" pr close "$ourl" --comment "superseded by release $TAG" >/dev/null 2>&1 || true
    git push "$REMOTE" --delete "$ob" >/dev/null 2>&1 || true
  done
  if [ -n "$EXISTING_PR" ]; then
    EBR="${EXISTING_PR%% *}"
    REST="${EXISTING_PR#* }"
    ESHA="${REST%% *}"
    EURL="${REST##* }"
    git fetch "$REMOTE" "$ESHA" >/dev/null 2>&1 || true
    # Tree-equality is the provenance check: identical trees mean the
    # open PR carries exactly this release content regardless of the
    # commit ancestry.
    if [ "$(git rev-parse "$ESHA^{tree}" 2>/dev/null)" = "$(git rev-parse "HEAD^{tree}")" ]; then
      printf '{"status":"release_pr_opened","tag":"%s","sha":"%s","pr":"%s","message":"release PR already open with matching content - merging it lands the release; rerun repo_release.sh after it merges"}\n' \
        "$TAG" "$ESHA" "$EURL"
      exit 0
    fi
    # Stale content: replace the branch head with the regenerated
    # release so the existing PR converges instead of drifting.
    RBR="$EBR"
    if ! git push "$REMOTE" --force-with-lease="refs/heads/$RBR:$ESHA" "HEAD:refs/heads/$RBR" >/dev/null 2>&1; then
      RBR="release/$TAG-r$(git rev-parse --short HEAD 2>/dev/null || date +%s)"
      git push "$REMOTE" "HEAD:$RBR" >/dev/null 2>&1 || \
        json_error permission_denied "release commit push rejected on $BASE and release branch - apply the release commit manually"
    else
      printf '{"status":"release_pr_opened","tag":"%s","sha":"%s","pr":"%s","message":"stale release PR updated to the regenerated release - merging it lands the release"}\n' \
        "$TAG" "$REL_SHA" "$EURL"
      exit 0
    fi
  fi
  if ! git push "$REMOTE" "HEAD:$RBR" >/dev/null 2>&1; then
    # A stale release branch from an earlier attempt blocks the push -
    # retry on a unique name rather than dying.
    RBR="release/$TAG-r$(git rev-parse --short HEAD 2>/dev/null || date +%s)"
    git push "$REMOTE" "HEAD:$RBR" >/dev/null 2>&1 || \
      json_error permission_denied "release commit push rejected on $BASE and release branch - apply the release commit manually"
  fi
  PR_URL=$("$GH" pr create --base "$BASE" --head "$RBR" \
    --title "release: $TAG" \
    --body "Release-on-Merge commit for $TAG (version file + CHANGELOG fold + fragment consumption). Merging this lands the release commit; the next repo_release.sh run tags $TAG on the resulting head." 2>/dev/null || true)
  if [ -n "$PR_URL" ]; then
    # squash keeps 'release: vX.Y.Z' as the merge subject so the
    # resume path detects it. No --auto: unattended auto-merge is a
    # provenance gap (the release would land on whatever head the
    # branch happens to hold when checks go green - possibly after a
    # force-push). Attempt an immediate head-bound merge; when
    # protection still blocks it, the release waits for a human or
    # the release workflow and the next repo_release.sh run tags the
    # landed merge commit.
    AM_OUT=$("$GH" pr merge "$PR_URL" --squash --match-head-commit "$REL_SHA" 2>&1)
    AM_RC=$?
    AUTO_FLAG=""
    [ $AM_RC -ne 0 ] && AUTO_FLAG=",\"merge_error\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1][:300]))' "$AM_OUT")"
    printf '{"status":"release_pr_opened","tag":"%s","sha":"%s","pr":"%s"%s,"message":"base protected - release lands via PR; merge it (or let the release workflow finalize); rerun repo_release.sh after it merges to tag+publish"}\n' \
      "$TAG" "$REL_SHA" "$PR_URL" "$AUTO_FLAG"
    exit 0
  fi
  json_error permission_denied "release pushed to $RBR but PR creation failed - merge $RBR into $BASE manually"
fi

publish_tag_release "$TAG" "$REL_SHA" ""
exit $?
