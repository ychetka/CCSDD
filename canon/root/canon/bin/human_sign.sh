#!/usr/bin/env bash
# human_sign.sh - human approval envelopes via an SSH signature
# (ssh-agent resident key - the private key never enters the
# workspace filesystem, so a workspace agent under the same UID
# cannot mint a signoff).
#
#   human_sign.sh init  [--key <pubkey-file>]
#   human_sign.sh sign  --verdict <v> --artifact <sha256|sha1|file>
#                       --out <envelope.json|->
#   human_sign.sh verify --envelope <file|CCSDD-SIGNOFF-1|...>
#                        --artifact <sha256|sha1|file>
#                        [--verdict <v>]
#   human_sign.sh consume --envelope <...> --artifact <...>
#                        [--verdict <v>] [--nonce-store <file>]
#
# `--out -` prints a compact one-line signoff the human can paste
# into an agent chat (remote-laptop workflow); verify accepts the
# pasted line directly or inside a file. `verify` is side-effect
# free; `consume` runs the same checks and only then records the
# nonce into .used_nonces under flock - gates call verify early and
# consume AFTER the protected action succeeded, so a merge blocked
# downstream does not burn the envelope.
#
# Model: `ssh-keygen -Y sign -n ccsdd-signoff` signs the canonical
# message `ccsdd-signoff v1|<verdict>|<artifact_sha>|<utc>|<nonce>`
# through the agent; `ssh-keygen -Y verify` checks it against an
# allowed_signers file that lives OUTSIDE the workspace at
# ~/.config/ccsdd/allowed_signers (env CCSDD_ALLOWED_SIGNERS).
#
# Envelope safety properties: the signature cryptographically binds
# verdict + artifact hash + timestamp + nonce; verify() enforces
# artifact/verdict equality and a 7-day freshness window; consume()
# additionally records the nonce into a store (default
# canon/human_signoffs/.used_nonces) under flock so a captured
# envelope cannot be replayed onto a later merge.
# init REFUSES to overwrite an existing allowed_signers: key
# rotation is a deliberate out-of-band act (delete the file by hand
# first). A workspace agent under the same UID could otherwise swap
# in its own pubkey and mint signoffs.
set -euo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
CONF_DIR="${CCSDD_CONF_DIR:-$HOME/.config/ccsdd}"
SIGNERS="${CCSDD_ALLOWED_SIGNERS:-$CONF_DIR/allowed_signers}"
NS="ccsdd-signoff"
WINDOW=$((7 * 86400))   # envelope freshness: 7 days

MODE=""; VERDICT=""; ARTIFACT=""; ENVELOPE=""; KEYFILE=""; NONCE_STORE=""
while [ $# -gt 0 ]; do
  case "$1" in
    init|sign|verify|consume) MODE=$1; shift;;
    --verdict)  VERDICT=$2;  shift 2;;
    --artifact) ARTIFACT=$2; shift 2;;
    --key)      KEYFILE=$2;  shift 2;;
    --envelope|--out) ENVELOPE=$2; shift 2;;
    --nonce-store) NONCE_STORE=$2; shift 2;;
    *) echo "usage: human_sign.sh init|sign|verify ..." >&2; exit 2;;
  esac
done

die() { echo "human_sign: $1" >&2; exit 2; }

