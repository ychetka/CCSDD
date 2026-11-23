#!/usr/bin/env bash
# gh_id.sh <merge|review> [login] - resolve the credential binary
# for a repository-agent identity class from project.json.
#   merge           -> merge.gh_bin (author/merge mutations: PR open,
#                      merge, release, issues, reads). NEVER falls
#                      back to review.* - a merge running under the
#                      reviewer identity makes PR author == reviewer,
#                      which both breaks the forge's self-approve
#                      rule and lets the merge identity fabricate
#                      review signals.
#   review          -> review.api_bin|gh_bin (review/panel
#                      publication: repo_pr_review, panel_verdict).
#   review <login>  -> reviewer_profiles.<login>.api_bin|gh_bin
#                      first, falling back to the class default -
#                      a risk:high second-family reviewer profile
#                      can carry its own forge credential instead
#                      of borrowing the default aggregator's.
# Prints a bare binary basename or exits 2 on a non-basename config.
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
CLS="${1:-}"
LOGIN="${2:-}"
case "$CLS" in merge|review) ;; *) echo "usage: gh_id.sh merge|review [login]" >&2; exit 2;; esac
# A login only refines the review class - a merge identity is always
# the single merge credential, never a per-login profile.
[ "$CLS" = "review" ] || LOGIN=""
OUT=$(CANON_DIR="$CANON_DIR" CLS="$CLS" LOGIN="$LOGIN" python3 -c 'import json,os,re
cls = os.environ["CLS"]
login = os.environ.get("LOGIN", "").strip().lower()
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
except Exception:
    pj = {}
sec = pj.get(cls) if isinstance(pj.get(cls), dict) else {}
gb = ""
if login:
    rp = sec.get("reviewer_profiles") or {}
    for name, prof in rp.items():
        if str(name).strip().lower() == login and isinstance(prof, dict):
            gb = prof.get("api_bin") or prof.get("gh_bin") or ""
            break
# api_bin wins over gh_bin: a non-GitHub forge names its CLI in
# api_bin while gh_bin may be absent or stale. The forge field sets
# the fallback binary so a gitlab project never resolves to "gh".
if not gb:
    gb = sec.get("api_bin") or sec.get("gh_bin")
if not gb:
    forge = pj.get("forge") or "github"
    gb = {"gitlab": "glab"}.get(forge, "gh")
print(gb if isinstance(gb, str) and re.fullmatch(r"[A-Za-z0-9_-]+", gb) else "")')
[ -n "$OUT" ] || { echo "gh_id: ${CLS}${LOGIN:+.$LOGIN} binary in project.json is not a bare basename" >&2; exit 2; }
echo "$OUT"
