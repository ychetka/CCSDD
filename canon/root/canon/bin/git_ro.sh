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

# No arg may smuggle a file write or shell hook.
for a in "$@"; do
  case "$a" in
    --output*|--work-tree*|--git-dir*|--exec*|--upload-pack*) \
      die "forbidden flag in read-only op: $a";;
  esac
done

case "$op" in
  status|diff|log|show|rev-parse|rev-list|merge-base|\
  ls-files|ls-remote|blame|cat-file|for-each-ref)
    exec git "$op" "$@";;
  branch)
    # Every arg must be a list-ish flag or a --list pattern - a bare
    # branch name would CREATE a branch.
    for a in "$@"; do
      case "$a" in
        -l|--list|--list=*|--show-current|-v|-vv|-a|-r|--merged|--no-merged|\
        --contains|--points-at|--sort=*|--format=*|--abbrev*|--column*|\
        --no-column|*'?'*|*'*'*|*'['*) :;;
        *) die "git_ro: branch argument not allowed: $a";;
      esac
    done
    exec git branch "$@";;
  remote)
    case "${1:-}" in
      -v|--verbose) [ $# -eq 1 ] || die "git_ro: remote -v takes no args"; exec git remote -v;;
      get-url)      exec git remote get-url "$2";;
      *) die "git_ro: remote subcommand not allowed: ${1:-<none>}";;
    esac;;
  worktree)
    [ "${1:-}" = "list" ] || die "git_ro: only 'worktree list' is read-only"
    shift; exec git worktree list "$@";;
  *)
    die "git_ro: operation not allowed: $op";;
esac
