#!/usr/bin/env bash
# canon_pub.sh - canon publication gate (specs/canon_gate.md).
#
#   canon_pub.sh publish --candidate <canon_ws_dir> \
#     --envelope <envelope.json> --version <semver> \
#     [--canon-root <dir>] [--manifest <path>] [--history <path>]
#
# Fail-closed checks, in order:
#   1. candidate tree exists and is non-empty
#   2. human decision envelope validates: verdict=approve,
#      artifact_sha == sha256 of the candidate tree, sig verifies
#      against the human key ($CANON_HUMAN_KEY or
#      ~/.config/canon/human_key - never inside the workspace)
#   3. read-limit: every candidate file stays within the agent
#      read limits (--max-lines, default 2000)
#   4. hygiene: no secrets-shaped content in candidate files
#   5. publish: candidate -> canon root, MANIFEST.json sha map
#      recomputed, canon_version bumped, release history row
#      appended. Git commit + canon-v<version> tag are performed
#      afterwards by the git-agent (instances never run git).
#
# --orch-dir <dir> additionally folds a second tree (the
# orchestrator layer: protocols, PLAYBOOK, bin) into the manifest
# under "orchestrator_sha256" - the orchestrator protocol set is
# hash-pinned at publication like the canon itself.
set -euo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

[ "${1:-}" = "publish" ] || {
  echo "usage: canon_pub.sh publish --candidate <dir> --envelope <json> --version <semver> [--canon-root <dir>] [--manifest <path>] [--history <path>] [--orch-dir <dir>] [--max-lines N]" >&2
  exit 2
}
shift

CAND=""; ENV=""; VER=""; MAXL=2000; ORCH_DIR=""
# Default canon root = the parent of the deployed canon dir
# (canon/root/ in the package layout). The candidate tree mirrors
# that root (contains canon/ inside), so files deploy verbatim.
# The authoritative manifest/history live one level ABOVE canon_home
# (<pkg>/canon/MANIFEST.json) - start_project.sh reads that path.
CANON_ROOT="$(dirname "$CANON_DIR")"
MANIFEST="$(dirname "$(dirname "$CANON_DIR")")/MANIFEST.json"
HISTORY="$(dirname "$(dirname "$CANON_DIR")")/release_history.jsonl"
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "canon_pub: dangling flag $1" >&2; exit 2; }
  case "$1" in
    --candidate) CAND=$2;; --envelope) ENV=$2;; --version) VER=$2;;
    --canon-root) CANON_ROOT=$2;; --manifest) MANIFEST=$2;;
    --history) HISTORY=$2;; --max-lines) MAXL=$2;;
    --orch-dir) ORCH_DIR=$2;;
    *) echo "canon_pub: unknown flag $1" >&2; exit 2;;
  esac; shift 2
done
[ -n "$CAND" ] && [ -n "$ENV" ] && [ -n "$VER" ] || {
  echo "canon_pub: --candidate --envelope --version required" >&2; exit 2; }

CAND="$CAND" ENV="$ENV" VER="$VER" MAXL="$MAXL" \
CANON_ROOT="$CANON_ROOT" MANIFEST="$MANIFEST" HISTORY="$HISTORY" \
ORCH_DIR="$ORCH_DIR" \
python3 - <<'PY'
import datetime, hashlib, hmac, json, os, re, sys, pathlib

cand = pathlib.Path(os.environ["CAND"])
env_path = os.environ["ENV"]
ver = os.environ["VER"]
max_lines = int(os.environ["MAXL"])
canon_root = pathlib.Path(os.environ["CANON_ROOT"])
manifest_p = pathlib.Path(os.environ["MANIFEST"])
history_p = pathlib.Path(os.environ["HISTORY"])

def fail(msg, code=3):
    print(f"canon_pub: {msg}", file=sys.stderr)
    sys.exit(code)

if not cand.is_dir():
    fail(f"candidate dir missing: {cand}")
files = sorted(p for p in cand.rglob("*") if p.is_file())
if not files:
    fail("candidate tree is empty")

