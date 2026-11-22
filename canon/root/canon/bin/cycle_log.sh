#!/usr/bin/env bash
# cycle_log.sh - JSONL event log for the cycle (canon/cycle_log.jsonl)
#
#   cycle_log.sh register --actor <id> --role <role> [--project <p>]
#       Registers an actor in canon/actors.json and prints a fresh
#       capability token ONCE on stdout. Only sha256(token) is stored;
#       the token travels to the actor inside its spawn/context
#       package and authenticates `close`. Roles: orchestrator,
#       director, executor|code_writer, designer, judge, reviewer,
#       resolver, repository, git, reader, hygiene, partner.
#
#   cycle_log.sh append --item i_30 --actor git-agent \
#     --action commit --expected "..." --result "..." \
#     --status closed --verdict ok --failure-class ""
#
#   cycle_log.sh close --actor <caller-id> --token <tok> \
#     [--item i_30 | --all] [--for-actor <target>] \
#     [--verdict ok|escalated] [--note "..."] [--dry-run]
#
# `close` is APPEND-ONLY: it never rewrites history. For every
# matching still-open record it appends a `close` event carrying
# {item, actor=<record actor>, closed_by=<caller>,
# closer_role=<caller role>, verdict, note}. The original failure
# verdict stays auditable; verify_constraints derives "open" state
# by folding the event stream.
#
# Close authorization: a caller may close its own records; callers
# whose role is `orchestrator` or `director` may close another
# actor's records via --for-actor. The registry (canon/actors.json)
# holds sha256(token) only; if the registry or the caller entry is
# absent the close degrades to self-close only and is stamped
# closer_role="unregistered" - never a silent privilege grant.
set -euo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
LOG="$CANON_DIR/cycle_log.jsonl"
ACTORS="$CANON_DIR/actors.json"

usage() {
  echo "usage: cycle_log.sh register --actor <id> --role <role> [--project <p>] [--registrar-token <t> | --token <t>]" >&2
  echo "       cycle_log.sh unregister --actor <id> [--registrar-token <t> | --token <t>]" >&2
  echo "       cycle_log.sh append --item <id> --actor <id> --action <a> --expected <e> --result <r> --status open|closed --verdict ok|failure|escalated [--failure-class <fc>]" >&2
  echo "       cycle_log.sh close --actor <id> --token <t> [--item <id> | --all] [--for-actor <id>] [--verdict ok|escalated] [--note <t>] [--allow-empty] [--dry-run]" >&2
  exit 2
}
[ $# -ge 1 ] || usage
CMD=$1; shift

LOCK="$LOG.lock"
exec 9>"$LOCK"
flock 9 || { echo "cycle_log: cannot acquire lock" >&2; exit 1; }

if [ "$CMD" = "register" ]; then
  ACTOR=""; ROLE=""; PROJECT=""; REG_TOKEN=""; OWN_TOKEN=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      --actor) ACTOR=$2;; --role) ROLE=$2;; --project) PROJECT=$2;;
      --registrar-token) REG_TOKEN=$2;; --token) OWN_TOKEN=$2;;
      *) usage;;
    esac; shift 2
  done
  [ -n "$ACTOR" ] && [ -n "$ROLE" ] || { echo "register: --actor and --role required" >&2; exit 2; }
  case "$ROLE" in
    orchestrator|director|executor|code_writer|designer|judge|reviewer|resolver|repository|git|reader|hygiene|partner) ;;
    *) echo "register: bad role '$ROLE'" >&2; exit 2;;
  esac
  ACTORS="$ACTORS" ACTOR="$ACTOR" ROLE="$ROLE" PROJECT="$PROJECT" \
    REG_TOKEN="$REG_TOKEN" OWN_TOKEN="$OWN_TOKEN" python3 - <<'PY'
import datetime, hashlib, json, os, secrets, sys
path, actor, role, project, reg_tok, own_tok = (os.environ[k] for k in
    ("ACTORS","ACTOR","ROLE","PROJECT","REG_TOKEN","OWN_TOKEN"))
PRIVILEGED = {"orchestrator", "director"}
def h(t): return hashlib.sha256(t.encode()).hexdigest()
reg = {"actors": []}
if os.path.isfile(path):
    try:
        reg = json.load(open(path, encoding="utf-8"))
        if not isinstance(reg.get("actors"), list):
            reg = {"actors": []}
    except Exception:
        reg = {"actors": []}
existing = next((a for a in reg["actors"] if a.get("actor_id") == actor), None)
priv = [a for a in reg["actors"] if a.get("role") in PRIVILEGED]
registrar_ok = bool(reg_tok) and any(
    a.get("token_sha256") == h(reg_tok) for a in priv)
