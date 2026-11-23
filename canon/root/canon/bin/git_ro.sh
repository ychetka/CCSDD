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
# --ext-diff/--textconv re-enable the external command drivers the
# pinned --no-ext-diff/--no-textconv below disable; --filters runs
# clean/smudge filters; -O/--find-object feeds diff an arbitrary
# object file; --paginate can invoke the configured pager.
for a in "$@"; do
  case "$a" in
    --output*|--work-tree*|--git-dir*|--exec*|--upload-pack*|--no-index*|\
    --ext-diff*|--textconv*|--filters*|--paginate*|-O*|--find-object*) \
      die "forbidden flag in read-only op: $a";;
  esac
done

# Every git call runs pinned: no pager, external differ blanked, so
# attacker-controlled repo config (core.pager, diff.external,
# diff.<driver>.command, textconv drivers) cannot execute code.
# core.fsmonitor is blanked too - git status/diff would otherwise
# spawn the monitor hook binary recorded in the repo config.
G="env GIT_PAGER=cat git --no-pager -c core.pager=cat -c diff.external= -c core.fsmonitor=false"

case "$op" in
  diff)
    # --no-ext-diff pins the builtin differ; --no-textconv disables
    # textconv drivers for binary files.
    exec $G diff --no-ext-diff --no-textconv "$@";;
  status|log|show|rev-parse|rev-list|merge-base|\
  ls-files|ls-remote|blame|cat-file|for-each-ref)
    case "$op" in
      log|show|blame) exec $G "$op" --no-ext-diff --no-textconv "$@";;
      *)              exec $G "$op" "$@";;
    esac;;
  branch)
    # Every arg must be a list-ish flag or a --list pattern. A bare
    # branch name would CREATE a branch - names are allowed only when
    # a list flag is present (`branch -l main`, `--contains <sha>`).
    listy=0; names=0
    for a in "$@"; do
      case "$a" in
        -l|--list|--list=*|--show-current|--merged|--no-merged|\
        --contains|--contains=*|--points-at|--points-at=*) listy=1;;
        -v|-vv|-a|-r|--sort=*|--format=*|--abbrev*|--column*|--no-column) :;;
        # Any other dash-leading arg is a flag we did not whitelist:
        # '-D victim' alongside '--contains HEAD' would otherwise
        # reach git and DELETE a branch inside the read-only path.
        -*) die "git_ro: branch flag not allowed: $a";;
        *) names=1;;   # bare name or glob pattern (may hold * ? [)
      esac
    done
    [ "$names" -eq 0 ] || [ "$listy" -eq 1 ] \
      || die "git_ro: branch name args require a list flag (-l/--list/...)"
    exec $G branch "$@";;
  remote)
    case "${1:-}" in
      -v|--verbose) [ $# -eq 1 ] || die "git_ro: remote -v takes no args"; exec $G remote -v;;
      get-url)      exec $G remote get-url "${2:?remote name required}";;
      *) die "git_ro: remote subcommand not allowed: ${1:-<none>}";;
    esac;;
  worktree)
    [ "${1:-}" = "list" ] || die "git_ro: only 'worktree list' is read-only"
    shift; exec $G worktree list "$@";;
  *)
    die "git_ro: operation not allowed: $op";;
esac