# Canonical layout: the candidate must mirror a canon root (a tree
# containing canon/RULES.md, canon/specs/, canon/bin/ inside).
for req in ("canon/RULES.md", "canon/specs/harness.md",
            "canon/bin/check_setup.sh"):
    if not (cand / req).is_file():
        fail(f"candidate does not match the canonical layout - "
             f"missing {req} (expected a canon-root mirror with "
             f"canon/ inside)")

# -- 0. version: semver + strictly monotone vs the last release ---
if not re.fullmatch(r"\d+\.\d+\.\d+", ver):
    fail(f"--version is not semver X.Y.Z: {ver!r}")
prev = {}
if manifest_p.is_file():
    try:
        prev = json.load(open(manifest_p, encoding="utf-8"))
    except Exception as e:
        fail(f"existing manifest unreadable: {e}")
old_ver = str(prev.get("canon_version") or "")
if old_ver:
    def _sv(v):
        return tuple(int(x) for x in v.split("."))
    if re.fullmatch(r"\d+\.\d+\.\d+", old_ver) and _sv(ver) <= _sv(old_ver):
        fail(f"version downgrade/same-version refused: "
             f"{ver} <= {old_ver}")

# -- candidate tree hash: sha256 over (relpath, sha256) pairs ----
tree_entries = []
for p in files:
    rel = p.relative_to(cand).as_posix()
    data = p.read_bytes()
    tree_entries.append((rel, hashlib.sha256(data).hexdigest()))
tree_sha = hashlib.sha256(
    "".join(f"{r}={s}" for r, s in tree_entries).encode()
).hexdigest()

# -- 2. decision envelope ----------------------------------------
try:
    env = json.load(open(env_path, encoding="utf-8"))
except Exception as e:
    fail(f"envelope unreadable: {e}")
if env.get("verdict") != "approve":
    fail(f"envelope verdict is not 'approve': {env.get('verdict')!r}")
if env.get("artifact_sha") != tree_sha:
    fail("envelope artifact_sha does not match candidate tree "
         f"(envelope={env.get('artifact_sha','?')[:12]}.. tree={tree_sha[:12]}..)",
         4)

key = os.environ.get("CANON_HUMAN_KEY")
if not key:
    kf = os.path.expanduser("~/.config/canon/human_key")
    if os.path.isfile(kf):
        key = open(kf).read().strip()
if not key:
    fail("human signing key unavailable "
         "(set CANON_HUMAN_KEY or ~/.config/canon/human_key - "
         "the same key that signs decision envelopes on the bus)", 5)
# The signed payload binds the TARGET version too - a valid envelope
# for this tree cannot be replayed under a different version string.
payload = (f"{env.get('verdict')}|{env.get('artifact_sha')}|"
           f"{env.get('signed_by','')}|{env.get('ts','')}|{ver}")
want = hmac.new(key.encode(), payload.encode(), hashlib.sha256).hexdigest()
got = str(env.get("sig") or "")
if not hmac.compare_digest(want, got):
    fail("envelope signature invalid (HMAC mismatch)", 5)
# Envelope freshness: the window is 7 days - the envelope is bound
# to (tree_sha, version) cryptographically, so age alone cannot
# approve a different artifact; the window only limits replay of
# stale contexts (a Friday decision must survive the weekend).
try:
    ts = datetime.datetime.fromisoformat(
        str(env.get("ts", "")).replace("Z", "+00:00"))
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=datetime.timezone.utc)
    age = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()
except Exception:
    fail("envelope ts is not a parseable ISO timestamp", 5)
if not (0 <= age <= 604800):
    fail(f"envelope ts outside the 7d freshness window (age {int(age)}s)", 5)

# -- 3. read-limit ------------------------------------------------
for p in files:
    n = len(p.read_text(encoding="utf-8", errors="replace").splitlines())
    if n > max_lines:
        fail(f"line-limit breach: {p.relative_to(cand)} has {n} lines > {max_lines}")

# -- 4. hygiene: secrets-shaped content ---------------------------
SECRET_RX = re.compile(
    r"(BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|"
    r"ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|"
    r"sk-[A-Za-z0-9_-]{20,}|"
    r"api[_-]?key[\"'\s:=]{1,6}[A-Za-z0-9_/-]{20,})", re.I)
