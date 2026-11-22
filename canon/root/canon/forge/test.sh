#!/usr/bin/env bash
# forge/test.sh - offline fixture adapter for panel_verdict.sh.
# Signals are stored in canon/panel_signals_fixture.json; comments are
# appended to canon/panel_comments_fixture.jsonl. No network, no creds.
# Selected via project.json "forge": "test" - for canon pipeline tests
# and local dry runs only.
set -uo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
SIG="$CANON_DIR/panel_signals_fixture.json"
CMT="$CANON_DIR/panel_comments_fixture.jsonl"

usage() {
  echo "usage: test.sh signal_set --sha <s> --context <c> --state <st> --description <d> [--url <u>]" >&2
  echo "       test.sh signal_get --sha <s>" >&2
  echo "       test.sh finding_post --pr <n> --body-file <f>" >&2
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
  # Read-modify-write under flock: parallel panel_verdict runs (one
  # per domain) would otherwise last-writer-win the fixture file.
  (
    flock -x 9
    SIG="$SIG" SHA="$SHA" CTX="$CTX" ST="$ST" DSC="$DSC" URL="$URL" python3 - <<'PY'
import datetime, json, os
path = os.environ["SIG"]
try:
    data = json.load(open(path))
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}
rec = {"state": os.environ["ST"], "creator": "panel-test",
       "updated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "description": os.environ["DSC"], "url": os.environ["URL"] or None}
data.setdefault(os.environ["SHA"], {})[os.environ["CTX"]] = rec
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2); f.flush(); os.fsync(f.fileno())
os.replace(tmp, path)
PY
  ) 9>"$SIG.lock"
  exit 0
fi

if [ "$OP" = "signal_get" ]; then
  SHA=""
  while [ $# -gt 0 ]; do
    case "$1" in --sha) SHA=$2;; *) usage;; esac; shift 2
  done
  SIG="$SIG" SHA="$SHA" python3 - <<'PY'
import json, os
try:
    data = json.load(open(os.environ["SIG"]))
except Exception:
    data = {}
sigs = []
for ctx, r in (data.get(os.environ["SHA"]) or {}).items():
    if ctx.startswith("ccsdd/"):
        sigs.append({"domain": ctx[6:], "state": r.get("state"),
                     "creator": r.get("creator"),
                     "updated_at": r.get("updated_at"),
                     "description": r.get("description")})
print(json.dumps({"status":"ok","signals":sigs}))
PY
  exit 0
fi

if [ "$OP" = "finding_post" ]; then
  PR=""; BF=""
  while [ $# -gt 0 ]; do
    case "$1" in --pr) PR=$2;; --body-file) BF=$2;; *) usage;; esac; shift 2
  done
  [ -n "$PR" ] && [ -f "$BF" ] || usage
  (
    flock -x 9
    CMT="$CMT" PR="$PR" python3 - "$BF" <<'PY'
import json, os, sys
rec = {"pr": int(os.environ["PR"]), "body": open(sys.argv[1], encoding="utf-8").read()}
with open(os.environ["CMT"], "a", encoding="utf-8") as f:
    f.write(json.dumps(rec) + "\n")
print(json.dumps({"url": f"fixture://comment/{os.environ['PR']}"}))
PY
  ) 9>"$CMT.lock"
  exit 0
fi

usage