if existing:
    # re-registration = token rotation: the actor's own current
    # token or a privileged registrar must authorize it - a bare
    # call must never silently invalidate a live token.
    own_ok = bool(own_tok) and h(own_tok) == existing.get("token_sha256")
    if not (own_ok or registrar_ok):
        print("register: actor exists - rotation needs --token (own) "
              "or --registrar-token (orchestrator/director)", file=sys.stderr)
        sys.exit(3)
elif role in PRIVILEGED and priv and not registrar_ok:
    # new privileged actor needs a sponsor once any privileged
    # actor exists; zero-privileged registry = first-boot bootstrap
    print("register: role '%s' requires --registrar-token of an "
          "orchestrator/director actor" % role, file=sys.stderr)
    sys.exit(3)
reg["actors"] = [a for a in reg["actors"] if a.get("actor_id") != actor]
token = secrets.token_hex(24)
reg["actors"].append({
    "actor_id": actor,
    "role": role,
    "token_sha256": h(token),
    "registered_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "project": project or None})
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(json.dumps(reg, indent=2) + "\n")
    f.flush(); os.fsync(f.fileno())
os.replace(tmp, path)
print(json.dumps({"actor_id": actor, "role": role, "token": token,
                  "note": "token shown once; store it in the actor context package"}))
PY
  exit 0
fi

if [ "$CMD" = "unregister" ]; then
  ACTOR=""; REG_TOKEN=""; OWN_TOKEN=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      --actor) ACTOR=$2;;
      --registrar-token) REG_TOKEN=$2;; --token) OWN_TOKEN=$2;;
      *) usage;;
    esac; shift 2
  done
  [ -n "$ACTOR" ] || { echo "unregister: --actor required" >&2; exit 2; }
  ACTORS="$ACTORS" ACTOR="$ACTOR" REG_TOKEN="$REG_TOKEN" OWN_TOKEN="$OWN_TOKEN" python3 - <<'PY'
import hashlib, json, os, sys
path, actor, reg_tok, own_tok = (os.environ[k] for k in
    ("ACTORS","ACTOR","REG_TOKEN","OWN_TOKEN"))
PRIVILEGED = {"orchestrator", "director"}
def h(t): return hashlib.sha256(t.encode()).hexdigest()
if not os.path.isfile(path):
    print("unregister: no actors registry", file=sys.stderr); sys.exit(1)
reg = json.load(open(path, encoding="utf-8"))
entries = reg.get("actors") if isinstance(reg, dict) else reg
existing = next((a for a in (entries or []) if a.get("actor_id") == actor), None)
if not existing:
    print("unregister: actor not registered", file=sys.stderr); sys.exit(1)
own_ok = bool(own_tok) and h(own_tok) == existing.get("token_sha256")
registrar_ok = bool(reg_tok) and any(
    a.get("token_sha256") == h(reg_tok) and a.get("role") in PRIVILEGED
    for a in entries)
if not (own_ok or registrar_ok):
    print("unregister: needs --token (own) or --registrar-token "
          "(orchestrator/director)", file=sys.stderr)
    sys.exit(3)
reg["actors"] = [a for a in entries if a.get("actor_id") != actor]
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(json.dumps(reg, indent=2) + "\n")
    f.flush(); os.fsync(f.fileno())
os.replace(tmp, path)
print(json.dumps({"actor_id": actor, "status": "unregistered"}))
PY
  exit 0
fi

