#!/usr/bin/env bash
# spec_anchor_check.sh - mechanical floor for the `specs` review
# domain (review_panel.json). Extracted from verify_constraints.sh
# check #7: .changes fragment fields + Spec impact anchor resolution.
#
# Env inputs (all optional, same semantics as verify_constraints.sh):
#   BASE, BASE_REF - diff base for "pending" fragment detection and
#                    base-existence of modifies/removes anchors
#   ISSUE_LIST, FRAG_LIST - allowed issue numbers for the fragment
#                    'issue:' field
#   PENDING_FRAGS  - explicit fragment list override
#   CANON_DIR      - honored when set (gate_run executes the base-ref
#                    blob and exports the live canon dir)
# Exit: 0 pass / 1 violations / 2 usage. Violations print on stdout.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1  # canon bin imports must not litter __pycache__
CANON_DIR="${CANON_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)}"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 2; }
cd -P "$TOP"
BASE="${BASE:-}"; BASE_REF="${BASE_REF:-}"
ISSUE_LIST="${ISSUE_LIST:-}"; FRAG_LIST="${FRAG_LIST:-}"

# Auto-resolve the base when the caller (e.g. gate_run) did not pass
# it: without BASE_REF the base-existence checks below are blind.
PJ="$CANON_DIR/project.json"
if [ -z "$BASE_REF" ]; then
  BB=$(PJ="$PJ" python3 -I -c 'import json,os
try: print(json.load(open(os.environ["PJ"])).get("base_branch") or "main")
except Exception: print("main")' 2>/dev/null)
  # Probe every configured remote, not just 'origin' - repo_merge
  # accepts any forge remote name, and CI may fetch a single branch
  # under a differently named remote.
  for r in $(git remote 2>/dev/null | sed "s#\$#/$BB#") "$BB"; do
    git rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { BASE_REF=$r; break; }
  done
fi
[ -n "$BASE_REF" ] && [ -z "$BASE" ] \
  && BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || true)

# Early skip only when PENDING_FRAGS was not given explicitly: an
# external caller may pass a fragment list that lives outside
# .changes/ (documented override in the header).
if [ -z "${PENDING_FRAGS:-}" ] \
   && ! compgen -G "$TOP/.changes/*.md" >/dev/null 2>&1; then
  echo "SKIP: no pending .changes entries"
  exit 0
fi