for p in files:
    m = SECRET_RX.search(p.read_text(encoding="utf-8", errors="replace"))
    if m:
        fail(f"secrets-shaped content in {p.relative_to(cand)}: {m.group(0)[:24]}..")

# -- 5. publish ---------------------------------------------------
# Guard before the destructive sweep: a wrong --canon-root must not
# mass-delete a foreign tree. The target must either be absent/empty
# (fresh init) or already look like a canon root (canon/RULES.md).
if canon_root.exists():
    if not canon_root.is_dir():
        fail(f"--canon-root exists and is not a dir: {canon_root}")
    existing = [p for p in canon_root.rglob("*") if p.is_file()]
    if existing and not (canon_root / "canon/RULES.md").is_file():
        fail(f"--canon-root {canon_root} is a non-empty dir without "
             f"canon/RULES.md - refusing to sweep a foreign tree "
             f"(pass the real canon root)", 6)
canon_root.mkdir(parents=True, exist_ok=True)
# stale-file sweep: anything in root that the candidate no longer
# ships is removed - deployment is whole-manifest, not additive
kept = {p.relative_to(cand).as_posix() for p in files}
removed = []
for old in canon_root.rglob("*"):
    if old.is_file() and old.relative_to(canon_root).as_posix() not in kept:
        removed.append(old.relative_to(canon_root).as_posix())
        old.unlink()
if removed:
    print(f"canon_pub: swept {len(removed)} stale file(s): "
          f"{removed[:5]}", file=sys.stderr)
for p in files:
    rel = p.relative_to(cand)
    dst = canon_root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(p.read_bytes())
    if p.name.endswith(".sh"):
        dst.chmod(0o755)

manifest = {
    "canon_version": ver,
    "canon_home": "canon/root",
    "canary": "GENERATED_AT_DEPLOY",
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "envelope": {
        "artifact_sha": env["artifact_sha"],
        "signed_by": env.get("signed_by"),
        "ts": env.get("ts"),
    },
    "files": [r for r, _ in tree_entries],
    "sha256": {r: s for r, s in tree_entries},
}
# Schema continuity: keys the deploy pipeline/check_setup rely on
# (canon_home, canary, gitignore, description) carry over from the
# previous manifest; a first-time publish falls back to the shipped
# product defaults so the result still deploys under start_project.sh.
DEFAULTS = {
    "canon_home": "canon/root",
    "canary": "GENERATED_AT_DEPLOY",
    "gitignore": ["canon/", ".devin/", ".windsurfrules",
                  ".windsurfrules.bak", "AGENTS.md", "CLAUDE.md",
                  ".claude/"],
    "description": "CCSDD neutral canon release.",
}
for k, dv in DEFAULTS.items():
    manifest[k] = prev.get(k, dv)
# orchestrator layer hash-pin: protocols/PLAYBOOK/bin drift was a
# real bypass source - the release manifest pins it like the canon
orch_env = os.environ.get("ORCH_DIR")
if orch_env:
    orch = pathlib.Path(orch_env)
    if not orch.is_dir():
        fail(f"--orch-dir missing: {orch}")
    osh = {}
    for p in sorted(orch.rglob("*")):
        if p.is_file():
            osh[p.relative_to(orch).as_posix()] = \
                hashlib.sha256(p.read_bytes()).hexdigest()
    manifest["orchestrator_dir"] = orch_env
    manifest["orchestrator_sha256"] = osh
tmp = manifest_p.with_suffix(".tmp")
tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
os.replace(tmp, manifest_p)

row = {
    "canon_version": ver,
    "tree_sha": tree_sha,
    "signed_by": env.get("signed_by"),
    "ts": env.get("ts"),
    "published_at": manifest["generated_at"],
    "file_count": len(tree_entries),
}
with open(history_p, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")

print(json.dumps({
    "status": "published",
    "canon_version": ver,
    "tree_sha": tree_sha,
    "files": len(tree_entries),
    "next": f"git-agent: commit canon tree + tag canon-v{ver}",
}))
PY
