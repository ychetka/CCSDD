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
export PYTHONDONTWRITEBYTECODE=1  # canon bin imports must not litter __pycache__
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null \
      || git -C code rev-parse --show-toplevel 2>/dev/null \
      || git -C "$CANON_DIR/../code" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "not a git repo" >&2; exit 1; }
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
      # JS repos: same network-free default as the Python path -
      # `npm ci` reaches the registry, executes the lockfile's
      # install scripts surface and breaks air-gapped runners.
      # The default runs the baseline against an already prepared
      # node_modules (NODE_PATH + .bin on PATH, mirroring the
      # PYTHONPATH approach); an explicit npm ci is opt-in only via
      # VW_ALLOW_INSTALL=1 (local/debug - never in gates).
      if [ "${VW_ALLOW_INSTALL:-0}" = "1" ]; then
        (cd "$WT" && ${TIMEOUT_BIN:+$TIMEOUT_BIN 300} \
          npm ci --silent --ignore-scripts) >/dev/null 2>&1 || ENV_RC=$?
      else
        # $WT is a fresh detached worktree - node_modules is never in
        # git, so it cannot exist there. Dependencies come from the
        # prepared main workspace ($TOP/node_modules); a baseline_env.sh
        # adapter may instead create $WT/node_modules itself.
        # Trust bound: the $TOP fallback applies only when $TOP is the
        # main workspace. Detect a linked worktree by git-dir vs
        # git-common-dir, NOT the canon symlink - an agent can delete
        # $TOP/canon to look like a main workspace and plant
        # node_modules/.bin/pytest to run under gate creds.
        NM_DIR="$WT/node_modules"
        _gd=$(git -C "$TOP" rev-parse --absolute-git-dir 2>/dev/null)
        _gcd=$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
        if [ ! -d "$NM_DIR" ] && { [ -z "$_gd" ] || [ "$_gd" = "$_gcd" ]; }; then
          NM_DIR="$TOP/node_modules"
        fi
        if [ -d "$NM_DIR" ]; then
          export NODE_PATH="$NM_DIR${NODE_PATH:+:$NODE_PATH}"
          export PATH="$NM_DIR/.bin:$PATH"
        else
          ENV_RC=2   # no prepared node_modules and installs are off
        fi
      fi
    elif [ -f "$WT/pyproject.toml" ] || [ -f "$WT/setup.py" ] \
         || ls "$WT"/requirements*.txt >/dev/null 2>&1; then
      # Python repos: the baseline runs on the system interpreter
      # with PYTHONPATH pointed at the worktree - NO pip install.
      # An editable/sdist install executes the candidate's own
      # setup.py/build-backend code in the verifier's context, and
      # a network fetch violates the judge's no-network contract
      # (plus breaks air-gapped runners). Projects that genuinely
      # need a built env declare the pinned canon/baseline_env.sh
      # adapter above, or the operator opts in explicitly via
      # VW_ALLOW_INSTALL=1 (local/debug use only - never in gates).
      if [ "${VW_ALLOW_INSTALL:-0}" = "1" ]; then
        python3 -I -m venv "$WT/.venv" >/dev/null 2>&1 || ENV_RC=$?
        if [ "$ENV_RC" = "0" ]; then
          for REQ in "$WT"/requirements*.txt; do
            [ -f "$REQ" ] || continue
            (cd "$WT" && ${TIMEOUT_BIN:+$TIMEOUT_BIN 300} \
              "$WT/.venv/bin/pip" install -q -r "$REQ") >/dev/null 2>&1 \
              || { ENV_RC=$?; break; }
          done
          if [ "$ENV_RC" = "0" ] && \
             { [ -f "$WT/pyproject.toml" ] || [ -f "$WT/setup.py" ]; }; then
            (cd "$WT" && ${TIMEOUT_BIN:+$TIMEOUT_BIN 300} \
              "$WT/.venv/bin/pip" install -q -e .) >/dev/null 2>&1 || ENV_RC=$?
          fi
        fi
      else
        # src-layout first (src/ shadows the repo root in sys.path
        # order so both layouts work); no .pth, no site-packages
        # mutation, nothing the candidate tree can smuggle in.
        VW_PY_PATH="$WT"
        [ -d "$WT/src" ] && VW_PY_PATH="$WT/src:$WT"
        export PYTHONPATH="$VW_PY_PATH${PYTHONPATH:+:$PYTHONPATH}"
      fi
    fi
    if [ "$BASE_UNRESOLVED" = "1" ]; then
      BASELINE_JSON="{\"error\":\"baseline_unresolvable\",\"detail\":\"no merge-base resolved; baseline would equal HEAD - refusing to certify the branch as its own baseline\"}"
    elif [ "$ENV_RC" != "0" ]; then
      BASELINE_JSON="{\"error\":\"env_setup_failed\",\"exit\":$ENV_RC,\"baseline_sha\":\"$BASE_SHA\"}"
    else
      TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
      # The baseline executes project code (the test command and the
      # deps it loads) in whatever context invoked us - possibly the
      # merge/review credential. A NAMED denylist cannot cover
      # deployment-specific credentials (GITLAB_PRIVATE_TOKEN,
      # AWS_SECRET_ACCESS_KEY, custom review.gh_bin vars) or
      # SSH_AUTH_SOCK - the agent socket would let baseline code sign
      # artifacts as the human. env -i with a minimal whitelist is
      # the only sound boundary; the check needs a test verdict,
      # not API access.
      # PATH hygiene: an inherited PATH can carry segments pointing
      # into OTHER trees (the caller's .venv, .worktrees/<other>) -
      # a pytest/python resolved there imports editable .pth code
      # from the wrong tree under gate creds. Keep segments inside
      # $WT (the prepared toolchain) and everything outside $TOP;
      # drop anything inside $TOP but outside $WT - EXCEPT the
      # prepared $NM_DIR the env setup just vetted (main-workspace
      # node_modules is only used when $TOP is not an item worktree).
      CLEAN_PATH=$(WT="$WT" TOP="$TOP" NM="${NM_DIR:-}" python3 -I -c 'import os
wt = os.path.realpath(os.environ["WT"])
top = os.path.realpath(os.environ["TOP"])
nm = os.path.realpath(os.environ["NM"]) if os.environ.get("NM") else ""
out = []
for seg in os.environ.get("PATH", "").split(os.pathsep):
    if not seg:
        continue
    r = os.path.realpath(seg)
    try:
        if os.path.commonpath([r, wt]) == wt or \
           (nm and os.path.commonpath([r, nm]) == nm):
            out.append(seg); continue
        if os.path.commonpath([r, top]) == top:
            continue
    except ValueError:
        pass
    out.append(seg)
print(os.pathsep.join(out))')
      SAFE_ENV=(
        env -i
        "PATH=$WT/.venv/bin:$WT/node_modules/.bin:$CLEAN_PATH"
        "HOME=${HOME:-/tmp}"
        "TMPDIR=${TMPDIR:-/tmp}"
        "LANG=${LANG:-C.UTF-8}"
        "LC_ALL=${LC_ALL:-$LANG}"
        "USER=${USER:-agent}"
        ${PYTHONPATH:+"PYTHONPATH=$PYTHONPATH"}
        ${NODE_PATH:+"NODE_PATH=$NODE_PATH"}
      )
      if [ -n "$TIMEOUT_BIN" ]; then
        (cd "$WT" && "${SAFE_ENV[@]}" "$TIMEOUT_BIN" 600 bash -c "$BASELINE_CMD") >"$OUT" 2>&1
      else
        # No timeout binary (BSD/macOS without coreutils): run
        # unbounded rather than fail the baseline outright.
        (cd "$WT" && "${SAFE_ENV[@]}" bash -c "$BASELINE_CMD") >"$OUT" 2>&1
      fi
      BRC=$?
      BTAIL=$(tail -n 20 "$OUT" 2>/dev/null | python3 -I -c 'import json,sys;print(json.dumps(sys.stdin.buffer.read().decode("utf-8","replace")))')
      BASELINE_JSON="{\"exit\":$BRC,\"baseline_sha\":\"$BASE_SHA\",\"tail\":$BTAIL}"
    fi
  else
    BASELINE_JSON="{\"error\":\"worktree_add_failed\",\"baseline_sha\":\"$BASE_SHA\"}"
  fi
  cleanup
  trap - EXIT INT TERM
fi

HEAD_SHA="$HEAD_SHA" BRANCH="$BRANCH" DIRTY="$DIRTY" STAT="$STAT" \
  BASELINE_JSON="$BASELINE_JSON" TOP="$TOP" python3 -I - <<'PY'
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
# Top-level fields only: the "tail" blob is test-runner output that
# legitimately contains the substring "error" - a glob match over the
# whole JSON would fail a green baseline.
BASELINE_JSON="$BASELINE_JSON" python3 -I -c 'import json,os,sys
try:
    b = json.loads(os.environ["BASELINE_JSON"])
except Exception:
    sys.exit(1)
if b.get("error") or (b.get("exit") or 0) != 0:
    sys.exit(1)
sys.exit(0)' || exit 1
exit 0
