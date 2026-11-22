#!/usr/bin/env bash
# review_worktree.sh open|close --pr <N> --domain <d> [--sha <40hex>]
#
# Detached, credential-free read worktrees for panel reviewers.
# `open` creates /tmp/pr-<repo_hash>-<domain>-<N> at the PR head
# commit without touching the main checkout; `close` removes it.
# Every reviewer gets a private worktree so reads at the PR head
# never disturb the main workspace or each other. Mutations
# (checkout/branch/commit) inside the worktree are the reviewer's
# responsibility - the tree is detached and is removed by `close`
# regardless. The worktree dir carries a hash of the repo path so
# parallel reviews of PR #N in two projects never collide.
#
#   open:  sha resolved via `gh pr view` (review identity binary) or
#          --sha explicitly; a missing local object is fetched before
#          the worktree add. Prints the worktree path.
#   close: removes the worktree if present (idempotent).
set -euo pipefail
die() { echo "review_worktree: $1" >&2; exit 2; }
# Canon resolves from the script location - NEVER from
# `rev-parse --show-toplevel` (nested workspace <ws>/canon + <ws>/code
# puts the repo root beside canon, not around it).
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
TOP=$(git rev-parse --show-toplevel 2>/dev/null \
      || git -C code rev-parse --show-toplevel 2>/dev/null) \
  || die "not a git repo"
cd -P "$TOP"
REMOTE=$(git remote 2>/dev/null | head -1 || true)
CMD="${1:-}"; shift || true
[ -n "$CMD" ] || die "usage: review_worktree.sh open|close --pr <N> --domain <d> [--sha <40hex>]"
case "$CMD" in open|close) ;; *) die "unknown command: $CMD";; esac
PR=""; DOMAIN=""; SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)     PR="$2"; shift 2;;
    --domain) DOMAIN="$2"; shift 2;;
    --sha)    SHA="$2"; shift 2;;
    *) die "unknown arg: $1";;
  esac
done
case "$PR" in ''|*[!0-9]*) die "--pr must be a positive integer";; esac
case "$DOMAIN" in ''|*[!a-z0-9_]*) die "--domain must be a lowercase panel domain name";; esac
REPO_HASH=$(printf '%s' "$TOP" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-8)
DIR="/tmp/pr-${REPO_HASH}-${DOMAIN}-${PR}"
case "$CMD" in
  close)
    if [ -d "$DIR" ]; then
      git worktree remove --force "$DIR" 2>/dev/null \
        || rm -rf "$DIR"   # last resort: stale manual copy
      git worktree prune 2>/dev/null || true
      echo "review worktree closed: $DIR"
    else
      echo "review worktree already absent: $DIR"
    fi
    ;;
  open)
    if [ -z "$SHA" ]; then
      GH_BIN="$("$CANON_DIR/bin/gh_id.sh" review)"; export GH_BIN
      SHA="$("$GH_BIN" pr view "$PR" --json headRefOid -q .headRefOid 2>/dev/null)" \
        || die "cannot resolve PR head sha for #$PR"
    fi
    [[ "$SHA" =~ ^[0-9a-fA-F]{40}$ ]] || die "sha must be 40 hex, got: ${SHA:-<none>}"
    # The head may live only on the remote (cross-clone push, fork):
    # fetch it before asking for the worktree.
    if ! git cat-file -e "$SHA^{commit}" 2>/dev/null; then
      [ -n "$REMOTE" ] || die "commit $SHA not local and no remote configured"
      git fetch "$REMOTE" "pull/$PR/head" >/dev/null 2>&1 \
        || git fetch "$REMOTE" "$SHA" >/dev/null 2>&1 \
        || die "cannot fetch $SHA for PR #$PR"
      git cat-file -e "$SHA^{commit}" 2>/dev/null \
        || die "commit $SHA still absent after fetch"
    fi
    if [ -d "$DIR" ]; then
      git worktree remove --force "$DIR" 2>/dev/null || rm -rf "$DIR"
      git worktree prune 2>/dev/null || true
    fi
    git worktree add --detach "$DIR" "$SHA" >/dev/null 2>&1 \
      || die "cannot create detached worktree at $SHA"
    echo "review worktree open: $DIR @ $SHA"
    ;;
esac
