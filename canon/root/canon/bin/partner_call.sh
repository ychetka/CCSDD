#!/usr/bin/env bash
# partner_call.sh - the ONLY permitted path to external LLM partners
# (gateway.md: all external calls go through the gateway; a direct
# mcp_call_tool / stdio runner from an instance is a PROXY bypass).
#
#   partner_call.sh --partner <id> --tool <name>
#     (--args '<json>' | --args-file <path>)
#     [--audit-key <key>] [--class consult|audit] [--round <n>]
#     [--item <id>]
#
# --args-file reads the same JSON object from disk - large audit
# packages exceed the kernel's single-argument limit.
#
# Deterministic behaviour before the answer returns:
#   1. classifies the call from the addressee (architect-partner and
#      code-reviewer are ALWAYS Audit; other partners default
#      Consult). --class may only raise Consult->Audit.
#   2. enforces limits from canon/config/policy.json (gateway.*):
#      Audit - audit_max_per_key calls per --audit-key (terminal
#      refusal); Consult - consult_daily_max_per_partner per partner
#      per day (refusal exits quota_limited). GATEWAY_* env vars may
#      only tighten limits, never raise them.
#   3. journals verbatim request+response to
#      canon/partner_journal/<ts>-<partner>-<pid>.json BEFORE the
#      answer is printed - the raw verdict exists in the journal even
#      if the caller instance crashes.
#   4. sanitizes: refuses args containing obvious secret material
#      (token/password/secret keys or .env blobs).
#
# Backend: PartnerMCPServer.call_tool - same code path the MCP
# server uses. Partner impl dir resolves from
# ~/.config/canon/mcp_config.json (args[0] -> dirname) or
# PARTNER_IMPL_DIR env.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1  # canon bin imports must not litter __pycache__
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
GATEWAY_DB="$CANON_DIR/gateway.db"
POLICY="$CANON_DIR/config/policy.json"

PARTNER=""; TOOL=""; ARGS_JSON=""; ARGS_FILE=""; AUDIT_KEY=""; REQ_CLASS=""; ROUND=""; REQ_ITEM=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "usage: partner_call.sh --partner <id> --tool <t> (--args '<json>' | --args-file <path>) [--audit-key <k>] [--class consult|audit] [--round <n>] [--item <id>]" >&2; exit 2; }
  case "$1" in
    --partner) PARTNER=$2;; --tool) TOOL=$2;;
    --args) ARGS_JSON=$2;; --args-file) ARGS_FILE=$2;;
    --audit-key) AUDIT_KEY=$2;; --class) REQ_CLASS=$2;;
    --round) ROUND=$2;; --item) REQ_ITEM=$2;;
    *) echo "partner_call: unknown flag $1" >&2; exit 2;;
  esac; shift 2
done
case "$ROUND" in ""|*[!0-9]*) [ -z "$ROUND" ] || { echo "partner_call: --round must be a positive integer" >&2; exit 2; } ;; esac
if [ -n "$ARGS_FILE" ]; then
  [ -z "$ARGS_JSON" ] || { echo "partner_call: --args and --args-file are exclusive" >&2; exit 2; }
  [ -f "$ARGS_FILE" ] || { echo "partner_call: args file missing: $ARGS_FILE" >&2; exit 2; }
fi
[ -n "$PARTNER" ] && [ -n "$TOOL" ] && [ -n "$ARGS_JSON$ARGS_FILE" ] || {
  echo "partner_call: --partner, --tool and (--args|--args-file) are required" >&2; exit 2; }

GATEWAY_DB="$GATEWAY_DB" POLICY="$POLICY" \
  CANON_DIR="$CANON_DIR" \
  PARTNERS_CFG="$CANON_DIR/config/partners.json" \
  PARTNER="$PARTNER" TOOL="$TOOL" \
  ARGS_JSON="$ARGS_JSON" ARGS_FILE="$ARGS_FILE" \
  AUDIT_KEY="$AUDIT_KEY" REQ_CLASS="$REQ_CLASS" ROUND="$ROUND" \
  REQ_ITEM="$REQ_ITEM" \
  python3 - <<'PY'
