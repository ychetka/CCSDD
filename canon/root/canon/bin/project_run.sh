#!/usr/bin/env bash
# project_run.sh <check_name> [-- extra args...] - the ONLY way an
# agent runs a project-declared command.
#
# Runtimes compile Exec() prefixes, and a prefix is a BROADENING
# primitive: Exec(python3 -m pytest) also admits 'python3 -m pytest
# -o plugin=<evil>' where the interpreter's own flags smuggle code
# around exec.deny. So adapters must never compile project.json
# gate_checks into the runtime allow-list - the allow set keeps only
# canon/bin (and its .devin/bin alias), and every project check goes
# through this wrapper, which:
#   * resolves the argv from canon/project.json gate_checks.<name>
#     (fail-closed: undeclared names and *_optional flags refuse),
#   * execs it under env -i with a minimal whitelist - the argv comes
#     from a WRITABLE workspace file, so caller secrets
#     (SSH_AUTH_SOCK, GH_TOKEN, ...) must never reach it,
#   * refuses shell heads: 'bash -c <string>' inside gate_checks
#     would re-import every bypass the argv form exists to close.
#
# Exit: 2 usage/config error; the check's own exit code otherwise.
set -euo pipefail
CANON_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"

die() { echo "project_run: $*" >&2; exit 2; }
[ $# -ge 1 ] || die "usage: project_run.sh <check_name> [-- extra args]"
CHECK="$1"; shift || true
case "$CHECK" in
  *[!a-z0-9_-]*) die "invalid check name: $CHECK";;
esac

ARGV=$(CANON_DIR="$CANON_DIR" CHECK="$CHECK" python3 -I -c '
import json, os, shlex
try:
    gc = json.load(open(os.path.join(os.environ["CANON_DIR"],
                                     "project.json"))).get("gate_checks") or {}
except Exception:
    print("ERR:pj"); raise SystemExit(0)
name = os.environ["CHECK"]
v = gc.get(name)
if name.endswith("_optional") or not isinstance(v, list) or not v \
        or not all(isinstance(a, str) and a for a in v):
    print("ERR:undeclared"); raise SystemExit(0)
elems = [str(a) for a in v]
head = elems[0].rsplit("/", 1)[-1]
if head in {"sh","bash","zsh","dash","fish","env","eval","source"}:
    print("ERR:shell-head"); raise SystemExit(0)
# NUL/tab cannot survive the TSV handoff to bash - reject rather
# than silently split an element.
if any("\t" in e or "\x00" in e for e in elems):
    print("ERR:elem"); raise SystemExit(0)
print("\t".join(elems))' 2>/dev/null || echo "ERR:py")

case "$ARGV" in
  ERR:pj|ERR:py)      die "cannot read canon/project.json" ;;
  ERR:undeclared)     die "no gate_checks.$CHECK argv in canon/project.json (declare it or use *_optional)" ;;
  ERR:shell-head)     die "gate_checks.$CHECK head is a shell - exec a binary directly" ;;
  ERR:elem)           die "gate_checks.$CHECK carries a tab/NUL element" ;;
  "")                 die "empty gate_checks.$CHECK argv" ;;
esac
IFS=$'\t' read -r -a PARGV <<< "$ARGV"

EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in --) shift; break;; esac
  EXTRA+=("$1"); shift
done

# env -i whitelist (same contract as verify_worktree baseline):
# project argv never inherits caller credentials or shell state.
exec env -i \
  "PATH=${PATH:-/usr/bin:/bin}" \
  "HOME=${HOME:-/tmp}" \
  "TMPDIR=${TMPDIR:-/tmp}" \
  "LANG=${LANG:-C.UTF-8}" \
  "LC_ALL=${LC_ALL:-$LANG}" \
  "USER=${USER:-agent}" \
  ${PYTHONPATH:+"PYTHONPATH=$PYTHONPATH"} \
  ${NODE_PATH:+"NODE_PATH=$NODE_PATH"} \
  "${PARGV[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
