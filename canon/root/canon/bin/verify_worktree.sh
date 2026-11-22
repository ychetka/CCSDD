#!/usr/bin/env bash
# verify_worktree.sh - deterministic signed worktree report.
# The director's "blood signature" made mechanical: agent instances are
# forbidden from running git directly, so this whitelisted script
# produces the evidence a director must verify personally before
# reporting or merging - current branch/HEAD, dirty tree list,
# diff stat vs HEAD, and (optionally) a BASELINE test run executed
# on a CLEAN temporary worktree at the merge-base so a judge never
# certifies tests that only pass thanks to the branch's uncommitted
# state.
#
# Usage:
#   verify_worktree.sh                      - report only
#   verify_worktree.sh --baseline-test CMD  - also run CMD on a clean
#                                             worktree of the base
#   verify_worktree.sh --base ref           - base ref for merge-base
# Output: JSON {head, branch, dirty_files[], diff_stat, baseline?,
#               digest}
#
# Digest semantics: the sha256 digest covers the report fields and
# proves INTERNAL CONSISTENCY of a pasted report (its fields were
# produced together by one run of this script). It is unkeyed - it
# does NOT authenticate provenance. The blood-sign is valid because
# the merge gate runs the deployed script itself and parses the
# JSON, not because the digest is secret.
#
# --baseline-test CMD is the contract: the director supplies a test
# command that runs via bash -c on the clean baseline worktree. It is
# arbitrary shell BY DESIGN (a test command is code). Mitigations:
# the command runs inside the detached baseline worktree only, under
# a 600s timeout, and env setup prefers --ignore-scripts installs.
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null || git -C code rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd -P "$TOP"

BASELINE_CMD=""
BASE_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --baseline-test) [ $# -ge 2 ] || { echo "usage error: --baseline-test needs a command" >&2; exit 2; }
                     BASELINE_CMD="$2"; shift 2 ;;
    --base)          [ $# -ge 2 ] || { echo "usage error: --base needs a ref" >&2; exit 2; }
                     BASE_REF="$2"
                     case "$BASE_REF" in
                       *[!A-Za-z0-9._/^-]*|''|-*|*..*) echo "usage error: --base is not a valid ref name" >&2; exit 2 ;;
                     esac
                     shift 2 ;;
    *) echo "usage: verify_worktree.sh [--baseline-test CMD] [--base ref]" >&2; exit 2 ;;
  esac
done

HEAD_SHA=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
DIRTY=$(git status --porcelain 2>/dev/null || true)
STAT=$(git diff HEAD --stat 2>/dev/null || true)

