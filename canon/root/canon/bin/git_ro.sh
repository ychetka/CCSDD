#!/usr/bin/env bash
# git_ro.sh <op> [args...] - whitelisted READ-ONLY git operations.
#
# The compiled exec policy denies the `git` binary for every actor;
# this wrapper is the legal introspection path for the git agent
# (status/log/diff requests from the calling instance) and for any
# agent that needs repository facts. Mutating verbs and any arg
# that can write files or reach the network are rejected.
#
# Allowed ops:
#   status  diff  log  show  rev-parse  rev-list  merge-base
#   ls-files  ls-remote  blame  cat-file  for-each-ref
#   branch     (only: no args, -l/--list pattern)
#   remote     (only: -v, get-url <name>)
#   worktree   (only: list)
#   fetch, checkout, switch, commit, push, pull, merge, rebase,
#   reset, clean, stash, tag, worktree <add|remove>, ... - DENIED
#   (mutations live in ship_*/repo_* wrappers or not at all).
set -euo pipefail

die() { echo "git_ro: $1" >&2; exit 2; }
[ $# -ge 1 ] || die "usage: git_ro.sh <op> [args...]"
op="$1"; shift

# No arg may smuggle a file write, a shell hook, an external diff
# driver, or a read of files outside the repository (--no-index
# compares arbitrary filesystem paths - it is not repo introspection).
for a in "$@"; do
  case "$a" in
    --output*|--work-tree*|--git-dir*|--exec*|--upload-pack*|--no-index*) \
      die "forbidden flag in read-only op: $a";;
  esac
done

case "$op" in
  diff)
    # --no-ext-diff pins the builtin differ: repo config (diff.external
    # / diff.<driver>.command) is attacker-controlled workspace state.
    exec git diff --no-ext-diff "$@";;
  status|log|show|rev-parse|rev-list|merge-base|\
  ls-files|ls-remote|blame|cat-file|for-each-ref)
    exec git "$op" "$@";;
  branch)
    # Every arg must be a list-ish flag or a --list pattern. A bare
    # branch name would CREATE a branch - names are allowed only when
    # a list flag is present (`branch -l main`, `--contains <sha>`).
    listy=0; names=0
    for a in "$@"; do
      case "$a" in
        -l|--list|--list=*|--show-current|--merged|--no-merged|\
        --contains|--contains=*|--points-at|--points-at=*) listy=1;;
        -v|-vv|-a|-r|--sort=*|--format=*|--abbrev*|--column*|\
        --no-column|*'?'*|*'*'*|*'['*) :;;
        [A-Za-z0-9._/-]*) names=1;;
        *) die "git_ro: branch argument not allowed: $a";;
      esac
    done
    [ "$names" -eq 0 ] || [ "$listy" -eq 1 ] \
      || die "git_ro: branch name args require a list flag (-l/--list/...)"
    exec git branch "$@";;
  remote)
    case "${1:-}" in
      -v|--verbose) [ $# -eq 1 ] || die "git_ro: remote -v takes no args"; exec git remote -v;;
      get-url)      exec git remote get-url "${2:?remote name required}";;
      *) die "git_ro: remote subcommand not allowed: ${1:-<none>}";;
    esac;;
  worktree)
    [ "${1:-}" = "list" ] || die "git_ro: only 'worktree list' is read-only"
    shift; exec git worktree list "$@";;
  *)
    die "git_ro: operation not allowed: $op";;
esac