artifact_sha() {  # file path | 40-hex sha1 | 64-hex sha256 -> hex digest
  local a="$1"
  # Hex format is checked BEFORE the file test: a file whose name
  # collides with a 40/64-hex digest must not shadow the digest.
  if [[ "$a" =~ ^[0-9a-fA-F]{40}$ ]] || [[ "$a" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf '%s' "${a,,}"
  elif [ -f "$a" ]; then
    python3 -I -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$a"
  else
    die "--artifact must be a file, sha256 or git sha, got: ${a:0:40}"
  fi
}

case "$MODE" in
init)
  [ -n "$KEYFILE" ] || {
    if ssh-add -L >/dev/null 2>&1; then
      PUBKEY=$(ssh-add -L | head -1)
      [ -n "$PUBKEY" ] || die "ssh-agent identity list is empty"
      KEYFILE=$(mktemp -t ccsdd-pubkey.XXXXXX)
      trap 'rm -f "$KEYFILE"' EXIT
      printf '%s\n' "$PUBKEY" > "$KEYFILE"
      # Show exactly WHICH identity is being registered: the agent may
      # hold several keys and head -1 picks only the first. Type +
      # fingerprint + comment are unambiguous; a truncated blob is not.
      echo "human_sign: using first ssh-agent identity:"
      echo "  type/comment: $(awk '{print $1, $NF}' "$KEYFILE")"
      ssh-keygen -lf "$KEYFILE" 2>/dev/null | sed 's/^/  fingerprint: /' \
        || echo "  fingerprint: (ssh-keygen could not parse the key)"
    else
      die "no --key given and ssh-agent has no identities (ssh-add first)"
    fi
  }
  [ -f "$KEYFILE" ] || die "pubkey file not found: $KEYFILE"
  # No silent overwrite: any workspace actor can exec canon/bin, so
  # an unconditional init would let an agent swap the trusted pubkey
  # and self-mint signoffs. Rotation = delete the file first, then
  # init - a deliberate act performed by the human, not the agent.
  [ -f "$SIGNERS" ] && die "allowed_signers already exists at $SIGNERS - remove it manually to rotate (init never overwrites)"
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  # noclobber closes the check-then-create window: a file appearing
  # between the test and the write is a race, not an overwrite.
  ( set -C; printf 'human %s\n' "$(cat "$KEYFILE")" > "$SIGNERS" ) \
    || die "allowed_signers appeared during init - refusing to overwrite"
  chmod 600 "$SIGNERS"
  echo "human_sign: allowed_signers written: $SIGNERS"
  echo "human_sign: keep the private key in ssh-agent only - it must"
  echo "            NOT live inside any project workspace."
  ;;

sign)
  [ -n "$VERDICT" ] && [ -n "$ARTIFACT" ] && [ -n "$ENVELOPE" ] \
    || die "usage: human_sign.sh sign --verdict <v> --artifact <sha|file> --out <env.json>"
  [ -f "$SIGNERS" ] || die "no allowed_signers at $SIGNERS - run 'human_sign.sh init'"
  SHA=$(artifact_sha "$ARTIFACT")
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  NONCE=$(python3 -I -c 'import secrets;print(secrets.token_hex(16))')
  MSG="ccsdd-signoff v1|${VERDICT}|${SHA}|${TS}|${NONCE}"
  TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT INT TERM
  printf '%s' "$MSG" > "$TMPD/msg"
  # allowed_signers permits options before the key type
  # (namespaces=..., cert-authority, ...): $2/$3 are not reliably the
  # key fields - take the first field matching an OpenSSH key type and
  # the blob after it.
  PUBKEY=$(awk '$1=="human"{for(i=2;i<NF;i++) if($i~/^(ssh-|ecdsa-|sk-)/||$i~/cert-v01@openssh\.com$/){print $i" "$(i+1);exit}}' "$SIGNERS")
  [ -n "$PUBKEY" ] || die "no 'human' principal in $SIGNERS"
  printf '%s\n' "$PUBKEY" > "$TMPD/key.pub"
  ssh-keygen -Y sign -f "$TMPD/key.pub" -n "$NS" "$TMPD/msg" 2>/dev/null \
    || die "signing failed - is the key loaded in ssh-agent? (ssh-add -l)"
  MSG="$MSG" SHA="$SHA" VERDICT="$VERDICT" TS="$TS" NONCE="$NONCE" \
  SIG="$TMPD/msg.sig" ENVELOPE="$ENVELOPE" python3 -I - <<'PY'
import base64, json, os
sig = base64.b64encode(open(os.environ["SIG"], "rb").read()).decode()
e = {"type": "human_signoff", "format": "ssh-sig-v1",
     "signer": "human", "verdict": os.environ["VERDICT"],
     "artifact_hash": os.environ["SHA"],
     "artifact_alg": "sha256" if len(os.environ["SHA"]) == 64 else "sha1",
     "ts": os.environ["TS"], "nonce": os.environ["NONCE"],
     "message": os.environ["MSG"], "signature_b64": sig}