import datetime, hashlib, json, os, re, signal, subprocess, sys

sys.path.insert(0, os.path.join(os.environ["CANON_DIR"], "bin"))
import gw_store

db_path = os.environ["GATEWAY_DB"]
partner, tool = os.environ["PARTNER"], os.environ["TOOL"]
args_file = os.environ.get("ARGS_FILE")
args_raw = open(args_file, encoding="utf-8").read() \
    if args_file else os.environ["ARGS_JSON"]
req_class = os.environ["REQ_CLASS"]
call_round = os.environ.get("ROUND") or None
if call_round is not None:
    call_round = int(call_round)

try:
    call_args = json.loads(args_raw)
except json.JSONDecodeError as e:
    print(f"partner_call: --args is not valid JSON: {e}", file=sys.stderr)
    sys.exit(2)
if not isinstance(call_args, dict):
    print("partner_call: --args must be a JSON object", file=sys.stderr)
    sys.exit(2)

# --- sanitize: no secrets leave the boundary ---------------------
# the canonical scanner is canon/bin/secret_scan.py - one pattern
# set shared with security_check so the two boundaries cannot
# drift apart. Refuse credential-shaped ASSIGNMENTS and known key
# formats; bare words like "token" appear all over spec text and
# are not secrets.
blob = json.dumps(call_args)
scanner = os.path.join(os.environ["CANON_DIR"], "bin", "secret_scan.py")
r = subprocess.run([sys.executable, scanner, "--quiet"],
                   input=blob, capture_output=True, text=True)
if r.returncode == 1:
    print("partner_call: REFUSED - args contain secret-looking material "
          "(gateway.md: secrets never cross the boundary)", file=sys.stderr)
    sys.exit(3)
if r.returncode != 0:
    # scanner crash (decode error etc.) - fail closed, never pass silently
    print(f"partner_call: REFUSED - secret scanner error rc={r.returncode}",
          file=sys.stderr)
    sys.exit(3)

# Audit key: an explicitly passed --audit-key is used as-is; without
# one the key is derived deterministically from the audited payload -
# re-auditing the SAME artifact shares one budget (the anti
# verdict-shopping property), and there is no way to launder a fresh
# budget by picking a new key.
audit_key = os.environ["AUDIT_KEY"] or \
    "auto:" + hashlib.sha256(
        json.dumps(call_args, sort_keys=True).encode()).hexdigest()[:16]

# --- deterministic classification --------------------------------
# Audit set comes from the canonical role registry (partners.json):
# every role whose declared profile is `Audit` is always an Audit
# call - never a hardcoded name list here. If the registry is
# unreadable the safe degradation keeps the `ex-*` (external
# arbitration) naming convention classified as `audit`.
try:
    _preg = json.load(open(os.environ["PARTNERS_CFG"], encoding="utf-8"))
    AUDIT_PARTNERS = {rid for rid, r in (_preg.get("roles") or {}).items()
                      if isinstance(r, dict) and r.get("profile") == "Audit"}
except Exception as e:
    if os.path.isfile(os.environ["PARTNERS_CFG"]):
        # The registry EXISTS but is corrupt: a silent fallback would
        # misclassify audit calls as consults - fail closed.
        print(f"partner_call: REFUSED - partners.json unreadable: {e}",
              file=sys.stderr)
        sys.exit(3)
    AUDIT_PARTNERS = {p for p in (partner,) if p.startswith("ex-")}
call_class = "audit" if partner in AUDIT_PARTNERS else "consult"
if req_class == "audit":
    call_class = "audit"          # initiator may only raise
elif req_class and req_class != "consult":
    print(f"partner_call: bad --class '{req_class}'", file=sys.stderr)
    sys.exit(2)

