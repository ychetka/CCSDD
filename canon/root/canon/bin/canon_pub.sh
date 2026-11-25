#!/usr/bin/env bash
# canon_pub.sh - canon publication gate (specs/canon_gate.md).
#
#   canon_pub.sh publish --candidate <canon_ws_dir> \
#     --envelope <envelope.json> --version <semver> \
#     [--canon-root <dir>] [--manifest <path>] [--history <path>]
#
# Fail-closed checks, in order:
#   1. candidate tree exists and is non-empty
#   2. human decision envelope validates through the SAME sign-off
#      machinery the merge gates use (canon/bin/human_sign.sh): an
#      ssh-sig envelope binding verdict=approve + artifact +
#      ts + nonce. The artifact here is
#      sha256("canon-v<ver>|<candidate_tree_sha256>") so a valid
#      envelope can never be replayed under a different version;
#      verify runs before publish, consume after, so a refused
#      publish does not burn the human's nonce.
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
# Gate 0 (review_15 #5 / review_16 #12): never run under a
# workspace-tampered canon - prove manifest hashes + the external
# stamp before trusting any $CANON_DIR script or adapter hook.
if [ -f "$CANON_DIR/canon_manifest.json" ]; then
  [ -x "$CANON_DIR/bin/assert_canon_integrity.sh" ] \
    || { echo "GATE_INTEGRITY: assert_canon_integrity.sh missing under a pinned manifest" >&2; exit 1; }
  "$CANON_DIR/bin/assert_canon_integrity.sh" || exit 1
fi

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
ORCH_DIR="$ORCH_DIR" HS="$CANON_DIR/bin/human_sign.sh" \
SCAN="$CANON_DIR/bin/secret_scan.py" \
python3 -I - <<'PY'
import datetime, hashlib, json, os, re, subprocess, sys, pathlib

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
all_entries = list(cand.rglob("*"))
# Path.is_file() follows symlinks: a candidate symlink to an outside
# file (e.g. ~/.ssh/id_rsa) would be dereferenced and PUBLISHED into
# the canon root; a broken symlink would be silently skipped. The
# canon tree ships regular files only - reject any symlink.
for p in all_entries:
    if p.is_symlink():
        fail(f"symlink forbidden in candidate: {p}")
files = sorted(p for p in all_entries if p.is_file())
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
# One signer, one verifier: delegate to canon/bin/human_sign.sh, the
# same ssh-sig machinery issue_merge.sh uses (a shared-key HMAC file
# readable under the agent's UID was the pre-SSH weakness). The
# signed artifact is the composite sha256 below, so verdict +
# version + tree are bound inside one signature; freshness (7d) and
# nonce replay are enforced by the verifier.
publish_sha = hashlib.sha256(
    f"canon-v{ver}|{tree_sha}".encode()).hexdigest()
HS = os.environ.get("HS") or ""
if not os.path.isfile(HS):
    fail(f"canon/bin/human_sign.sh missing: {HS!r}", 5)
r = subprocess.run(["bash", HS, "verify",
                    "--envelope", env_path,
                    "--artifact", publish_sha,
                    "--verdict", "approve"],
                   capture_output=True, text=True)
if r.returncode != 0:
    fail("envelope verification failed: " +
         (r.stderr or r.stdout).strip()[:240], 5)

# Provenance fields for manifest/history - best-effort parse of the
# SAME transports verify accepts (JSON file, compact line, literal).
# Cryptographic truth already came from human_sign above; this only
# fills the audit stamp.
try:
    raw_e = open(env_path, encoding="utf-8").read().strip() \
        if os.path.isfile(env_path) else env_path
except Exception:
    raw_e = ""
env = {}
if raw_e.startswith("CCSDD-SIGNOFF-1|"):
    _p = raw_e.split("|")
    if len(_p) == 6:
        env = {"verdict": _p[1], "ts": _p[3]}
else:
    try:
        env = json.loads(raw_e)
    except Exception:
        env = {}

# -- 3. read-limit ------------------------------------------------
for p in files:
    n = len(p.read_text(encoding="utf-8", errors="replace").splitlines())
    if n > max_lines:
        fail(f"line-limit breach: {p.relative_to(cand)} has {n} lines > {max_lines}")

# -- 4. hygiene: delegate to the canonical scanner - a separate
# regex here would drift from the gate-time pattern set (and already
# missed several GitHub token prefixes + doc placeholders).
SCAN = os.environ.get("SCAN")
if not SCAN or not os.path.isfile(SCAN):
    fail(f"canonical secret_scan.py missing: {SCAN!r}", 6)
for p in files:
    r = subprocess.run([sys.executable, SCAN, "--quiet"],
                       input=p.read_bytes(), capture_output=True)
    if r.returncode == 1:
        fail(f"secrets-shaped content in {p.relative_to(cand)} "
             f"(secret_scan.py hit)")
    if r.returncode not in (0,):
        fail(f"secret_scan.py error rc={r.returncode} on "
             f"{p.relative_to(cand)}", 6)

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
# Drop directories emptied by the sweep (deepest first) so the
# published root mirrors the candidate exactly.
for d in sorted((q for q in canon_root.rglob("*") if q.is_dir()),
                key=lambda q: len(q.parts), reverse=True):
    try:
        d.rmdir()  # succeeds only on an empty dir
    except OSError:
        pass
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
        "format": "ssh-sig-v1",
        "artifact_sha": publish_sha,
        "signed_by": "human",
        "ts": env.get("ts"),
    },
    "file_count": len(tree_entries),
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
# sort_keys=True keeps the published manifest byte-comparable with
# tools/regen_manifest.py output - two writers, one format.
tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2,
                          sort_keys=True) + "\n")
os.replace(tmp, manifest_p)

row = {
    "canon_version": ver,
    "tree_sha": tree_sha,
    "signed_by": "human",
    "ts": env.get("ts"),
    "published_at": manifest["generated_at"],
    "file_count": len(tree_entries),
}
with open(history_p, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")

# Publish succeeded - burn the nonce NOW (never before the action,
# so a refused publish does not strand the human's envelope). A
# consume failure can only be a replay collision or a store write
# error; the publish already landed, so warn rather than fail.
r = subprocess.run(["bash", HS, "consume",
                    "--envelope", env_path,
                    "--artifact", publish_sha,
                    "--verdict", "approve"],
                   capture_output=True, text=True)
if r.returncode != 0:
    print("canon_pub: WARNING - sign-off nonce consume failed "
          "after publish: " + (r.stderr or r.stdout).strip()[:200],
          file=sys.stderr)

print(json.dumps({
    "status": "published",
    "canon_version": ver,
    "tree_sha": tree_sha,
    "files": len(tree_entries),
    "next": f"git-agent: commit canon tree + tag canon-v{ver}",
}))
PY