if [ "$CMD" = "append" ]; then
  ITEM=""; ACTOR=""; ACTION=""; EXPECTED=""; RESULT=""; STATUS=closed; VERDICT=ok; FC=""; TOKEN=""; BY=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      --item) ITEM=$2;; --actor) ACTOR=$2;; --action) ACTION=$2;;
      --expected) EXPECTED=$2;; --result) RESULT=$2;;
      --status) STATUS=$2;; --verdict) VERDICT=$2;;
      --failure-class) FC=$2;; --token) TOKEN=$2;; --by) BY=$2;;
      *) usage;;
    esac; shift 2
  done
  [ -n "$ITEM" ]   || { echo "append: --item required"; exit 2; }
  [ -n "$ACTOR" ]  || { echo "append: --actor required"; exit 2; }
  [ -n "$ACTION" ] || { echo "append: --action required"; exit 2; }
  case "$VERDICT" in ok|failure|escalated) ;; *) echo "bad verdict"; exit 2;; esac
  case "$STATUS" in open|closed) ;; *) echo "bad status"; exit 2;; esac
  if [ -n "$FC" ]; then
    # Canonical failure_class enum - single list shared by all gate
    # scripts (repo_merge/repo_release emit these verbatim; harness.md
    # documents the same set). Unknown values collapse to `unknown`.
    case "$FC" in \
      gate_blocked|merge_conflict|ci_failed|permission_denied|stale_head|\
      malformed_input|upstream_error|upstream_timeout|missing_changes_entry|\
      version_not_bumped|version_source_missing|version_drift|conflict|\
      contract_gap|contract_ambiguity|unverifiable|scope_conflict|\
      quota_limited|incomplete_read|not_found|manual_gate|\
      epic_incomplete|missing_issue_field|issue_mismatch|stale_input|plan_drift|\
      verify_escalated|verify_failed|release_failed|\
      baseline_unresolvable|env_setup_failed|unknown) ;; *) FC=unknown;; esac
  fi
  # failure_class is only meaningful on a failure/escalated verdict -
  # a closed-ok record must never carry one
  if [ "$VERDICT" = "failure" ] || [ "$VERDICT" = "escalated" ]; then
    [ -n "$FC" ] || { echo "append: verdict=$VERDICT requires --failure-class"; exit 2; }
  else
    FC=""
  fi
  # Clearing actions (close / resolve_*) clear open failure records,
  # so they carry the same token authentication as `close`: the
  # caller (--by, default --actor) must authenticate with its token
  # and may clear another actor's record only when its role is
  # orchestrator/director. Plain progress records stay unauthenticated.
  CLEARING=0; AUTH=""
  case "$ACTION" in close|resolve_*) CLEARING=1;; esac
  BY="${BY:-$ACTOR}"
  if [ "$CLEARING" = "1" ]; then
    [ -n "$TOKEN" ] || { echo "append: --action $ACTION requires --token"; exit 3; }
    AUTH=$(ACTORS="$ACTORS" BY="$BY" TOKEN="$TOKEN" ACTOR="$ACTOR" python3 - <<'PY'
import hashlib, json, os, sys
actors_path = os.environ["ACTORS"]
caller, token, target = (os.environ[k] for k in ("BY","TOKEN","ACTOR"))
def h(t): return hashlib.sha256(t.encode()).hexdigest()
PRIV = {"orchestrator", "director"}
role = "unregistered"
try:
    reg = json.load(open(actors_path, encoding="utf-8"))
    entries = reg.get("actors") if isinstance(reg, dict) else reg
except Exception:
    entries = []
me = next((a for a in (entries or []) if a.get("actor_id") == caller), None)
if not me or me.get("token_sha256") != h(token):
    print("deny", file=sys.stderr); sys.exit(3)
role = me.get("role") or "unregistered"
if caller != target and role not in PRIV:
    print("deny-priv", file=sys.stderr); sys.exit(3)
print(role)
PY
) || { echo "append: token auth failed for --by $BY" >&2; exit 3; }
  fi
  python3 - "$ITEM" "$ACTOR" "$ACTION" "$EXPECTED" "$RESULT" "$STATUS" "$VERDICT" "$FC" "$CLEARING" "$BY" "$AUTH" <<'PY' >> "$LOG"
import json, sys, datetime
item, actor, action, expected, result, status, verdict, fc, clearing, by, role = sys.argv[1:12]
rec = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "item": item, "actor": actor, "action": action,
    "expected": expected, "result": result,
    "status": status, "verdict": verdict,
    "failure_class": fc or None}
if clearing == "1":
    rec["closed_by"] = by
    rec["closer_role"] = role
    rec["token_authenticated"] = True
print(json.dumps(rec))
PY

elif [ "$CMD" = "close" ]; then
  ITEM=""; ACTOR=""; TOKEN=""; VERDICT=ok; NOTE=""; DRY=""; ALL=""; FOR=""; ALLOW_EMPTY=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY=1; shift; continue;;
      --all) ALL=1; shift; continue;;
      --allow-empty) ALLOW_EMPTY=1; shift; continue;;
    esac
    [ $# -ge 2 ] || usage
    case "$1" in
      --item) ITEM=$2;; --actor) ACTOR=$2;; --token) TOKEN=$2;;
      --for-actor) FOR=$2;; --verdict) VERDICT=$2;;
      --note) NOTE=$2;; *) usage;;
    esac; shift 2
  done
  [ -n "$ACTOR" ] || { echo "close: --actor required"; exit 2; }
  # explicit selection: --item or --all, never a bare wildcard close
  if [ -z "$ITEM" ] && [ -z "$ALL" ]; then
    echo "close: pass --item <id> or --all explicitly"; exit 2
  fi
  case "$VERDICT" in ok|failure|escalated) ;; *) echo "bad verdict"; exit 2;; esac
  [ -f "$LOG" ] || { echo "cycle_log: no log file - nothing to close" >&2; exit 1; }
  LOG="$LOG" ACTORS="$ACTORS" ITEM="$ITEM" ACTOR="$ACTOR" TOKEN="$TOKEN" \
    VERDICT="$VERDICT" NOTE="$NOTE" DRY="$DRY" ALL="$ALL" FOR="$FOR" \
    ALLOW_EMPTY="$ALLOW_EMPTY" python3 - <<'PY'