# Open-dispute escalation: a consult call on an item that already has
# an unresolved failure/escalated record in cycle_log.jsonl is a
# dispute, not casual advice - raise it to audit class so it spends
# the bounded per-key budget instead of the loose daily consult one.
req_item = os.environ.get("REQ_ITEM") or ""
if req_item and call_class == "consult":
    clog = os.path.join(os.environ["CANON_DIR"], "cycle_log.jsonl")
    open_fails = {}
    if os.path.isfile(clog):
        for ln in open(clog, encoding="utf-8", errors="replace"):
            try:
                rec = json.loads(ln)
            except Exception:
                continue
            if not isinstance(rec, dict):
                continue
            k2 = (rec.get("actor"), rec.get("item"))
            if rec.get("status") == "open" \
                    and rec.get("verdict") in ("failure", "escalated"):
                open_fails[k2] = rec
            act = rec.get("action") or ""
            if (act.startswith("resolve_") or act == "close") \
                    and rec.get("token_authenticated") is True \
                    and rec.get("verdict") not in ("failure", "escalated"):
                open_fails.pop(k2, None)
    if any(k[1] == req_item for k in open_fails):
        call_class = "audit"

# --- partner impl resolution (BEFORE any quota spend) -------------
# A call that cannot reach a backend must not burn budget - resolve
# impl_dir first so every counter spent below maps to a real call.
impl_dir = os.environ.get("PARTNER_IMPL_DIR")
conf_path = os.path.expanduser("~/.config/canon/mcp_config.json")
if not impl_dir and os.path.isfile(conf_path):
    conf = json.load(open(conf_path, encoding="utf-8"))
    srv = (conf.get("mcpServers") or conf).get(partner) or {}
    argv = srv.get("args") or []
    if argv:
        impl_dir = os.path.dirname(argv[0])
if not impl_dir or not os.path.isdir(impl_dir):
    print(f"partner_call: cannot resolve partner impl dir for "
          f"'{partner}' (set PARTNER_IMPL_DIR)", file=sys.stderr)
    sys.exit(2)
sys.path.insert(0, impl_dir)
os.environ["PARTNER_ID"] = partner
os.environ.setdefault("PARTNER_CONFIG",
                      os.path.join(impl_dir, "config.json"))

from core.server import PartnerMCPServer  # noqa: E402

# --- counters + limits -------------------------------------------
# Limits come from the manifest-hashed canon policy
# (canon/config/policy.json), not from caller-controlled env: a
# caller may only ever TIGHTEN a limit via env, never raise it.
try:
    _gw = (json.load(open(os.environ["POLICY"], encoding="utf-8"))
           .get("gateway") or {})
except Exception as e:
    if os.path.isfile(os.environ["POLICY"]):
        # Corrupt policy would silently reset all quota limits to
        # hardcoded defaults - fail closed instead.
        print(f"partner_call: REFUSED - policy.json unreadable: {e}",
              file=sys.stderr)
        sys.exit(3)
    _gw = {}
audit_max = int(os.environ.get("GATEWAY_AUDIT_MAX",
                               _gw.get("audit_max_per_key", 20)))
audit_max = min(audit_max, int(_gw.get("audit_max_per_key", 20)))
consult_max = int(os.environ.get("GATEWAY_CONSULT_DAILY_MAX",
                                 _gw.get("consult_daily_max_per_partner", 50)))
consult_max = min(consult_max,
                  int(_gw.get("consult_daily_max_per_partner", 50)))
audit_daily = int(_gw.get("audit_daily_max_total", 100))
today = datetime.date.today().isoformat()
# SQLite/WAL store: quota check+increment is ONE transaction -
# concurrent calls can never lose or double-spend an increment,
# and the transaction commits BEFORE the backend call below (a
# transaction is never held open across the network).
con = gw_store.connect(db_path)
# Orphan reaper: a caller killed between quota-spend and refund
# (SIGKILL/OOM leaves no finally-block) strands its increments as an
# inflight row keyed by pid. Rows whose pid is dead are reaped and
# refunded inside ONE transaction (gw_store.inflight_reap_dead) so
# two concurrent callers can never refund the same orphan twice.
try:
    gw_store.inflight_reap_dead(con)
