#!/usr/bin/env bash
# repo_version_set.sh - write a version into the repo's version source.
# Sibling of repo_version_at.sh (which reads): used by repo_release.sh
# to stamp the computed next version into the version file on the base
# branch during the release commit.
#
# Usage: repo_version_set.sh <version>
#   Prints the path of the updated source file on stdout.
#   Exit 2 = no version source found; exit 1 = write failed.
#
# Resolution order (mirrors repo_version_at.sh):
#   1. repo adapter canon/version_source.sh set <version>
#   2. project.json version.file + version.regex (regex is rewritten
#      with the new version substituted into its first capture group)
#   3. autodetect: pyproject.toml [project].version, package.json
#      .version, Cargo.toml [package].version, VERSION, setup.cfg
#      [metadata].version - first hit wins, same order as the reader.
set -euo pipefail
# CANON_DIR resolves from the script location, not the git top: in
# nested workspaces the git top may be a subdir like
# code/ while canon/ lives at the workspace root.
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$TOP"
VER="${1:?usage: repo_version_set.sh <version>}"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.a-zA-Z0-9-]*)?$ ]] || {
  echo "repo_version_set: not a semver: $VER" >&2; exit 2; }

# 1. repo-declared adapter
if [ -x "$CANON_DIR/version_source.sh" ]; then
  "$CANON_DIR/version_source.sh" set "$VER" && exit 0
  echo "repo_version_set: adapter version_source.sh failed" >&2; exit 1
fi

# 2. project.json-declared file+regex
PJ="$CANON_DIR/project.json"
PJ_V=$(PJ="$PJ" python3 -I - 2>/dev/null <<'PY' || true
import json, os, sys
try:
    v = (json.load(open(os.environ["PJ"], encoding="utf-8")).get("version") or {})
except Exception:
    sys.exit(1)
# Both keys mandatory: a 'version' block without regex would crash
# below with KeyError and no diagnosis.
if isinstance(v.get("file"), str) and isinstance(v.get("regex"), str):
    print(v["file"]); print(v["regex"]); sys.exit(0)
sys.exit(1)
PY
)
if [ -n "$PJ_V" ]; then
  VFILE=$(printf '%s\n' "$PJ_V" | sed -n 1p)
  VREGEX=$(printf '%s\n' "$PJ_V" | sed -n 2p)
  # The declared file must be a normalized relative path inside the
  # repo - a project.json pointing at '../x' or '/etc/y' would make
  # the release commit write outside the worktree.
  VFILE="$VFILE" python3 -I -c 'import os,sys
vf = os.environ["VFILE"]
n = os.path.normpath(vf)
if os.path.isabs(vf) or n.startswith("..") or n in ("", "."):
    sys.exit(2)' || { echo "repo_version_set: unsafe version.file in project.json" >&2; exit 2; }
  VER="$VER" VFILE="$VFILE" VREGEX="$VREGEX" python3 -I - <<'PY'
import os, re, sys
vf, vr, ver = os.environ["VFILE"], os.environ["VREGEX"], os.environ["VER"]
try:
    body = open(vf, encoding="utf-8").read()
except OSError:
    sys.exit(2)
m = re.search(vr, body)
if not m:
    sys.exit(2)
start, end = m.span(1) if m.groups() else m.span(0)
open(vf, "w", encoding="utf-8").write(body[:start] + ver + body[end:])
print(vf)
PY
  rc=$?
  # A DECLARED version source that fails to match must not fall
  # through to autodetect - writing some other file's 'version' key
  # creates the version_drift the reader flags later. Fail closed.
  [ $rc -eq 0 ] || { echo "repo_version_set: declared version file/regex did not match" >&2; exit 2; }
  exit 0
fi

# 3. autodetect common manifests - SAME order and SAME section
# anchors as repo_version_at.sh (pyproject [project], package.json,
# Cargo [package], VERSION, setup.cfg [metadata]); divergent order or
# an unanchored pattern writes the version the reader will not find.
VER="$VER" python3 -I - <<'PY'
import json, os, re, sys
ver = os.environ["VER"]
# Section boundary must match a REAL TOML table header, not any line
# starting with '[' - a multiline array value (`[`/`["dep", "x"]` on
# its own line) inside the section is content, not a boundary.
_HDR = r"^\[\[?[A-Za-z0-9_.-][A-Za-z0-9_.'\" \t-]*\]\]?[ \t]*(?:#.*)?$"
try:
    import tomllib
except ImportError:
    tomllib = None
def toml_get(body, *keys):
    # Structural read-back (3.11+): the regex may have replaced a
    # 'version =' line inside a multiline string or inline table -
    # tomllib sees the REAL table field.
    if tomllib is None:
        return None
    try:
        d = tomllib.loads(body)
        for k in keys:
            d = d[k]
        return d if isinstance(d, str) else None
    except Exception:
        return None
candidates = [
    ("pyproject.toml", r'(?ms)(^\[project\](?:(?!' + _HDR + r').)*?^\s*version\s*=\s*["\'])([^"\']+)(["\'])',
     ("project", "version")),
    # package.json: anchor the key at top-level indent so a nested
    # "version" (engines/plugin config) can never shadow the root
    # field - and verify the write with json.loads afterwards.
    ("package.json",   r'(?m)^([ \t]{1,4}"version"\s*:\s*")([^"]+)(")',
     None),
    ("Cargo.toml",     r'(?ms)(^\[package\](?:(?!' + _HDR + r').)*?^\s*version\s*=\s*["\'])([^"\']+)(["\'])',
     ("package", "version")),
]
for path, pat, toml_path in candidates:
    if not os.path.isfile(path):
        continue
    body = open(path, encoding="utf-8").read()
    m = re.search(pat, body)
    if not m:
        continue
    new = body[:m.start(2)] + ver + body[m.end(2):]
    if path == "package.json":
        # Structural post-check: the ROOT version must read back as
        # the value written - a regex hit inside a nested block is a
        # miss, not a silent write.
        try:
            if json.loads(new).get("version") != ver:
                continue
        except Exception:
            continue
    elif toml_path and tomllib is not None:
        # Structural post-check, same idea as package.json: when the
        # ORIGINAL is valid TOML, the rewritten text must also parse
        # and read `ver` back at the real table path - a regex hit
        # inside a multiline string/inline table is a miss, not a
        # silent write. An unparseable original has no structural
        # field to corrupt, so the regex write stands (the file's
        # 'version' is textual-only anyway).
        try:
            tomllib.loads(body)
            orig_parses = True
        except Exception:
            orig_parses = False
        if orig_parses and toml_get(new, *toml_path) != ver:
            continue   # regex hit text, not the real table field
    open(path, "w", encoding="utf-8").write(new)
    print(path)
    sys.exit(0)
if os.path.isfile("VERSION"):
    open("VERSION", "w", encoding="utf-8").write(ver + "\n")
    print("VERSION")
    sys.exit(0)
if os.path.isfile("setup.cfg"):
    body = open("setup.cfg", encoding="utf-8").read()
    m = re.search(r'(?ms)(^\[metadata\](?:(?!' + _HDR + r').)*?^\s*version\s*=\s*)(\S+)', body)
    if m:
        open("setup.cfg", "w", encoding="utf-8").write(body[:m.start(2)] + ver + body[m.end(2):])
        print("setup.cfg")
        sys.exit(0)
sys.exit(2)
PY
rc=$?
[ $rc -eq 0 ] || echo "repo_version_set: no version source found" >&2
exit $rc
