#!/usr/bin/env bash
# stamp_verify.sh [--require] - root-of-trust check for the deployed
# canon stamp.
#
# canon/canon_manifest.json lives inside the agent's WRITABLE
# workspace: Gate 0-style hash pins only raise tampering from a
# one-file edit to a two-file edit (manifest + target). start_project
# therefore also writes a stamp OUTSIDE the workspace, next to
# allowed_signers:
#     ~/.config/ccsdd/workspaces/<sha256(abs workspace path)>.json
# carrying the sha256 of the deployed canon_manifest.json itself.
# An agent that rewrites both gate scripts and the local manifest
# still cannot forge the external stamp without leaving the sandbox
# (and check_setup runs there anyway).
#
# Exit: 0 = external stamp matches;
#       1 = stamp exists and mismatches (manifest was rewritten), or
#           with --require no stamp at all;
#       2 = stamp exists but unreadable/corrupt (fail-closed);
#       3 = no external stamp (unmanaged workspace).
set -euo pipefail
REQUIRE=0
[ "${1:-}" = "--require" ] && REQUIRE=1
CANON_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
WS_DIR="$(cd -P "$CANON_DIR/.." && pwd)"

python3 -I - "$WS_DIR" "$CANON_DIR" "$REQUIRE" <<'PY'
import hashlib, json, os, sys
ws, canon, require = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
home = os.environ.get("HOME") or "/tmp"
key = hashlib.sha256(os.path.realpath(ws).encode()).hexdigest()
stamp = os.path.join(home, ".config", "ccsdd", "workspaces", key + ".json")
local = os.path.join(canon, "canon_manifest.json")
if not os.path.exists(stamp):
    if require:
        print(f"stamp_verify: no external stamp at {stamp} "
              f"(workspace not deployed via start_project.sh)",
              file=sys.stderr)
        sys.exit(1)
    sys.exit(3)  # unmanaged workspace - nothing to compare against
try:
    want = json.load(open(stamp))["manifest_sha256"]
except Exception as e:
    print(f"stamp_verify: external stamp unreadable: {e}",
          file=sys.stderr)
    sys.exit(2)
try:
    got = hashlib.sha256(open(local, "rb").read()).hexdigest()
except OSError as e:
    print(f"stamp_verify: local manifest unreadable: {e}",
          file=sys.stderr)
    sys.exit(1)
if got != want:
    print("stamp_verify: canon_manifest.json differs from the "
          "deploy-time external stamp - the in-workspace manifest "
          "was rewritten after deploy (Gate 0 hashes are no longer "
          "meaningful; re-run check_setup.sh for diagnostics)",
          file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
