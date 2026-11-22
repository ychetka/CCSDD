#!/usr/bin/env bash
# forge/gitlab.sh - GitLab adapter for panel_verdict.sh.
# Named per-SHA signals = commit statuses (name ccsdd/<domain>);
# findings = MR notes. Env: API_BIN (allowlisted `glab` basename).
# Final approval on GitLab maps to POST merge_requests/:iid/approve
# (no REQUEST_CHANGES primitive - a failed ccsdd/* signal + missing
# approve is the negative verdict).
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
  OUT=$("$API_BIN" api "projects/:id/statuses/$SHA" 2>/dev/null) || exit 1
  OUT="$OUT" python3 - <<'PY'
import json, os
rows = json.loads(os.environ["OUT"])
latest = {}
for s in (rows if isinstance(rows, list) else []):
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
  "$API_BIN" api -X POST "projects/:id/merge_requests/$PR/notes" \
    --form "body=$(cat "$BF")" --jq '.id' 2>/dev/null | python3 -c 'import json,sys
i = sys.stdin.read().strip()
print(json.dumps({"url": ("note:" + i) if i else ""}))'
  exit 0
fi

usage
