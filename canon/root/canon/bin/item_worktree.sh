#!/usr/bin/env bash
# item_worktree.sh - per-item worktree lifecycle for the git agent.
#
#   item_worktree.sh open  --branch <name> [--base <ref>] [--dir <p>]
#   item_worktree.sh close --branch <name> [--keep-branch] [--force]
#   item_worktree.sh path  --branch <name>
#   item_worktree.sh list
#
# open : creates <repo-sibling>/.worktrees/<branch> on a new branch
#        off <base> (default: the primary branch's upstream, else
#        HEAD). Parallel executors never share a tree: each item gets
#        its own worktree, its own index, its own candidate commits.
#        Untracked files can no longer hide from `git diff` - the
#        judge reviews committed candidate state.
# close: removes the worktree AND its local branch once the item is
#        merged/abandoned so worktrees do not accumulate on disk.
#        --force is required when the branch is not fully merged;
#        --keep-branch removes only the worktree (remote branch/PR
#        stays - audit history is preserved).
# path : prints the worktree path for a branch (empty + rc 1 if none).
# list : `git worktree list --porcelain`.
#
# Worktrees live OUTSIDE the repository tree at
#   ${CCSDD_WT_ROOT:-<repo-parent>/.worktrees}/<branch>
# - no gitignore entry needed, the scope/hygiene gates never see them.
set -euo pipefail

die()  { echo "item_worktree: $1" >&2; exit 2; }
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not a git repo"
WT_ROOT="${CCSDD_WT_ROOT:-$(dirname "$TOP")/.worktrees}"

BRANCH=""; BASE=""; FORCE=""; KEEP=""
case "${1:-}" in
  open|close|path) VERB=$1; shift;;
  list) exec git worktree list --porcelain;;
  *) die "usage: item_worktree.sh open|close|path|list ...";;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH=$2; shift 2;;
    --base)   BASE=$2;   shift 2;;
    --force)  FORCE=1;   shift;;
    --keep-branch) KEEP=1; shift;;
    *) die "unknown flag: $1";;
  esac
done
[ -n "$BRANCH" ] || die "--branch required"
case "$BRANCH" in
  *..*|*//*|*'..'*|*' '*|*~*|*^*|*:*|*'?'*|*'*'*|*'['*|'\\'*)
    die "invalid branch name: $BRANCH";;
esac
WT="$WT_ROOT/$BRANCH"

case "$VERB" in
  path)
    [ -d "$WT" ] && { printf '%s\n' "$WT"; exit 0; }
    git worktree list --porcelain | awk -v b="refs/heads/$BRANCH" \
      '/^worktree /{p=$2} /^branch /{if($2==b){print p; exit 0}}'
    exit 1;;

  open)
    [ -e "$WT" ] && die "worktree path already exists: $WT"
    mkdir -p "$WT_ROOT"
    if [ -z "$BASE" ]; then
      BASE=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
      [ -n "$BASE" ] || BASE=HEAD
    fi
    git worktree add "$WT" -b "$BRANCH" "$BASE" \
      || die "worktree add failed for $BRANCH @ $BASE"
    echo "item_worktree: opened $WT (branch $BRANCH @ $BASE)";;

  close)
    if [ -d "$WT" ]; then
      git worktree remove ${FORCE:+--force} "$WT" \
        || die "worktree remove failed (uncommitted work? use --force)"
    else
      # already gone - still proceed to branch cleanup
      :
    fi
    if [ -z "$KEEP" ] && git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
      if git branch -d "$BRANCH" >/dev/null 2>&1; then
        echo "item_worktree: deleted merged branch $BRANCH"
      elif [ -n "$FORCE" ]; then
        git branch -D "$BRANCH" >/dev/null
        echo "item_worktree: force-deleted unmerged branch $BRANCH"
      else
        die "branch $BRANCH not fully merged - re-run with --force or --keep-branch"
      fi
    fi
    echo "item_worktree: closed $BRANCH";;
esac
