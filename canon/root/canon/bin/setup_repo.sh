#!/usr/bin/env bash
# setup_repo.sh - canonical GitHub repository setup, run once by the
# human during deployment (or via the repository agent).
#
#   setup_repo.sh [--repo owner/name] [--base main] [--dry-run]
#
# What it does, in order:
#   1. resolves the repository (arg or git remote origin);
#   2. checks gh auth (GH_TOKEN env or `gh auth status`) - the token
#      is requested interactively by gh itself, never stored here;
#   3. applies canonical branch protection on the base branch:
#      PR required, stale-review dismissal, no force pushes,
#      required linear history OFF (merge commits are the RoM flow);
#   4. deploys .github/workflows/release.yml (the serialized
#      release-main concurrency group) - via a bootstrap branch+PR
#      when base is already protected, direct push otherwise;
#   5. prints the canonical project.json review/merge block to
#      hand to the deployer.
#
# Idempotent: re-running converges to the same settings.
set -euo pipefail

REPO=""; BASE="main"; DRY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=$2; shift 2;;
    --base) BASE=$2; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "usage: setup_repo.sh [--repo o/n] [--base main] [--dry-run]" >&2; exit 2;;
  esac
done

if [ -z "$REPO" ]; then
  REPO=$(git remote get-url origin 2>/dev/null \
    | sed -n 's#.*github.com[:/]\([^/]*\)/\([^/.]*\)\(\.git\)\?#\1/\2#p')
fi
[ -n "$REPO" ] || { echo "setup_repo: cannot resolve repo - pass --repo owner/name" >&2; exit 1; }
echo "setup_repo: repository $REPO, base branch $BASE"

if ! gh auth status >/dev/null 2>&1 && [ -z "${GH_TOKEN:-}" ]; then
  echo "setup_repo: no GitHub credentials - run 'gh auth login' or export GH_TOKEN" >&2
  exit 1
fi

# --- 1. branch protection -------------------------------------------------
# required_status_checks: PRESERVE whatever is already required -
# sending null would silently drop the branch's existing CI gates.
EXISTING_CHECKS=$(gh api "repos/$REPO/branches/$BASE/protection" \
    --jq '.required_status_checks' 2>/dev/null || echo 'null')
PROT=$(EXISTING="$EXISTING_CHECKS" python3 - <<'PY'
import json, os
try:
    checks = json.loads(os.environ.get("EXISTING") or "null")
except Exception:
    checks = None
prot = {
  "required_status_checks": checks if isinstance(checks, dict) else None,
  "enforce_admins": False,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": True,
    "require_code_owner_reviews": False,
    "required_approving_review_count": 1
  },
  "restrictions": None,
  "required_linear_history": False,
  "allow_force_pushes": False,
  "allow_deletions": False,
  "required_conversation_resolution": False
}
print(json.dumps(prot))
PY
)

echo "setup_repo: applying branch protection on $BASE"
echo "$PROT"
if [ -z "$DRY" ]; then
  gh api -X PUT "repos/$REPO/branches/$BASE/protection" \
    --input - <<<"$PROT" >/dev/null \
    || { echo "setup_repo: protection API failed (token lacks admin?)" >&2; exit 1; }
  # Read-back verification: a 2xx PUT can still leave the branch
  # differently protected than requested (API silently drops
  # unknown fields, org rulesets may override). Fail loudly rather
  # than report a phantom protection.
  APPLIED=$(gh api "repos/$REPO/branches/$BASE/protection" 2>/dev/null || true)
  echo "$APPLIED" | python3 -c 'import json,sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit("setup_repo: protection read-back failed")
r = d.get("required_pull_request_reviews") or {}
if not r.get("dismiss_stale_reviews") \
        or (r.get("required_approving_review_count") or 0) < 1 \
        or d.get("allow_force_pushes", {}).get("enabled") \
        or d.get("allow_deletions", {}).get("enabled"):
    sys.exit("setup_repo: protection read-back mismatch - "
             "applied settings do not match the canonical payload")' \
    && echo "setup_repo: protection applied and verified" \
    || exit 1
fi

# --- 2. canonical release workflow ---------------------------------------
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
WF=$(cat "$CANON_DIR/templates/release_workflow.yml")
HAVE_WF=$(gh api "repos/$REPO/contents/.github/workflows/release.yml" \
            --jq .sha 2>/dev/null || true)
if [ -n "$HAVE_WF" ]; then
  echo "setup_repo: release.yml already deployed (sha ${HAVE_WF:0:8}) - update via normal PR flow"
else
  echo "setup_repo: deploying .github/workflows/release.yml"
  if [ -z "$DRY" ]; then
    # Protected base forbids a direct push - bootstrap via a branch.
    BASE_SHA=$(gh api "repos/$REPO/git/refs/heads/$BASE" --jq .object.sha) \
      || { echo "setup_repo: cannot read base ref" >&2; exit 1; }
    gh api -X POST "repos/$REPO/git/refs" \
      -f ref="refs/heads/canon/bootstrap-release" -f sha="$BASE_SHA" \
      >/dev/null 2>&1 || true   # exists already - fine
    # macOS base64 has no -w flag - tr-fold is the portable form.
    B64=$(printf '%s' "$WF" | base64 | tr -d '\n')
    gh api -X PUT "repos/$REPO/contents/.github/workflows/release.yml" \
      -f message="canon: serialized release workflow" \
      -f content="$B64" -f branch="canon/bootstrap-release" >/dev/null \
      || { echo "setup_repo: workflow deploy failed" >&2; exit 1; }
    gh pr create --repo "$REPO" --head canon/bootstrap-release --base "$BASE" \
      --title "canon: serialized release workflow" \
      --body "Deploys the canonical release-main concurrency group." 2>/dev/null \
      && echo "setup_repo: bootstrap PR opened - merge it to activate RoM serialization" \
      || echo "setup_repo: branch pushed (PR may already exist)"
  fi
fi

# --- 3. canonical project.json block --------------------------------------
cat <<EOF
setup_repo: canonical project.json block for this repository:
  "review": {
    "reviewer_logins": ["<reviewer-bot-login>"],
    "gh_bin": "gh-reviewer",
    "reviewer_profiles": {
      "<reviewer-login>": {"gh_bin": "gh-reviewer", "model_family": "<family>"}
    }
  },
  "merge": {"gh_bin": "gh"}
  NOTE: review.gh_bin MUST differ from merge.gh_bin - separate
  accounts/wrappers, or check_setup fails the deploy (author ==
  reviewer enables self-approve and review-signal forgery).
  Reviewer token rights on GitHub: Pull requests: Read & Write,
  Commit statuses: Read & Write, Issues: Read & Write.
setup_repo: done.
EOF
