#!/usr/bin/env bash
# repo_version_at.sh <git-ref> - stack-neutral project version probe.
# Prints the project version found at <git-ref> on stdout, or nothing
# when no version source exists. Canonical adapters in priority order:
#   1. repo-declared adapter canon/version_source.sh <ref> -> stdout
#   2. canon/project.json version.file + version.regex (1st group)
#   3. autodetect: pyproject.toml [project].version, package.json
#      .version, Cargo.toml [package].version, VERSION, setup.cfg
#      [metadata].version
# Used by repo_merge.sh (bump gate) and repo_release.sh (tag derive);
# single resolver so the two never diverge. repo_version_set.sh MUST
# mirror this order and the section-anchored patterns.
set -uo pipefail
REF="${1:?usage: repo_version_at.sh <git-ref>}"
# CANON_DIR resolves from the script location, not the git top: in
# nested workspaces the git top may be a subdir like
# code/ while canon/ lives at the workspace root.
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || exit 0

if [ -x "$CANON_DIR/version_source.sh" ]; then
  "$CANON_DIR/version_source.sh" "$REF" 2>/dev/null | head -1
  exit 0
fi

REF="$REF" TOP="$TOP" CANON_DIR="$CANON_DIR" python3 -I - <<'PY'
import json, os, re, subprocess, sys
ref, top, canon_dir = os.environ["REF"], os.environ["TOP"], os.environ["CANON_DIR"]

def show(path):
    r = subprocess.run(["git", "-C", top, "show", "%s:%s" % (ref, path)],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None

try:
    pj = json.load(open(os.path.join(canon_dir, "project.json")))
    v = pj.get("version") or {}
    vf, rx = v.get("file"), v.get("regex")
    if vf and rx:
        body = show(vf)
        if body:
            m = re.search(rx, body)
            if m:
                print(m.group(1) if m.groups() else m.group(0))
                sys.exit(0)
except Exception:
    pass

# Section-anchored patterns: `version` must be found inside the
# declaring section only - an unanchored `^version =` would match a
# [tool.*]/[dependency] version and report the wrong number.
body = show("pyproject.toml")
if body:
    m = re.search(r"(?ms)^\[project\](?:(?!^\[).)*?^\s*version\s*=\s*[\"']([^\"']+)", body)
    if m:
        print(m.group(1)); sys.exit(0)
body = show("package.json")
if body:
    try:
        v = json.loads(body).get("version")
        if v:
            print(v); sys.exit(0)
    except Exception:
        pass
body = show("Cargo.toml")
if body:
    m = re.search(r"(?ms)^\[package\](?:(?!^\[).)*?^\s*version\s*=\s*[\"']([^\"']+)", body)
    if m:
        print(m.group(1)); sys.exit(0)
body = show("VERSION")
if body:
    print(body.strip().splitlines()[0].strip()); sys.exit(0)
body = show("setup.cfg")
if body:
    m = re.search(r"(?ms)^\[metadata\](?:(?!^\[).)*?^\s*version\s*=\s*(\S+)", body)
    if m:
        print(m.group(1)); sys.exit(0)
PY