out = os.environ["ENVELOPE"]
if out == "-":
    # Chat-paste transport: a single self-authenticating line the
    # human can copy from a laptop terminal into an agent chat.
    # The channel is untrusted by design - verify() re-derives the
    # signed message from the fields, so nothing here can be
    # altered, replayed or rebound to a different artifact.
    print("CCSDD-SIGNOFF-1|%s|%s|%s|%s|%s" % (
        e["verdict"], e["artifact_hash"], e["ts"], e["nonce"], sig))
else:
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(e, fh, indent=2); fh.write("\n")
    print(f"human_sign: envelope written: {out} (artifact {os.environ['SHA'][:16]}..)")
PY
  ;;

verify|consume)
  [ -n "$ARTIFACT" ] && [ -n "$ENVELOPE" ] \
    || die "usage: human_sign.sh verify|consume --envelope <f> --artifact <sha|file> [--verdict <v>]"
  [ -f "$SIGNERS" ] || die "no allowed_signers at $SIGNERS - human_sign.sh init was never run"
  SHA=$(artifact_sha "$ARTIFACT")
  CONSUME="0"; [ "$MODE" = "consume" ] && CONSUME="1"
  E=$(ENVELOPE="$ENVELOPE" SHA="$SHA" VERDICT="$VERDICT" WINDOW="$WINDOW" \
      CONSUME="$CONSUME" \
      NONCE_STORE="${NONCE_STORE:-${CCSDD_NONCE_STORE:-$CANON_DIR/human_signoffs/.used_nonces}}" \
      SIGNERS_ENV="$SIGNERS" NS_ENV="$NS" \
      python3 -I - <<'PY'
import base64, json, os, sys, tempfile, subprocess, time, calendar, shutil, fcntl
env, sha, want_v = (os.environ.get(k) or "" for k in
                    ("ENVELOPE", "SHA", "VERDICT"))
# --envelope accepts: a file path (JSON envelope or a file holding
# a compact line), a literal CCSDD-SIGNOFF-1|... line, or literal
# JSON text. The compact line expands into the same envelope
# fields, so every check below is identical for both transports.
raw = open(env, encoding="utf-8").read().strip() \
      if os.path.isfile(env) else env
if raw.startswith("CCSDD-SIGNOFF-1|"):
    parts = raw.split("|")
    if len(parts) != 6:
        sys.exit("human_sign: malformed compact signoff line")
    _, v, art, ts_c, nonce, sig = parts
    e = {"format": "ssh-sig-v1", "signer": "human", "verdict": v,
         "artifact_hash": art.lower(),
         "artifact_alg": "sha256" if len(art) == 64 else "sha1",
         "ts": ts_c, "nonce": nonce, "signature_b64": sig,
         "message": "ccsdd-signoff v1|%s|%s|%s|%s" %
                    (v, art.lower(), ts_c, nonce)}
else:
    try:
        e = json.loads(raw)
    except Exception as ex:
        sys.exit(f"human_sign: cannot parse envelope {env}: {ex}")
if e.get("format") != "ssh-sig-v1":
    sys.exit("human_sign: unsupported envelope format "
             f"{e.get('format')!r} (legacy TOTP envelopes are not "
             "accepted - re-sign with human_sign.sh sign)")
for k in ("verdict","artifact_hash","ts","nonce","message","signature_b64"):
    if k not in e:
        sys.exit(f"human_sign: envelope missing field '{k}'")
if e["artifact_hash"].lower() != sha:
    sys.exit(f"human_sign: envelope artifact mismatch "
             f"({e['artifact_hash'][:16]}.. != {sha[:16]}..)")
if want_v and e["verdict"] != want_v:
    sys.exit(f"human_sign: envelope verdict '{e['verdict']}' != required '{want_v}'")
expect = "ccsdd-signoff v1|%s|%s|%s|%s" % (
    e["verdict"], e["artifact_hash"].lower(), e["ts"], e["nonce"])
if e["message"] != expect:
    sys.exit("human_sign: signed message does not match envelope fields")
# Freshness window: an old envelope approves nothing. timegm, NOT
# mktime - mktime reads the struct as LOCAL time, so in UTC-x
# zones a fresh UTC stamp computed a negative age and was rejected.
try:
    ts = time.strptime(e["ts"], "%Y-%m-%dT%H:%M:%SZ")
    age = time.time() - calendar.timegm(ts)
except Exception:
    sys.exit("human_sign: unparseable ts in envelope")
# Tolerate clock skew: a signer host whose clock runs a few
# minutes fast must not produce a spuriously-rejected envelope.
if not (-300 <= age <= float(os.environ["WINDOW"])):
    sys.exit(f"human_sign: envelope stale ({int(age//86400)}d old, window 7d)")
# Anti-replay: a nonce may certify exactly one acceptance. The
# consumed-check happens on EVERY verify (a burned nonce is dead
# input), but the WRITE is consume-only: gates verify early and
# consume after the protected action, so a merge blocked later in
# the pipeline does not strand the human's envelope.
store = os.environ["NONCE_STORE"]
consume = os.environ.get("CONSUME") == "1"
# Store format: '<nonce>|<artifact_hash>' per line (legacy bare
# '<nonce>' lines still replay-block). Binding the artifact makes
# consume idempotent: the same envelope re-presented for the SAME
# artifact after a post-consume pipeline failure is a retry, not a
# replay; the same nonce on a DIFFERENT artifact is a replay.
used = {}
if os.path.isfile(store):
    # shared flock on the read path: a concurrent consume's check+
    # append must not race a verify that reads a half-written file.
    with open(store, "r") as fh:
        fcntl.flock(fh, fcntl.LOCK_SH)
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            n, _, art = ln.partition("|")
            used[n] = art or None
if e["nonce"] in used:
    if used[e["nonce"]] == sha:
        ALREADY = True
    else:
        sys.exit("human_sign: envelope nonce already consumed (replay)")
else:
    ALREADY = False
sig_raw = base64.b64decode(e["signature_b64"])
tmp = tempfile.mkdtemp(prefix="ccsdd-verify.")
try:
    sig_f = os.path.join(tmp, "msg.sig")
    open(sig_f, "wb").write(sig_raw)
    # -Y verify reads the SIGNED DATA FROM STDIN - a positional file
    # argument is not the message and fails verification outright.
    r = subprocess.run(["ssh-keygen", "-Y", "verify", "-f",
                        os.environ["SIGNERS_ENV"], "-I", "human",
                        "-n", os.environ["NS_ENV"], "-s", sig_f],
                       input=e["message"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("human_sign: signature does not verify: " +
                 (r.stderr or r.stdout).strip()[:200])
finally:
    shutil.rmtree(tmp, ignore_errors=True)
if consume:
    if ALREADY:
        # Idempotent re-consume: a merge that consumed the nonce and
        # then failed downstream (release step) can be retried
        # without forcing the human to re-sign the same artifact.
        print(f"human_sign: envelope OK - '{e['verdict']}' for artifact {sha[:16]}.. (nonce already consumed for this artifact)")
        raise SystemExit(0)
    os.makedirs(os.path.dirname(store), exist_ok=True)
    # flock around check+append: concurrent merges must not both
    # pass the replay check before either records the nonce.
    with open(store, "a+") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.seek(0)
        again = False
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            n, _, art = ln.partition("|")
            if n == e["nonce"]:
                if art == sha:
                    again = True
                    break
                sys.exit("human_sign: envelope nonce already consumed (replay)")
        if not again:
            fh.write(e["nonce"] + "|" + sha + "\n")
print(f"human_sign: envelope OK - '{e['verdict']}' for artifact {sha[:16]}..")
PY
  ) || exit 2
  echo "$E"
  ;;

*) die "usage: human_sign.sh init|sign|verify ...";;
esac
