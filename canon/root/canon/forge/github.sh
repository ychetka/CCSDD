#!/usr/bin/env bash
# forge/github.sh - GitHub adapter for panel_verdict.sh.
# Named per-SHA signals = commit statuses (context ccsdd/<domain>);
# findings = PR issue comments. Env: API_BIN (allowlisted gh basename).
set -uo pipefail
API_BIN="${API_BIN:-gh}"

usage() {
  echo "usage: github.sh signal_set --sha <s> --context <c> --state <success|failure|pending> --description <d> [--url <u>]" >&2
  echo "       github.sh signal_get --sha <s>" >&2
  echo "       github.sh finding_post --pr <n> --body-file <f>" >&2
  exit 2
}
[ $# -ge 1 ] || usage
OP=$1; shift

if [ "$OP" = "signal_set" ]; then
  SHA=""; CTX=""; ST=""; DSC=""; URL=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) SHA=$2;; --context) CTX=$2;; --state) ST=$2;;
      --description) DSC=$2;; --url) URL=$2;; *) usage;;
    esac; shift 2
  done
  case "$ST" in success|failure|pending) ;; *) echo "bad state" >&2; exit 2;; esac
  ARGS=(-f "state=$ST" -f "context=$CTX" -f "description=${DSC:0:140}")
  [ -n "$URL" ] && ARGS+=(-f "target_url=$URL")
  "$API_BIN" api -X POST "repos/{owner}/{repo}/statuses/$SHA" "${ARGS[@]}" >/dev/null || exit 1
  exit 0
fi

if [ "$OP" = "signal_get" ]; then
  SHA=""
  while [ $# -gt 0 ]; do
    case "$1" in --sha) SHA=$2;; *) usage;; esac; shift 2
  done
  OUT=$("$API_BIN" api "repos/{owner}/{repo}/commits/$SHA/status" 2>/dev/null) || exit 1
  OUT="$OUT" python3 - <<'PY'
import json, os, sys
d = json.loads(os.environ["OUT"])
latest = {}
for s in (d.get("statuses") or []):
    ctx = s.get("context") or ""
    if not ctx.startswith("ccsdd/"):
        continue
    if ctx not in latest or (s.get("updated_at") or "") > (latest[ctx].get("updated_at") or ""):
        latest[ctx] = {"domain": ctx[6:], "state": s.get("state"),
                       "creator": (s.get("creator") or {}).get("login"),
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
  "$API_BIN" api -X POST "repos/{owner}/{repo}/issues/$PR/comments" \
    -F "body=@$BF" --jq '.html_url' 2>/dev/null | python3 -c 'import json,sys
u = sys.stdin.read().strip()
print(json.dumps({"url": u}))'
  exit 0
fi

usage
