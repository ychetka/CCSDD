#!/usr/bin/env bash
# docs_check.sh - mechanical floor for the `docs` review domain.
#   1. Markdown link integrity: relative links and #anchors inside
#      *.md files (docs/, README*) must resolve in the worktree.
#   2. Canon version sync (only when canon/MANIFEST.json exists in
#      the repo): every explicit 'canon' version mention in README*
#      must equal manifest canon_version.
#   (repo doc linters run as a separate RUNNER=project check.)
# CANON_DIR env is honored (gate_run executes the base-ref blob).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1  # canon bin imports must not litter __pycache__
CANON_DIR="${CANON_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)}"
# Nested workspaces: probe cwd, ./code, and the sibling of CANON_DIR.
TOP=$(git rev-parse --show-toplevel 2>/dev/null \
      || git -C code rev-parse --show-toplevel 2>/dev/null \
      || git -C "$CANON_DIR/../code" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP"
PJ="$CANON_DIR/project.json"
fails=0

# --- 1. markdown relative links + anchors ---
LINK_BAD=$(TOP="$TOP" CANON_DIR="$CANON_DIR" python3 -I - <<'PY'
import os, re, sys, urllib.parse
top = os.environ["TOP"]
# Slugger/anchor logic is shared with spec_anchor_check.sh via
# canon/bin/md_anchors.py - one implementation for every markdown
# gate (drifted before: fence sets, {#id} handling, titled links).
sys.path.insert(0, os.path.join(os.environ.get("CANON_DIR", ""), "bin"))
try:
    import md_anchors as _md
    gh_anchor, strip_nonlink = _md.gh_anchor, _md.strip_nonlink
except Exception:
    def strip_nonlink(body):
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
        return re.sub(r"`[^`\n]+`", "", "\n".join(out))
    def gh_anchor(h):
        h = re.sub(r"\{#[^}]+\}", "", h)
        return re.sub(r"[^\w\- ]", "", h.strip().lower()).replace(" ", "-")
bad = []
# Enumerate via git, not os.walk: a symlinked dir inside the repo
# would let os.walk escape the top (docs in a worktree's .worktrees
# or an attacker's symlink farm get linted too), and untracked junk
# should not gate a PR anyway. ls-files covers tracked + staged.
import subprocess
top_real = os.path.realpath(top)
md_files = []
try:
    out = subprocess.run(
        ["git", "ls-files", "--", "*.md"],
        cwd=top, capture_output=True, text=True, check=True).stdout
except Exception:
    out = ""
for rel in out.splitlines():
    p = os.path.realpath(os.path.join(top, rel))
    # containment: a symlinked path must still resolve inside top
    if os.path.commonpath([p, top_real]) != top_real:
        continue
    if p.endswith(".md"):
        md_files.append(p)

def anchors_of(path):
    # Shared anchor collection from md_anchors.collect_anchors - the
    # private copy drifted once already; inline code spans still have
    # to be blanked before headings are counted (a '# x' inside
    # backticks is literal text, not a heading) which is exactly what
    # strip_nonlink does before collect.
    try:
        body = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return set()
    try:
        return _md.collect_anchors(strip_nonlink(body))
    except NameError:
        body = strip_nonlink(body)
        out, seen = set(), {}
        for l in body.splitlines():
            if l.startswith("#"):
                out |= {a.lower() for a in re.findall(r"\{#([^}\s]+)\}", l)}
                h = gh_anchor(l.lstrip("# ").strip())
                n = seen.get(h, 0); seen[h] = n + 1
                out.add(h if n == 0 else f"{h}-{n}")
        out |= {a.lower() for a in re.findall(r'(?:name|id)\s*=\s*["\']([^"\']+)["\']', body)}
        return out

# [text](target) plus the optional Markdown title form
# [text](target "Title") / (target 'Title') - the title is not part
# of the resolved path.
link_re = re.compile(
    r'''(?<!!)\[[^\]]*\]\(\s*([^\s)]+)(?:\s+["'][^"']*["'])?\s*\)''')
for p in md_files:
    rel = os.path.relpath(p, top)
    body = open(p, encoding="utf-8", errors="replace").read()
    body = strip_nonlink(body)
    for m in link_re.finditer(body):
        url = m.group(1).strip("<>")
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", url) or url.startswith("//"):
            continue  # external scheme or protocol-relative - skip
        file_part, _, anch = url.partition("#")
        # percent-decode both sides - non-ASCII anchors are commonly
        # written URL-encoded in links but plain unicode in headers
        file_part = urllib.parse.unquote(file_part)
        anch = urllib.parse.unquote(anch)
        target = os.path.normpath(os.path.join(os.path.dirname(p), file_part)) if file_part else p
        if file_part and not os.path.exists(target):
            bad.append(f"{rel}: broken link -> {url}")
            continue
        if anch and anch.lower() not in anchors_of(target):
            bad.append(f"{rel}: unresolved anchor -> {url}")
for b in bad[:50]:
    print(b)
PY
)
if [ -n "$LINK_BAD" ]; then
  printf '%s\n' "$LINK_BAD" | sed 's/^/  link: /'
  echo "FAIL: markdown link integrity"; fails=$((fails+1))
else
  echo "PASS: markdown links/anchors resolve"
fi

# --- 2. canon version sync (canon repos only) ---
if [ -f "$TOP/canon/MANIFEST.json" ]; then
  VER_BAD=$(TOP="$TOP" python3 -I - <<'PY'
import json, os, re
top = os.environ["TOP"]
want = json.load(open(os.path.join(top, "canon/MANIFEST.json")))["canon_version"]
bad = []
for name in ("README.md",):
    for root, _, files in os.walk(top):
        for f in files:
            if f != name: continue
            p = os.path.join(root, f)
            rel = os.path.relpath(p, top)
            if ".git/" in rel: continue
            for i, l in enumerate(open(p, encoding="utf-8", errors="replace"), 1):
                # only lines that DECLARE the canon version count -
                # prose mentioning an old release ("fixed in canon
                # 1.1.0") is not a version declaration
                if not re.search(r"canon[\s_-]*version|canon[\s_-]*v\d", l, re.I):
                    continue
                m = re.search(r"v?(\d+\.\d+\.\d+)", l)
                if m and m.group(1) != want:
                    bad.append(f"{rel}:{i}: canon version {m.group(1)} != manifest {want}")
for b in bad:
    print(b)
PY
)
  if [ -n "$VER_BAD" ]; then
    printf '%s\n' "$VER_BAD" | sed 's/^/  version: /'
    echo "FAIL: canon version drift in docs"; fails=$((fails+1))
  else
    echo "PASS: canon version in docs matches manifest"
  fi
fi

# --- 3. project-declared docs linter ---
# Project docs linter is RUNNER=project, not here.

[ $fails -eq 0 ] && { echo "DOCS_CHECK: PASS"; exit 0; }
echo "DOCS_CHECK: $fails FAILURES"; exit 1
