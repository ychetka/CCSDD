#!/usr/bin/env bash
# partner_call.sh - the ONLY permitted path to external LLM partners
# (gateway.md: all external calls go through the gateway; a direct
# mcp_call_tool / stdio runner from an instance is a PROXY bypass).
#
#   partner_call.sh --partner <id> --tool <name>
#     (--args '<json>' | --args-file <path>)
#     [--audit-key <key>] [--class consult|audit]
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
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
JOURNAL="$CANON_DIR/partner_journal"
COUNTERS="$CANON_DIR/gateway_counters.json"
POLICY="$CANON_DIR/config/policy.json"
mkdir -p "$JOURNAL"

PARTNER=""; TOOL=""; ARGS_JSON=""; ARGS_FILE=""; AUDIT_KEY=""; REQ_CLASS=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "usage: partner_call.sh --partner <id> --tool <t> (--args '<json>' | --args-file <path>) [--audit-key <k>] [--class consult|audit]" >&2; exit 2; }
  case "$1" in
    --partner) PARTNER=$2;; --tool) TOOL=$2;;
    --args) ARGS_JSON=$2;; --args-file) ARGS_FILE=$2;;
    --audit-key) AUDIT_KEY=$2;; --class) REQ_CLASS=$2;;
    *) echo "partner_call: unknown flag $1" >&2; exit 2;;
  esac; shift 2
done
if [ -n "$ARGS_FILE" ]; then
  [ -z "$ARGS_JSON" ] || { echo "partner_call: --args and --args-file are exclusive" >&2; exit 2; }
  [ -f "$ARGS_FILE" ] || { echo "partner_call: args file missing: $ARGS_FILE" >&2; exit 2; }
fi
[ -n "$PARTNER" ] && [ -n "$TOOL" ] && [ -n "$ARGS_JSON$ARGS_FILE" ] || {
  echo "partner_call: --partner, --tool and (--args|--args-file) are required" >&2; exit 2; }

JOURNAL="$JOURNAL" COUNTERS="$COUNTERS" POLICY="$POLICY" \
  PARTNER="$PARTNER" TOOL="$TOOL" \
  ARGS_JSON="$ARGS_JSON" ARGS_FILE="$ARGS_FILE" \
  AUDIT_KEY="$AUDIT_KEY" REQ_CLASS="$REQ_CLASS" \
  python3 - <<'PY'
import datetime, fcntl, hashlib, json, os, re, signal, sys

journal_dir = os.environ["JOURNAL"]
counters_path = os.environ["COUNTERS"]
partner, tool = os.environ["PARTNER"], os.environ["TOOL"]
args_file = os.environ.get("ARGS_FILE")
args_raw = open(args_file, encoding="utf-8").read() \
    if args_file else os.environ["ARGS_JSON"]
req_class = os.environ["REQ_CLASS"]

try:
    call_args = json.loads(args_raw)
except json.JSONDecodeError as e:
    print(f"partner_call: --args is not valid JSON: {e}", file=sys.stderr)
    sys.exit(2)
if not isinstance(call_args, dict):
    print("partner_call: --args must be a JSON object", file=sys.stderr)
    sys.exit(2)

# --- sanitize: no secrets leave the boundary ---------------------
# refuse credential-shaped ASSIGNMENTS and known key formats; bare
# words like "token" appear all over spec text and are not secrets
SECRET_RE = re.compile(
    r"(BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|"
    r"ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|"
    r"sk-[A-Za-z0-9_-]{20,}|"
    r"(?:api[_-]?key|secret|password|passwd|bearer)"
    r"[\"'\s:=>-]{1,10}[A-Za-z0-9_/+\-.]{20,})",
    re.IGNORECASE)
def scan(obj):
    if isinstance(obj, str):
        return bool(SECRET_RE.search(obj))
    if isinstance(obj, dict):
        return any(SECRET_RE.search(str(k)) or scan(v) for k, v in obj.items())
    if isinstance(obj, list):
        return any(scan(v) for v in obj)
    return False