except Exception:
    pass   # an older DB without the table must not block the call
spent_keys = []
if call_class == "audit":
    # Global daily backstop bounds audit-key spraying: the per-key
    # budget only helps if keys cannot be minted freely.
    day_key = f"audit_day:{today}"
    key = f"audit:{audit_key}"
    vals, tripped = gw_store.counters_check_incr(
        con, [(key, audit_max), (day_key, audit_daily)])
    if tripped == day_key:
        print(f"partner_call: REFUSED - global daily audit limit "
              f"({audit_daily}) reached - "
              f"failure_class=quota_limited", file=sys.stderr)
        sys.exit(4)
    if tripped is not None:
        print(f"partner_call: REFUSED - audit iteration limit "
              f"({audit_max}) reached for key '{audit_key}' - "
              f"escalation path, no auto-renewal (gateway.md §5)",
              file=sys.stderr)
        sys.exit(4)
    spent_keys = [key, day_key]
else:
    key = f"consult:{today}:{partner}"
    vals, tripped = gw_store.counters_check_incr(
        con, [(key, consult_max)])
    if tripped is not None:
        print(f"partner_call: REFUSED - consult daily limit "
              f"({consult_max}) reached for {partner} - "
              f"failure_class=quota_limited (quota.md)", file=sys.stderr)
        sys.exit(4)
    spent_keys = [key]

# Inflight ledger: record the spend under THIS pid before the
# network hop so a SIGKILL orphan is reapable by the next run.
import uuid
CALL_ID = uuid.uuid4().hex
try:
    gw_store.inflight_add(con, CALL_ID, os.getpid(), spent_keys)
except Exception:
    pass

def _refund():
    # A call that never reached a partner answer (timeout, backend
    # error) must not consume irreplaceable budget - return the
    # increments in one short transaction. A refund failure must
    # never mask the original error.
    try:
        gw_store.counters_refund(con, spent_keys)
    except Exception as re_:
        # A refund failure must never mask the original error, but it
        # must not be silent either - log it for postmortem.
        print(f"partner_call: WARN quota refund failed: {re_}",
              file=sys.stderr)
    finally:
        try:
            gw_store.inflight_clear(con, CALL_ID)
        except Exception:
            pass

ts = datetime.datetime.now(datetime.timezone.utc)
# Every external call carries an explicit deadline (RULES.md) - a
# hung partner must not block the turn until kill.
call_timeout = int(_gw.get("call_timeout_seconds", 300))
def _timeout(_sig, _frm):
    raise TimeoutError(f"partner call exceeded {call_timeout}s")
signal.signal(signal.SIGALRM, _timeout)
signal.alarm(call_timeout)
try:
    result = PartnerMCPServer(partner_id=partner).call_tool(tool, call_args)
    try:
        gw_store.inflight_clear(con, CALL_ID)
    except Exception:
        pass
except TimeoutError as e:
    _refund()
    print(f"partner_call: REFUSED - {e} - "
          f"failure_class=upstream_timeout", file=sys.stderr)
    sys.exit(4)
except Exception as e:
    _refund()
    print(f"partner_call: backend call failed: {e} - "
          f"failure_class=upstream_error", file=sys.stderr)
    sys.exit(4)
finally:
    signal.alarm(0)

# --- journal BEFORE returning ------------------------------------
# Append-only journal row in the WAL store - the raw verdict exists
# in the journal even when the caller dies right after the answer.
entry = {
    "ts": ts.isoformat(),
    "partner": partner,
    "tool": tool,
    "class": call_class,
    "round": call_round,
    "audit_key": audit_key if call_class == "audit" else None,
    "request_args": call_args,
    "response": result,
}
gw_store.journal_append(con, entry)
jid = con.execute("SELECT last_insert_rowid()").fetchone()[0]

out = result if isinstance(result, str) else json.dumps(
    result, ensure_ascii=False, indent=2)
print(out)
print(f"[gateway] class={call_class} partner={partner} "
      f"journal_row={jid}", file=sys.stderr)
PY