import datetime, hashlib, json, os, sys
log, actors_path = os.environ["LOG"], os.environ["ACTORS"]
want_item, caller, token = (os.environ[k] for k in ("ITEM","ACTOR","TOKEN"))
verdict, note = os.environ["VERDICT"], os.environ["NOTE"]
dry = os.environ["DRY"] == "1"
want_all = os.environ["ALL"] == "1"
for_actor = os.environ["FOR"]
allow_empty = os.environ["ALLOW_EMPTY"] == "1"

# authenticate the caller against the actor registry
role, authed = "unregistered", False
if os.path.isfile(actors_path):
    try:
        reg = json.load(open(actors_path, encoding="utf-8"))
        entries = reg.get("actors") if isinstance(reg, dict) else reg
        for a in entries or []:
            if a.get("actor_id") == caller:
                if hashlib.sha256(token.encode()).hexdigest() == a.get("token_sha256"):
                    role, authed = a.get("role", "unregistered"), True
                else:
                    print("cycle_log close: bad token for actor", file=sys.stderr)
                    sys.exit(3)
    except Exception as e:
        print(f"cycle_log close: actors.json unreadable: {e}", file=sys.stderr)
        sys.exit(3)

target = for_actor or caller
if target != caller and role not in ("orchestrator", "director"):
    print(f"cycle_log close: caller {caller} (role={role}) may not close "
          f"records of actor {target} - orchestrator/director only",
          file=sys.stderr)
    sys.exit(3)

if not authed:
    # An unauthenticated close would append an event that the fold
    # refuses to count - refuse it up front instead of writing a
    # silently-useless record.
    print(f"cycle_log close: caller {caller} is not authenticated "
          "(register the actor and pass --token)", file=sys.stderr)
    sys.exit(3)

now = datetime.datetime.now(datetime.timezone.utc).isoformat()
# SEQUENTIAL fold: walk the log in order; an open record enters the
# open set, a clearing event removes exactly its (actor,item) key. A
# prior close must never shadow a LATER reopened record for the same
# pair, and a clearing event must be token-authenticated and carry
# verdict=ok - a "failure"/"escalated" close marks the incident, it
# does not resolve it.
open_keys = set()
records = []
for line in open(log, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        continue
    if not isinstance(rec, dict):
        continue
    records.append(rec)
    act = rec.get("action") or ""
    if (act == "close" or act.startswith("resolve_")) \
            and rec.get("token_authenticated") is True \
            and rec.get("verdict") == "ok":
        open_keys.discard((rec.get("actor"), rec.get("item")))
        continue
    if rec.get("status") == "open" \
            and rec.get("verdict") in ("failure", "escalated"):
        open_keys.add((rec.get("actor"), rec.get("item")))

matched = []
for rec in records:
    if rec.get("status") != "open":
        continue
    if (rec.get("actor"), rec.get("item")) not in open_keys:
        continue
    if rec.get("actor") != target:
        continue
    if not want_all and rec.get("item") != want_item:
        continue
    matched.append(rec)

# Escalated records are incidents awaiting the developer: closing
# them is a privileged operation even for the owning actor - an
# executor must not self-resolve an escalation it was told to park.
if any(r.get("verdict") == "escalated" for r in matched) \
        and role not in ("orchestrator", "director", "resolver"):
    print(f"cycle_log close: escalated records require "
          f"orchestrator/director/resolver role (caller role={role})",
          file=sys.stderr)
    sys.exit(3)

if not matched:
    msg = f"cycle_log close: no open records match actor={target}"
    if not want_all:
        msg += f" item={want_item}"
    if allow_empty:
        print(msg + " (allowed-empty)")
        sys.exit(0)
    print(msg, file=sys.stderr)
    sys.exit(1)

events = []
for rec in matched:
    ev = {
        "ts": now,
        "item": rec.get("item"),
        "actor": rec.get("actor"),
        "action": "close",
        "expected": rec.get("expected"),
        "result": note or "closed",
        "status": "closed",
        "verdict": verdict,
        "failure_class": None,
        "closed_by": caller,
        "closer_role": role,
        "token_authenticated": authed,
    }
    events.append(ev)

if dry:
    for e in events:
        print(json.dumps(e))
    print(f"dry-run: {len(events)} close event(s) would append", file=sys.stderr)
    sys.exit(0)

with open(log, "a", encoding="utf-8") as f:
    for e in events:
        f.write(json.dumps(e) + "\n")
    f.flush(); os.fsync(f.fileno())
print(f"appended {len(events)} close event(s) by {caller} (role={role})"
      + (f" for actor={target}" if target != caller else ""))
PY
else
  usage
fi