if scan(call_args):
    print("partner_call: REFUSED - args contain secret-looking material "
          "(gateway.md: secrets never cross the boundary)", file=sys.stderr)
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
AUDIT_PARTNERS = {"architect-partner", "code-reviewer"}
call_class = "audit" if partner in AUDIT_PARTNERS else "consult"
if req_class == "audit":
    call_class = "audit"          # initiator may only raise
elif req_class and req_class != "consult":
    print(f"partner_call: bad --class '{req_class}'", file=sys.stderr)
    sys.exit(2)

# --- counters + limits -------------------------------------------
# Limits come from the manifest-hashed canon policy
# (canon/config/policy.json), not from caller-controlled env: a
# caller may only ever TIGHTEN a limit via env, never raise it.
try:
    _gw = (json.load(open(os.environ["POLICY"], encoding="utf-8"))
           .get("gateway") or {})
except Exception:
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
# flock: concurrent calls must not lose counter increments.
lock_f = open(counters_path + ".lock", "a")
fcntl.flock(lock_f, fcntl.LOCK_EX)
if os.path.exists(counters_path):
    try:
        counters = json.load(open(counters_path, encoding="utf-8"))
        if not isinstance(counters, dict):
            raise ValueError("not an object")
    except Exception as e:
        # Fail CLOSED: a corrupted quota file must not silently reset
        # every counter - that is a quota bypass without touching
        # policy. Refuse until a human repairs the state.
        print(f"partner_call: REFUSED - gateway counters file is "
              f"unreadable ({e}) - fail closed, repair "
              f"{counters_path}", file=sys.stderr)
        sys.exit(4)
else:
    counters = {}
if call_class == "audit":
    # Global daily backstop bounds audit-key spraying: the per-key
    # budget only helps if keys cannot be minted freely.
    day_key = f"audit_day:{today}"
    if int(counters.get(day_key, 0)) >= audit_daily:
        print(f"partner_call: REFUSED - global daily audit limit "
              f"({audit_daily}) reached - "
              f"failure_class=quota_limited", file=sys.stderr)
        sys.exit(4)
    key = f"audit:{audit_key}"
    n = int(counters.get(key, 0))
    if n >= audit_max:
        print(f"partner_call: REFUSED - audit iteration limit "
              f"({audit_max}) reached for key '{audit_key}' - "
              f"escalation path, no auto-renewal (gateway.md §5)",
              file=sys.stderr)
        sys.exit(4)
    counters[key] = n + 1
    counters[day_key] = int(counters.get(day_key, 0)) + 1
else:
    key = f"consult:{today}:{partner}"
    n = int(counters.get(key, 0))
    if n >= consult_max:
        print(f"partner_call: REFUSED - consult daily limit "
              f"({consult_max}) reached for {partner} - "
              f"failure_class=quota_limited (quota.md)", file=sys.stderr)
        sys.exit(4)
    counters[key] = n + 1
tmp = counters_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(counters, f, indent=2)
os.replace(tmp, counters_path)
fcntl.flock(lock_f, fcntl.LOCK_UN)
lock_f.close()

# --- backend ------------------------------------------------------
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
except TimeoutError as e:
    print(f"partner_call: REFUSED - {e} - "
          f"failure_class=upstream_timeout", file=sys.stderr)
    sys.exit(4)
finally:
    signal.alarm(0)

# --- journal BEFORE returning ------------------------------------
entry = {
    "ts": ts.isoformat(),
    "partner": partner,
    "tool": tool,
    "class": call_class,
    "audit_key": audit_key if call_class == "audit" else None,
    "request_args": call_args,
    "response": result,
}
# Journal filename: the partner id is caller-supplied - strip anything
# but a safe basename charset so '--partner ../x' cannot write outside
# partner_journal/.
safe_partner = re.sub(r"[^A-Za-z0-9_-]", "_", partner)
name = f"{ts.strftime('%Y%m%dT%H%M%S')}-{safe_partner}-{os.getpid()}.json"
with open(os.path.join(journal_dir, name), "w", encoding="utf-8") as f:
    json.dump(entry, f, ensure_ascii=False, indent=2)

out = result if isinstance(result, str) else json.dumps(
    result, ensure_ascii=False, indent=2)
print(out)
print(f"[gateway] class={call_class} partner={partner} "
      f"journal={name}", file=sys.stderr)
PY
