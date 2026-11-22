#!/usr/bin/env bash
# gh_id.sh <merge|review> - resolve the credential binary for a
# repository-agent identity class from project.json.
#   merge  -> merge.gh_bin (author/merge mutations: PR open, merge,
#             release, issues, reads). NEVER falls back to
#             review.gh_bin - a merge running under the reviewer
#             identity makes the PR author == reviewer, which both
#             breaks the forge's self-approve rule and lets the merge
#             identity fabricate review signals.
#   review -> review.gh_bin (review/panel publication: repo_pr_review,
#             panel_verdict).
# Prints a bare binary basename or exits 2 on a non-basename config.
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
CLS="${1:-}"
case "$CLS" in merge|review) ;; *) echo "usage: gh_id.sh merge|review" >&2; exit 2;; esac
OUT=$(CANON_DIR="$CANON_DIR" CLS="$CLS" python3 -c 'import json,os,re
cls = os.environ["CLS"]
try:
    pj = json.load(open(os.path.join(os.environ["CANON_DIR"], "project.json")))
    gb = ((pj.get(cls) or {}).get("gh_bin")) or "gh"
    print(gb if isinstance(gb, str) and re.fullmatch(r"[A-Za-z0-9_-]+", gb) else "")
except Exception:
    print("gh")')
[ -n "$OUT" ] || { echo "gh_id: ${CLS}.gh_bin in project.json is not a bare binary basename" >&2; exit 2; }
echo "$OUT"
