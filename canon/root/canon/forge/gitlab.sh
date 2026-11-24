#!/usr/bin/env bash
# forge/gitlab.sh - GitLab adapter for panel_verdict.sh.
# Named per-SHA signals = commit statuses (name ccsdd/<domain>);
# findings = MR notes. Env: API_BIN (allowlisted `glab` basename).
# Final approval on GitLab maps to POST merge_requests/:iid/approve
# (no REQUEST_CHANGES primitive - a failed ccsdd/* signal + missing
# approve is the negative verdict).
#
# HONEST BOUNDARY: on GitLab, `creator` attribution of a commit
# status is the token user and every developer+ project member may
# post statuses under any name - creator checks are weaker than on
# GitHub. Deploys that need hard creator enforcement should rely on
# MR approval state (final_approve) rather than status authorship.
#
# SCOPE: this adapter covers the PANEL surface only (panel_verdict.sh
# signals/findings/final_approve). The repo_*.sh lifecycle scripts
# (repo_merge/repo_release/repo_pr_*/repo_status_check) speak the
# `gh` CLI dialect directly (gh pr view --json, repos/{o}/{r} REST
# paths) - on GitLab they require a gh-compatible wrapper, they do
# not accept `glab`.
set -uo pipefail
API_BIN="${API_BIN:-glab}"

usage() {
  echo "usage: gitlab.sh signal_set --sha <s> --context <c> --state <success|failure|pending> --description <d> [--url <u>]" >&2
  echo "       gitlab.sh signal_get --sha <s>" >&2
  echo "       gitlab.sh finding_post --pr <n> --body-file <f>" >&2
  exit 2
}
[ $# -ge 1 ] || usage
OP=$1; shift

# GitLab state names differ: failure -> failed.
gl_state() { case "$1" in failure) echo failed;; *) echo "$1";; esac; }

if [ "$OP" = "signal_set" ]; then
  SHA=""; CTX=""; ST=""; DSC=""; URL=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) SHA=$2;; --context) CTX=$2;; --state) ST=$2;;
      --description) DSC=$2;; --url) URL=$2;; *) usage;;
    esac; shift 2
  done
  case "$ST" in success|failure|pending) ;; *) echo "bad state" >&2; exit 2;; esac
  ARGS=(--form "state=$(gl_state "$ST")" --form "name=$CTX" --form "description=${DSC:0:255}")
  [ -n "$URL" ] && ARGS+=(--form "target_url=$URL")
  "$API_BIN" api -X POST "projects/:id/statuses/$SHA" "${ARGS[@]}" >/dev/null || exit 1
  exit 0
fi

if [ "$OP" = "signal_get" ]; then
  SHA=""
  while [ $# -gt 0 ]; do
    case "$1" in --sha) SHA=$2;; *) usage;; esac; shift 2
  done
  # Read endpoint differs from the write endpoint: statuses are
  # listed under repository/commits. --paginate + multi-document
  # decode, same as the GitHub adapter.
  OUT=$("$API_BIN" api --paginate \
        "projects/:id/repository/commits/$SHA/statuses" 2>/dev/null) || exit 1
  OUT="$OUT" python3 - <<'PY'
import json, os
raw = os.environ["OUT"]
dec = json.JSONDecoder()
rows, idx = [], 0
while idx < len(raw):
    while idx < len(raw) and raw[idx].isspace():
        idx += 1
    if idx >= len(raw):
        break
    doc, idx = dec.raw_decode(raw, idx)
    rows.extend(doc if isinstance(doc, list) else [])
latest = {}
for s in rows:
    ctx = s.get("name") or ""
    if not ctx.startswith("ccsdd/"):
        continue
    st = {"failed": "failure"}.get(s.get("status"), s.get("status"))
    if ctx not in latest or (s.get("updated_at") or "") > (latest[ctx].get("updated_at") or ""):
        latest[ctx] = {"domain": ctx[6:], "state": st,
                       "creator": (s.get("author") or {}).get("username"),
                       "updated_at": s.get("updated_at"),
                       "description": s.get("description")}
print(json.dumps({"status":"ok","signals":list(latest.values())}))
PY
  exit 0
fi

if [ "$OP" = "finding_post" ]; then
  PR=""; BF=""
  while [ $# -gt 0 ]; do
    case "$1" in --pr) PR=$2;; --body-file) BF=$2;; *) usage;; esac; shift 2
  done
  [ -n "$PR" ] && [ -f "$BF" ] || usage
  # The note body travels as a request-body FILE (--input), not argv
  # interpolation of $(cat) - a large/multi-line body survives intact
  # and never hits the argument-size ceiling.
  BODY_JSON=$(mktemp)
  BF="$BF" BODY_JSON="$BODY_JSON" python3 -c 'import json,os
json.dump({"body": open(os.environ["BF"], encoding="utf-8").read()},
          open(os.environ["BODY_JSON"], "w", encoding="utf-8"))'
  "$API_BIN" api -X POST "projects/:id/merge_requests/$PR/notes" \
    --input "$BODY_JSON" --jq '.id' 2>/dev/null | python3 -c 'import json,sys
i = sys.stdin.read().strip()
print(json.dumps({"url": ("note:" + i) if i else ""}))'
  rm -f "$BODY_JSON"
  exit 0
fi

usage