if [ -z "${PENDING_FRAGS:-}" ]; then
  if [ -n "$BASE" ]; then
    # Strict diff scope: fragments on base that were never consumed
    # must not re-enter the check - they are base history, not this
    # PR's pending release notes.
    PENDING_FRAGS=$(git -c core.quotepath=false diff --name-only --diff-filter=ACMR "$BASE"...HEAD 2>/dev/null \
                    | grep -E '^\.changes/[^/]+\.md$' | grep -v '/README\.md$' || true)
  else
    # No resolvable base (detached/fixture context): fall back to
    # whatever pending fragments exist in the worktree.
    PENDING_FRAGS=$(cd "$TOP" && ls .changes/*.md 2>/dev/null | grep -v 'README\.md$' || true)
  fi
fi

# Nothing pending in THIS delta: a release PR (deletes fragments), a
# no-changes-entry path, or a worktree where only .changes/README.md
# exists must not run the anchor checks or the repo adapter with an
# empty list.
if [ -z "${PENDING_FRAGS:-}" ]; then
  echo "SKIP: no pending .changes entries in delta"
  exit 0
fi

# A. Mandatory fragment fields (bump / user_visible / issue) and a
#    non-empty '## Spec impact' (adds/modifies/removes lines or the
#    bare '-' none-marker). CANONICAL contract - runs even when a repo
#    adapter owns anchor resolution.
FIELD_BAD=$(TOP="$TOP" PENDING_FRAGS="$PENDING_FRAGS" ISSUE_LIST="$ISSUE_LIST $FRAG_LIST" CANON_DIR="$CANON_DIR" python3 -I - <<'PY'
import os, re, sys
top = os.environ["TOP"]
frags = [l.strip() for l in os.environ.get("PENDING_FRAGS","").splitlines() if l.strip()]
issue_list = set(os.environ.get("ISSUE_LIST","").split())
bad = []

sys.path.insert(0, os.path.join(os.environ.get("CANON_DIR") or "", "bin"))
from changes_parser import front_fields, issue_numbers

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
    # Natural forms (harness.md): '10', '#10', '10, 11', '#10, #11',
    # '[10, 11]', '"10"', '10 # comment' - the canonical
    # issue_numbers parser, identical to issue_merge's acceptance.
    iss_nums = issue_numbers(iss)
    if not iss_nums:
        bad.append(f"{name}: missing 'issue: <N>'")
    elif issue_list and not {str(n) for n in iss_nums} <= issue_list:
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
    # A directive whose every target is a placeholder word
    # ('- adds: none', '- modifies: -') declares nothing and
    # satisfies nothing: it slips past has_lines while carrying
    # zero real anchors. The author must either name docs/specs
    # targets or use the bare '-' none-marker.
    for kind, targets in re.findall(
            r"(?im)^\s*(?:-\s*)?(adds|modifies|removes)\s*:\s*(.+)$", sec):
        toks = [t.strip().strip("`")
                for t in re.split(r"[,\s]+", targets.strip())]
        if not any(t and t.lower() not in ("none", "-", "n/a")
                   for t in toks):
            bad.append(f"{name}: '{kind}: {targets.strip()}' declares "
                       f"only placeholder targets - name a docs/specs "
                       f"target or use the bare '-' none-marker")
for b in bad:
    print(b)
PY
)
if [ -n "$FIELD_BAD" ]; then
  printf '%s\n' "$FIELD_BAD" | sed 's/^/  fragment: /'
  echo "FAIL: changes fragment field validation"
  exit 1
fi

# B. Anchor resolution - the repo adapter (if present and taken from
#    the BASE ref, never the PR/worktree copy) first, then the
#    canonical fallback below.
ADAPTER_OUT=""
ADAPTER_RC=127
# Repo adapters execute under gate credentials: scrub the
# environment (no SSH_AUTH_SOCK / forge tokens / PYTHONPATH) and
# keep CWD out of sys.path via PYTHONSAFEPATH (3.11+) so a module
# inside the candidate tree cannot shadow stdlib imports.
ADP_ENV() { env -i "PATH=${PATH:-/usr/bin:/bin}" "HOME=/tmp" "TMPDIR=/tmp" \
           "LANG=${LANG:-C.UTF-8}" PYTHONDONTWRITEBYTECODE=1 \
           PYTHONSAFEPATH=1 "PENDING_FRAGS=$PENDING_FRAGS" "$@"; }
if [ -n "$BASE" ] && git cat-file -e "$BASE_REF:tools/check_spec_anchors.sh" 2>/dev/null; then
  ADP=$(mktemp)
  git show "$BASE_REF:tools/check_spec_anchors.sh" > "$ADP" 2>/dev/null
  ADAPTER_OUT=$(cd "$TOP" && ADP_ENV bash "$ADP" 2>&1 | tail -n 5)
  ADAPTER_RC=$?
  rm -f "$ADP"
elif [ -x "$CANON_DIR/tools/check_spec_anchors.sh" ]; then
  ADAPTER_OUT=$(cd "$TOP" && ADP_ENV bash "$CANON_DIR/tools/check_spec_anchors.sh" 2>&1 | tail -n 5)
  ADAPTER_RC=$?
fi
if [ $ADAPTER_RC -ne 127 ]; then
  if [ $ADAPTER_RC -eq 0 ]; then
    echo "PASS: spec anchors (repo adapter)"
    exit 0
  else
    printf '%s\n' "$ADAPTER_OUT" | sed 's/^/  adapter: /'
    echo "FAIL: Spec impact anchors do not resolve"
    exit 1
  fi
fi

# Canonical fallback (no repo adapter): every pending fragment's
# Spec impact anchors are checked here - adds/modifies targets
# must exist under docs/specs/ in the working tree after the
# change; removes targets must be gone (file or anchor) and must
# have existed at the base.
TOP="$TOP" PENDING_FRAGS="$PENDING_FRAGS" BASE="$BASE" BASE_REF="$BASE_REF" CANON_DIR="$CANON_DIR" python3 -I - <<'PY'
import os, re, subprocess, sys
top = os.environ["TOP"]
base_ref = os.environ.get("BASE_REF") or ""
frags = [l.strip() for l in os.environ.get("PENDING_FRAGS","").splitlines() if l.strip()]
bad = []

# Slugger/anchor logic is shared with docs_check.sh via
# canon/bin/md_anchors.py - one implementation for every markdown
# gate (drifted before: fence sets, {#id} handling, titled links).
import sys as _sys, os as _os
_sys.path.insert(0, _os.path.join(_os.environ.get("CANON_DIR", ""), "bin"))
try:
    import md_anchors as _md
    gh_anchor, collect_anchors = _md.gh_anchor, _md.collect_anchors
    strip_fenced = _md.strip_fenced
except Exception:
    # Inline fallback keeps the check runnable on stripped deploys;
    # the canonical module is the source of truth.
    def gh_anchor(heading):
        heading = re.sub(r"\{#[^}]+\}", "", heading)
        return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")
    def strip_fenced(body):
        out, fchar, flen = [], None, None
        for l in body.splitlines():
            s = l.strip()
            if fchar is not None:
                if s and set(s) <= {fchar} and len(s) >= flen:
                    fchar = None
                continue
            fm = re.match(r"^\s*(`{3,}|~{3,})", l)
            if fm:
                fchar, flen = fm.group(1)[0], len(fm.group(1))
                continue
            out.append(l)
        return "\n".join(out)
    def collect_anchors(body):
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
        # fail-closed: without a base ref the check cannot prove
        # prior existence - report as non-existent so modifies/
        # removes claims against phantom anchors are caught.
        return False
    r = subprocess.run(["git","show",base_ref+":"+rel],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return False
    if not anchor:
        return True
    # Same collection rules as the worktree check - an {#id} or
    # duplicate-suffixed anchor must resolve at base too.
    return anchor.lower() in collect_anchors(strip_fenced(r.stdout))

def norm_target(t):
    file_part, _, anchor = t.partition("#")
    return os.path.normpath(file_part), anchor

def spec_impact_lines(body):
    m = re.search(r"(?im)^#+\s*spec impact\s*$", body)
    if not m:
        return []
    sec = body[m.end():]
    nxt = re.search(r"(?m)^#", sec)
    if nxt:
        sec = sec[:nxt.start()]
    return re.findall(
        r"(?im)^\s*(?:-\s*)?(adds|modifies|removes)\s*:\s*(.+)$", sec)

# Anchors a PR introduces itself: every `adds:` target declared by
# any fragment of the delta. An epic merges task by task - task 1
# `adds: spec.md#req-1`, task 2 `modifies:`/`removes:` it before the
# epic reaches main. `existed_at_base` alone would block that valid
# sequence; a delta-introduced target counts as existing for
# modifies/removes checks (net effect vs base: adds / nothing).
introduced = []          # list of (norm_file, anchor_or_None), lowercased
for rel in frags:
    path = os.path.join(top, rel)
    if not os.path.isfile(path):
        continue
    body = open(path, encoding="utf-8", errors="replace").read()
    for kind, targets in spec_impact_lines(body):
        if kind != "adds":
            continue
        for t in re.split(r"[,\s]+", targets.strip()):
            t = t.strip().strip("`")
            if not t or t.lower() in ("none", "-", "n/a"):
                continue
            fp, anch = norm_target(t)
            # Anchors compare case-insensitively (collect_anchors and
            # anchor_resolves lowercase everything): 'adds: x.md#Req-1'
            # in task 1 must satisfy 'modifies: x.md#req-1' in task 2.
            introduced.append((fp, anch.lower() if anch else None))

def introduced_in_delta(norm_fp, anchor):
    al = anchor.lower() if anchor else anchor
    for fp, anch in introduced:
        if fp == norm_fp and (anch is None or anch == al):
            return True
    return False

# Targets another fragment of the SAME delta removes (intra-epic
# add-then-remove): task 1 adds spec.md#r1, task 2 removes it before
# the epic reaches main. An adds/modifies target that the delta
# itself removes must not be required to resolve in the final tree.
removed = []
for rel in frags:
    path = os.path.join(top, rel)
    if not os.path.isfile(path):
        continue
    body = open(path, encoding="utf-8", errors="replace").read()
    for kind, targets in spec_impact_lines(body):
        if kind != "removes":
            continue
        for t in re.split(r"[,\s]+", targets.strip()):
            t = t.strip().strip("`")
            if not t or t.lower() in ("none", "-", "n/a"):
                continue
            fp, anch = norm_target(t)
            removed.append((fp, anch.lower() if anch else None))

def removed_in_delta(norm_fp, anchor):
    al = anchor.lower() if anchor else anchor
    for fp, anch in removed:
        if fp == norm_fp and (anch is None or anch == al):
            return True
    return False

for rel in frags:
    path = os.path.join(top, rel)
    if not os.path.isfile(path):
        continue
    body = open(path, encoding="utf-8", errors="replace").read()
    name = os.path.basename(path)
    lines = spec_impact_lines(body)
    if not lines:
        continue
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
                if removed_in_delta(norm_fp, anchor or None):
                    continue  # removed later in the same delta
                if not os.path.isfile(p):
                    bad.append(f"{name}: {kind} target missing: {t}")
                elif os.path.isdir(p):
                    bad.append(f"{name}: {kind} target is a directory: {t}")
                elif not anchor:
                    bad.append(f"{name}: {kind} needs an explicit '#anchor': {t}")
                elif not anchor_resolves(p, anchor):
                    bad.append(f"{name}: {kind} anchor '#{anchor}' "
                               f"does not resolve in {file_part}")
                elif kind == "modifies" and not existed_at_base(norm_fp, anchor) \
                        and not introduced_in_delta(norm_fp, anchor):
                    bad.append(f"{name}: modifies anchor '#{anchor}' "
                               f"never existed at base and is not "
                               f"delta-introduced in {norm_fp}")
            if kind == "removes":
                still = (anchor_resolves(p, anchor) if anchor
                         else os.path.exists(p))
                if still:
                    bad.append(f"{name}: removes target still present: {t}")
                elif not existed_at_base(norm_fp, anchor) \
                        and not introduced_in_delta(norm_fp, anchor):
                    bad.append(f"{name}: removes target never existed at base "
                               f"and is not delta-introduced: {t}")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
RC=$?
if [ $RC -eq 0 ]; then
  echo "PASS: spec anchors (canonical fallback)"
else
  echo "FAIL: Spec impact anchors do not resolve"
fi
exit $RC
