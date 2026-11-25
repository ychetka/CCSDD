#!/usr/bin/env bash
# assert_canon_integrity.sh - the shared "Gate 0" for every merge /
# release / verify entry point: the deployed canon tree must hash to
# canon/canon_manifest.json AND (when the deploy left one) the local
# manifest must hash to the external workspace stamp in
# ~/.config/ccsdd/workspaces/ (stamp_verify.sh).
#
# ship_commit.sh carried this check inline; the merge path used to
# run repo_version_at / verify_worktree / repo_release with nothing
# but blind trust in $CANON_DIR - a code_writer could rewrite a gate
# script or canon_manifest.json mid-cycle and have it execute under
# merge credentials. Call this FIRST in every gate script; when no
# canon_manifest.json exists (bare test fixtures) it exits clean.
#
# Exit: 0 = integrity proven or unmanaged canon; 1 = tampered.
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

[ -f "$CANON_DIR/canon_manifest.json" ] || exit 0

CANON_DIR="$CANON_DIR" python3 -I - <<'PY'
import hashlib, json, os, sys
canon_dir = os.environ["CANON_DIR"]
try:
    mf = json.load(open(os.path.join(canon_dir, "canon_manifest.json")))
    sha = mf.get("sha256", {})
except Exception:
    sys.stderr.write("canon_manifest.json unreadable - integrity unknown\n")
    sys.exit(1)
if not isinstance(sha, dict) or not sha:
    # An empty sha256 table verifies nothing - the loop below would
    # pass vacuously on {"sha256": {}}.
    sys.stderr.write("canon_manifest.json sha256 table empty - refuse\n")
    sys.exit(1)
files = mf.get("files")
if files is not None and (
        not isinstance(files, list)
        or set(str(f) for f in files) != set(sha.keys())):
    sys.stderr.write("canon_manifest.json files/sha256 mismatch - refuse\n")
    sys.exit(1)
bad = []
# Verify EVERY manifest-covered file, not a script subset: a pinned
# spec/agent/config edit is as much canon drift as a rewritten gate,
# and partial coverage left the non-script half unchecked.
for rel, want in sorted(sha.items()):
    if not isinstance(rel, str) or not rel.startswith("canon/"):
        continue
    if not isinstance(want, str):
        bad.append(rel + " (unpinned)")
        continue
    p = os.path.normpath(os.path.join(canon_dir, rel[len("canon/"):]))
    if not p.startswith(canon_dir.rstrip("/") + "/"):
        bad.append(rel + " (path escape)")
        continue
    try:
        got = hashlib.sha256(open(p, "rb").read()).hexdigest()
    except OSError:
        bad.append(rel + " (unreadable)")
        continue
    if got != want:
        bad.append(rel)
# Adapter hooks (project-installed version_source.sh / baseline_env.sh
# / canon/tools/*) are pinned separately in adapters_sha256: merge
# paths execute them under gate creds, so a rewritten hook is as
# fatal as a rewritten gate script.
pinned = mf.get("adapters_sha256") or {}
if not isinstance(pinned, dict):
    sys.stderr.write("canon_manifest.json adapters_sha256 malformed - refuse\n")
    sys.exit(1)
for rel, want in sorted(pinned.items()):
    if not isinstance(rel, str) or not rel.startswith("canon/"):
        bad.append(rel + " (adapter path escape)")
        continue
    p = os.path.normpath(os.path.join(canon_dir, rel[len("canon/"):]))
    if not p.startswith(canon_dir.rstrip("/") + "/"):
        bad.append(rel + " (adapter path escape)")
        continue
    try:
        got = hashlib.sha256(open(p, "rb").read()).hexdigest()
    except OSError:
        bad.append(rel + " (adapter unreadable)")
        continue
    if got != want:
        bad.append(rel + " (adapter drift)")
# A hook that exists on disk but is NOT pinned executes unsigned:
# refuse rather than trust it.
HOOKS = ("version_source.sh", "baseline_env.sh")
unsigned = []
for h in HOOKS:
    rel = "canon/" + h
    if rel not in pinned and rel not in sha and os.path.exists(
            os.path.join(canon_dir, h)):
        unsigned.append(rel)
tools_dir = os.path.join(canon_dir, "tools")
if os.path.isdir(tools_dir):
    for dp, _dn, fns in os.walk(tools_dir):
        for name in sorted(fns):
            rel = "canon/" + os.path.relpath(
                os.path.join(dp, name), canon_dir)
            if rel not in pinned and rel not in sha:
                unsigned.append(rel)
if unsigned:
    sys.stderr.write("unsigned adapter hooks present (not in "
                     "adapters_sha256): " + ", ".join(unsigned) + "\n")
    sys.exit(1)
if bad:
    sys.stderr.write("canon files differ from canon_manifest sha256: "
                     + ", ".join(bad[:12]) + "\n")
    sys.exit(1)
PY
[ $? -eq 0 ] || {
  echo "GATE_INTEGRITY: gate scripts do not match canon_manifest.json - refuse to run rewritten gates" >&2
  exit 1
}
# The manifest itself is workspace state: when the deploy left an
# external stamp in ~/.config/ccsdd/workspaces/, the local manifest
# must hash to it - otherwise the sha256 table above is self-
# attested and proves nothing.
if [ -x "$CANON_DIR/bin/stamp_verify.sh" ]; then
  SRC=0; "$CANON_DIR/bin/stamp_verify.sh" || SRC=$?
  case "$SRC" in
    0|3) ;;   # match, or unmanaged workspace (no stamp)
    *) echo "GATE_INTEGRITY: canon_manifest.json fails the external stamp check - refuse to run on a rewritten manifest" >&2
       exit 1 ;;
  esac
fi
exit 0