BASELINE_JSON='{"status":"skipped","exit":0}'
if [ -n "$BASELINE_CMD" ]; then
  # The baseline is the merge-base with the target base branch (what
  # main looked like when the branch diverged), not blindly the
  # branch HEAD - tests green at HEAD certify the branch, not the
  # base. An unresolvable base is reported explicitly, never
  # silently substituted with HEAD.
  BASE_SHA="" BASE_UNRESOLVED=0
  if [ -n "$BASE_REF" ]; then
    # Probe every configured remote like verify_constraints does -
    # the github remote is not always 'origin'.
    for cand in $(git remote 2>/dev/null | sed "s#\$#/$BASE_REF#") "$BASE_REF"; do
      BASE_SHA=$(git merge-base HEAD "$cand" 2>/dev/null) && break || BASE_SHA=""
    done
    # A resolved merge-base that IS the branch head means zero branch
    # commits - the 'baseline' would be the branch itself. That is a
    # refusal, not a pass.
    if [ "$BASE_SHA" = "$HEAD_SHA" ]; then BASE_UNRESOLVED=1; fi
  else
    for cand in origin/main origin/master main master; do
      MB=$(git merge-base HEAD "$cand" 2>/dev/null || true)
      if [ -n "$MB" ] && [ "$MB" != "$HEAD_SHA" ]; then BASE_SHA="$MB"; break; fi
    done
  fi
  [ -n "$BASE_SHA" ] && [ "$BASE_SHA" != "$HEAD_SHA" ] || { BASE_SHA="$HEAD_SHA"; BASE_UNRESOLVED=1; }
  WT=$(mktemp -d "${TMPDIR:-/tmp}/verify-baseline.XXXXXX")
  OUT=$(mktemp "${TMPDIR:-/tmp}/verify-baseline-out.XXXXXX")
  cleanup() {
    git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT" 2>/dev/null
    rm -f "$OUT" 2>/dev/null
  }
  trap cleanup EXIT INT TERM
  if git worktree add --detach "$WT" "$BASE_SHA" >/dev/null 2>&1; then
    # Isolated baseline env: symlinking .venv/node_modules from the
    # working tree would import the BRANCH's own code via editable
    # .pth installs and falsify the baseline as "pre-existing".
    # Build the toolchain inside the clean worktree instead:
    # repo adapter canon/baseline_env.sh wins, then npm ci with
    # --ignore-scripts, then a fresh venv. An env-setup failure is a
    # distinct error - not a test failure and never silently skipped.
    ENV_RC=0
    TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
    # The env adapter comes from the deployed control plane
    # ($CANON_DIR), never from $TOP - inside a PR worktree the
    # worktree copy is agent-controlled.
    if [ -x "$CANON_DIR/baseline_env.sh" ]; then
      bash "$CANON_DIR/baseline_env.sh" "$WT" >/dev/null 2>&1 || ENV_RC=$?
    elif [ -f "$WT/package.json" ]; then
      (cd "$WT" && ${TIMEOUT_BIN:+$TIMEOUT_BIN 300} \
        npm ci --silent --ignore-scripts) >/dev/null 2>&1 || ENV_RC=$?
    elif [ -f "$WT/pyproject.toml" ] || [ -f "$WT/setup.py" ] \
         || ls "$WT"/requirements*.txt >/dev/null 2>&1; then
      # Python repos: venv + requirements (dev deps included) beats a
      # bare `pip install -e .`, which fails outright on projects
      # whose packaging needs a backend the venv does not ship.
      # Every network step is bounded by the same timeout binary.
      python3 -m venv "$WT/.venv" >/dev/null 2>&1 || ENV_RC=$?
      if [ "$ENV_RC" = "0" ]; then
        REQ=$(ls "$WT"/requirements*.txt 2>/dev/null | head -n1 || true)
        if [ -n "$REQ" ]; then
          (cd "$WT" && ${TIMEOUT_BIN:+$TIMEOUT_BIN 300} \
            "$WT/.venv/bin/pip" install -q -r "$REQ") >/dev/null 2>&1 || ENV_RC=$?
        else
          (cd "$WT" && ${TIMEOUT_BIN:+$TIMEOUT_BIN 300} \
            "$WT/.venv/bin/pip" install -q -e .) >/dev/null 2>&1 || ENV_RC=$?
        fi
      fi
    fi
    if [ "$BASE_UNRESOLVED" = "1" ]; then
      BASELINE_JSON="{\"error\":\"baseline_unresolvable\",\"detail\":\"no merge-base resolved; baseline would equal HEAD - refusing to certify the branch as its own baseline\"}"
    elif [ "$ENV_RC" != "0" ]; then
      BASELINE_JSON="{\"error\":\"env_setup_failed\",\"exit\":$ENV_RC,\"baseline_sha\":\"$BASE_SHA\"}"
    else
      TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
      if [ -n "$TIMEOUT_BIN" ]; then
        (cd "$WT" && PATH="$WT/.venv/bin:$WT/node_modules/.bin:$PATH" \
          "$TIMEOUT_BIN" 600 bash -c "$BASELINE_CMD") >"$OUT" 2>&1
      else
        # No timeout binary (BSD/macOS without coreutils): run
        # unbounded rather than fail the baseline outright.
        (cd "$WT" && PATH="$WT/.venv/bin:$WT/node_modules/.bin:$PATH" \
          bash -c "$BASELINE_CMD") >"$OUT" 2>&1
      fi
      BRC=$?
      BTAIL=$(tail -n 20 "$OUT" 2>/dev/null | python3 -c 'import json,sys;print(json.dumps(sys.stdin.buffer.read().decode("utf-8","replace")))')
      BASELINE_JSON="{\"exit\":$BRC,\"baseline_sha\":\"$BASE_SHA\",\"tail\":$BTAIL}"
    fi
  else
    BASELINE_JSON="{\"error\":\"worktree_add_failed\",\"baseline_sha\":\"$BASE_SHA\"}"
  fi
  cleanup
  trap - EXIT INT TERM
fi

HEAD_SHA="$HEAD_SHA" BRANCH="$BRANCH" DIRTY="$DIRTY" STAT="$STAT" \
  BASELINE_JSON="$BASELINE_JSON" TOP="$TOP" python3 - <<'PY'
import hashlib, json, os, time
dirty = [ln for ln in os.environ["DIRTY"].splitlines() if ln.strip()]
payload = {
    "ts_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "repo_top": os.environ["TOP"],
    "branch": os.environ["BRANCH"],
    "head": os.environ["HEAD_SHA"],
    "dirty_files": dirty,
    "dirty_count": len(dirty),
    "diff_stat": os.environ["STAT"].strip(),
    "baseline": json.loads(os.environ["BASELINE_JSON"]),
}
# Content hash makes the report tamper-evident for internal
# consistency only (see header: unkeyed digest != provenance proof).
payload["status"] = "signed"
payload["digest"] = hashlib.sha256(
    json.dumps(payload, sort_keys=True).encode()).hexdigest()
print(json.dumps(payload))
PY
PY_RC=$?

# A failed baseline is a FAILED CHECK, not a signed pass: the JSON is
# still emitted above for the audit trail, but the process exit code
# must refuse to read as green.
# ("status":"skipped" carries exit:0 and stays a 0.)
[ "$PY_RC" != "0" ] && exit "$PY_RC"
case "$BASELINE_JSON" in
  *'"error"'*|*'"exit":'[1-9]*) exit 1 ;;
esac
exit 0
