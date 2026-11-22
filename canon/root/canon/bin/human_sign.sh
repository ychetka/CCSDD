#!/usr/bin/env bash
# human_sign.sh - human approval envelopes via a TOTP second factor
# (Google Authenticator compatible).
#
#   human_sign.sh init                 # provision: secret -> ~/.config/ccsdd/
#   human_sign.sh sign  --verdict <v> --artifact <sha256|file>
#                       --out <envelope.json>
#   human_sign.sh verify --envelope <file> --artifact <sha256>
#                       [--verdict <v>]
#
# A bare TOTP code is an approval FACTOR, not an asymmetric
# signature: it proves the holder of the secret saw this exact
# artifact digest at this timestamp and typed the live code - it
# does not give transferable non-repudiation. The envelope binds
# {verdict, artifact_sha, code, ts}; verification recomputes the
# TOTP for the recorded timestep and requires the artifact digest
# to match, so a recorded code cannot be replayed onto a different
# artifact and a different verdict.
#
# The secret lives OUTSIDE the workspace at
# ~/.config/ccsdd/human_totp_secret (mode 600) - workspace agents
# neither mint nor verify codes. The human runs `init` once, scans
# the otpauth:// URI into any TOTP app, then `sign` prompts for the
# current 6-digit code interactively.
set -euo pipefail

SECRET_FILE="${CCSDD_TOTP_SECRET:-$HOME/.config/ccsdd/human_totp_secret}"
MODE=""; VERDICT=""; ARTIFACT=""; ENVELOPE=""
while [ $# -gt 0 ]; do
  case "$1" in
    init|sign|verify) MODE=$1; shift;;
    --verdict)  VERDICT=$2;  shift 2;;
    --artifact) ARTIFACT=$2; shift 2;;
    --code)     CODE=$2;     shift 2;;
    --envelope|--out) ENVELOPE=$2; shift 2;;
    *) echo "usage: human_sign.sh init|sign|verify ..." >&2; exit 2;;
  esac
done

MODE="$MODE" SECRET_FILE="$SECRET_FILE" VERDICT="$VERDICT" \
ARTIFACT="$ARTIFACT" ENVELOPE="$ENVELOPE" CODE="${CODE:-}" python3 - <<'PY'
import base64, getpass, hashlib, hmac, json, os, struct, sys, time

mode, sf = os.environ["MODE"], os.environ["SECRET_FILE"]
verdict, art, env, code_arg = (os.environ.get(x) or "" for x in
                     ("VERDICT", "ARTIFACT", "ENVELOPE", "CODE"))

def load_secret():
    try:
        raw = open(sf, encoding="ascii").read().strip()
        return base64.b32decode(raw)
    except Exception:
        sys.exit(f"human_sign: cannot read TOTP secret at {sf} - "
                 f"run 'human_sign.sh init' first")

def totp(secret, counter):
    ctr = struct.pack(">Q", int(counter))
    d = hmac.new(secret, ctr, hashlib.sha1).digest()
    o = d[-1] & 0x0F
    return "%06d" % (struct.unpack(">I", d[o:o+4])[0] & 0x7FFFFFFF)

def artifact_sha(a):
    if os.path.isfile(a):
        return hashlib.sha256(open(a, "rb").read()).hexdigest()
    if len(a) in (40, 64) and all(c in "0123456789abcdef" for c in a.lower()):
        return a.lower()          # sha256 or git sha1 - opaque binding
    sys.exit(f"human_sign: --artifact must be a file, sha256 or git sha, got: {a[:40]}")

if mode == "init":
    os.makedirs(os.path.dirname(sf), mode=0o700, exist_ok=True)
    secret = os.urandom(20)
    b32 = base64.b32encode(secret).decode()
    fd = os.open(sf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(b32 + "\n")
    user = getpass.getuser()
    print(f"human_sign: TOTP secret written to {sf} (mode 600)")
    print(f"add to your authenticator app:")
    print(f"  otpauth://totp/CCSDD:{user}?secret={b32}&issuer=CCSDD")
    sys.exit(0)

if mode == "sign":
    if not verdict or not art or not env:
        sys.exit("usage: human_sign.sh sign --verdict <v> --artifact <sha|file> --out <envelope.json>")
    secret = load_secret()
    sha = artifact_sha(art)
    if code_arg:
        code = code_arg
    else:
        # the heredoc occupies stdin - the human types on the tty
        try:
            with open("/dev/tty") as tty:
                tty.write(f"approve '{verdict}' for artifact "
                          f"{sha[:16]}.. - enter the current "
                          f"6-digit TOTP code: ")
                tty.flush()
                code = tty.readline().strip()
        except OSError:
            sys.exit("human_sign: no tty and no --code given")
    now = time.time()
    step = int(now // 30)
    if code not in {totp(secret, s) for s in (step - 1, step, step + 1)}:
        sys.exit("human_sign: TOTP code rejected - envelope NOT written")
    os.makedirs(os.path.dirname(os.path.abspath(env)), exist_ok=True)
    envelope = {
        "type": "human_signoff",
        "signer": "human",
        "verdict": verdict,
        "artifact_hash": sha,
        "artifact_alg": "sha256" if len(sha) == 64 else "sha1",
        "code": code,
        "ts": step * 30,      # recorded timestep - verifies offline
    }
    with open(env, "w", encoding="utf-8") as fh:
        json.dump(envelope, fh, indent=2)
        fh.write("\n")
    print(f"human_sign: envelope written: {env} (artifact {sha[:16]}..)")
    sys.exit(0)

if mode == "verify":
    if not env or not art:
        sys.exit("usage: human_sign.sh verify --envelope <file> --artifact <sha> [--verdict <v>]")
    secret = load_secret()
    sha = artifact_sha(art)
    try:
        e = json.load(open(env, encoding="utf-8"))
    except Exception as ex:
        sys.exit(f"human_sign: cannot parse envelope {env}: {ex}")
    for k in ("verdict", "artifact_hash", "code", "ts"):
        if k not in e:
            sys.exit(f"human_sign: envelope missing field '{k}'")
    if e["artifact_hash"].lower() != sha:
        sys.exit(f"human_sign: envelope artifact mismatch "
                 f"({e['artifact_hash'][:16]}.. != {sha[:16]}..)")
    if verdict and e["verdict"] != verdict:
        sys.exit(f"human_sign: envelope verdict '{e['verdict']}' != required '{verdict}'")
    step = int(e["ts"]) // 30
    if e["code"] not in {totp(secret, s) for s in (step - 1, step, step + 1)}:
        sys.exit("human_sign: envelope TOTP code does not verify")
    if abs(time.time() - e["ts"]) > 86400 * 365 * 50:
        sys.exit("human_sign: envelope timestamp implausible")
    print(f"human_sign: envelope OK - '{e['verdict']}' for artifact {sha[:16]}..")
    sys.exit(0)

sys.exit("usage: human_sign.sh init|sign|verify ...")
PY
