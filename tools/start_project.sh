#!/usr/bin/env bash
# start_project.sh - non-interactive deployment of the neutral canon
# into a project workspace, plus runtime adaptation.
#
# Deploys canon/root/ into <workspace>/ (mirror layout -> canon/ dir),
# generates the per-repo canary, writes the gitignore block and
# canon/project.json, runs canon/bin/check_setup.sh fail-closed, then
# invokes every requested adapters/<name>.sh to produce runtime glue.
#
# This is the reusable core: a future orchestrator calls THIS script;
# bus/instance wiring stays outside.
#
# Usage:
#   start_project.sh --workspace DIR [options]
#
# Options:
#   --workspace DIR          project dir (required); repo may sit in DIR or DIR/code
#   --adapter NAME           runtime adapter to apply (repeatable);
#                            available: files adapters/<name>.sh of this product
#   --repo owner/name        repo slug for canon/project.json (default: git remote)
#   --text-lang en|ru        text_language for project.json (default: en)
#   --repo-lang en|ru        repo_language: language of committed artifacts
#                            (default en; opt out only for a non-English repo)
#   --canon DIR              canon source root dir (default: this product's canon/root)
#   --manifest PATH          MANIFEST.json path (default: <canon>/../MANIFEST.json)
#   --protected-paths a,b,c  extra paths for project.json protected_paths
#   --allow-untagged-canon   deploy canon without a canon-v<ver> tag (logged drift)
#   --dry-run                resolve and print planned actions; modify nothing
#   -h|--help
set -euo pipefail

die() { echo "start_project: $*" >&2; exit 1; }
warn() { echo "start_project WARN: $*" >&2; }

WORKSPACE=""; REPO_SLUG=""; TEXT_LANG="en"; REPO_LANG=""; CANON_DIR=""; MANIFEST=""
PROTECTED=""; ALLOW_UNTAGGED=0; DRY_RUN=0; ADAPTERS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace)  WORKSPACE="${2:?--workspace requires path}"; shift 2 ;;
    --adapter)    ADAPTERS+=("${2:?--adapter requires name}"); shift 2 ;;
    --repo)       REPO_SLUG="${2:?--repo requires owner/name}"; shift 2 ;;
    --text-lang)  TEXT_LANG="${2:?--text-lang requires en|ru}"; shift 2 ;;
    --repo-lang)  REPO_LANG="${2:?--repo-lang requires en|ru}"; shift 2 ;;
    --canon)      CANON_DIR="${2:?--canon requires path}"; shift 2 ;;
    --manifest)   MANIFEST="${2:?--manifest requires path}"; shift 2 ;;
    --protected-paths) PROTECTED="${2:?--protected-paths requires a,b,c}"; shift 2 ;;
    --allow-untagged-canon) ALLOW_UNTAGGED=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    sed -n '1,32p' "$0"; exit 0 ;;
    *)            die "unknown arg $1" ;;
  esac
done

[ -n "$WORKSPACE" ] || die "--workspace DIR is required"
[ -d "$WORKSPACE" ] || die "workspace not found: $WORKSPACE"
WORKSPACE=$(cd "$WORKSPACE" && pwd -P)
case "$TEXT_LANG" in en|ru) ;; *) die "--text-lang must be en or ru" ;; esac
case "$REPO_LANG" in en|ru|"") ;; *) die "--repo-lang must be en or ru" ;; esac

PRODUCT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ADAPTER_DIR="$PRODUCT_DIR/adapters"
if [ -z "$CANON_DIR" ]; then
  CANON_DIR="$PRODUCT_DIR/canon/root"
fi
[ -d "$CANON_DIR/canon" ] || die "canon source root not found (expects <dir>/canon tree): $CANON_DIR"
[ -n "$MANIFEST" ] || MANIFEST="$(dirname "$CANON_DIR")/MANIFEST.json"
[ -f "$MANIFEST" ] || die "canon manifest not found: $MANIFEST"

for a in "${ADAPTERS[@]}"; do
  case "$a" in
    *[!a-zA-Z0-9_-]*|"") die "invalid adapter name: '$a' (a-zA-Z0-9_- only)" ;;
  esac
  [ -x "$ADAPTER_DIR/$a.sh" ] || die "no adapter: $ADAPTER_DIR/$a.sh"
done

GIT_TOP=$(git -C "$WORKSPACE" rev-parse --show-toplevel 2>/dev/null \
       || git -C "$WORKSPACE/code" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$GIT_TOP" ] && [ -z "$REPO_SLUG" ]; then
  REMOTE_URL=$(git -C "$GIT_TOP" remote get-url origin 2>/dev/null \
            || git -C "$GIT_TOP" remote -v | awk '$2 ~ /github\.com/ {print $2; exit}' || true)
  if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
    REPO_SLUG="${BASH_REMATCH[1]}"
  fi
fi

# Guard: never deploy onto the canon SOURCE tree itself.
if [ "$(cd "$CANON_DIR" && pwd -P)" = "$WORKSPACE" ] \
   || [ "$(cd "$CANON_DIR/../.." 2>/dev/null && pwd -P || true)" = "$WORKSPACE" ]; then
  die "workspace is the canon source tree - deployment refused"
fi

CANON_VER=$(python3 -c "import json;print(json.load(open('$MANIFEST'))['canon_version'])")

echo "=== START PROJECT (canon deploy) ==="
echo "  workspace  : $WORKSPACE"
echo "  git_top    : ${GIT_TOP:-<none>}"
echo "  repo_slug  : ${REPO_SLUG:-<unknown>}"
echo "  canon      : $CANON_DIR (v$CANON_VER)"
echo "  text_lang  : $TEXT_LANG"
echo "  adapters   : ${ADAPTERS[*]:-<none>}"

if [ "$DRY_RUN" = "1" ]; then
  echo ""
  echo "[DRY-RUN ONLY - no files modified]"
  echo "Planned actions on a real run:"
  echo "  1. release tag check: canon-v$CANON_VER must exist in the canon repo"
  echo "  2. deploy every manifest file verbatim, sha256-verified; remove stale canon files"
  echo "  3. generate per-repo canary -> canon/RULES.md tail + canon/canon_manifest.json stamp"
  echo "  4. insert canon gitignore block; untrack deployed paths (infra commit, default branch only)"
  echo "  5. generate canon/project.json if absent"
  echo "  6. run canon/bin/check_setup.sh - fail closed"
  for a in "${ADAPTERS[@]}"; do echo "  7+. run adapters/$a.sh"; done
  exit 0
fi

[ -n "$GIT_TOP" ] || die "workspace must contain a git repository (init it first, or re-run pointing at the repo root)"

# Canon release fencing: deploy only a released canon (canon-v<ver> tag).
CANON_REPO=$(git -C "$CANON_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$CANON_REPO" ]; then
  if ! git -C "$CANON_REPO" rev-parse -q --verify "refs/tags/canon-v$CANON_VER" >/dev/null; then
    if [ "$ALLOW_UNTAGGED" = "1" ]; then
      warn "canon v$CANON_VER has no canon-v$CANON_VER tag - deploying under --allow-untagged-canon (drift incident, journal it)"
    else
      die "canon v$CANON_VER is not released (no canon-v$CANON_VER tag in $CANON_REPO). Publish via canon_pub.sh + tag, or pass --allow-untagged-canon"
    fi
  fi
else
  warn "canon dir is not inside a git repo - release tag check skipped"
fi

# Manifest-driven deploy: every file verbatim + sha256; stale files from
# an earlier canon are removed; the manifest lands as the deploy stamp.
python3 - "$CANON_DIR" "$MANIFEST" "$WORKSPACE" <<'PY'
import hashlib, json, os, shutil, stat, sys
canon, manifest_path, ws = sys.argv[1:4]
m = json.load(open(manifest_path, encoding="utf-8"))
hashes = m.get("sha256") or {}

old_files = []
stamp = os.path.join(ws, "canon", "canon_manifest.json")
try:
    old_files = json.load(open(stamp, encoding="utf-8")).get("files", [])
except Exception:
    pass

new_set = set(m["files"])
for rel in m["files"]:
    # Manifest paths must stay inside the workspace - a '../' entry
    # would write outside the deploy root.
    if not rel or rel.startswith("/") or ".." in rel.split("/"):
        print(f"DEPLOY FAIL: unsafe manifest path: {rel!r}", file=sys.stderr)
        sys.exit(1)
    src = os.path.join(canon, rel)
    if not os.path.isfile(src):
        print(f"DEPLOY FAIL: manifest file missing in canon: {rel}", file=sys.stderr)
        sys.exit(1)
    want = hashes.get(rel)
    if want and hashlib.sha256(open(src, "rb").read()).hexdigest() != want:
        print(f"DEPLOY FAIL: canon hash mismatch: {rel}", file=sys.stderr)
        sys.exit(1)
    dst = os.path.join(ws, rel)
    os.makedirs(os.path.dirname(dst) or ws, exist_ok=True)
    shutil.copy2(src, dst)
    if rel.endswith(".sh"):
        os.chmod(dst, os.stat(dst).st_mode | stat.S_IXUSR | stat.S_IXGRP)

for rel in old_files:
    if rel in new_set:
        continue
    dst = os.path.join(ws, rel)
    if os.path.isfile(dst):
        os.remove(dst)
        print(f"canon: removed stale {rel}")

os.makedirs(os.path.dirname(stamp), exist_ok=True)
# Executable hooks that gate scripts may invoke but that live outside
# the shipped manifest: ONLY the declared adapter names at the canon
# root plus anything under canon/tools/. A planted canon/bin/evil.sh
# must stay an "extra file", never a silently-legalized "hook" - the
# allowlist is closed on purpose.
HOOK_NAMES = {"canon/version_source.sh", "canon/baseline_env.sh"}
adapters = {}
for dp, _dn, fns in os.walk(os.path.join(ws, "canon")):
    for name in sorted(fns):
        rel = "canon/" + os.path.relpath(os.path.join(dp, name),
                                         os.path.join(ws, "canon"))
        if rel in new_set:
            continue
        if rel in HOOK_NAMES or rel.startswith("canon/tools/"):
            adapters[rel] = hashlib.sha256(
                open(os.path.join(dp, name), "rb").read()).hexdigest()
if adapters:
    m["adapters_sha256"] = adapters
with open(stamp, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print(f"canon {m['canon_version']}: deployed {len(m['files'])} files"
      + (f" (+{len(adapters)} pinned adapter hooks)" if adapters else ""))
PY

# Per-repo canary: proves canon/RULES.md was not truncated. Written into
# the rules tail and the deploy stamp; source keeps GENERATED_AT_DEPLOY.
python3 - "$WORKSPACE" <<'PY'
import hashlib, json, secrets, sys
ws = sys.argv[1]
token = "cnr-" + secrets.token_hex(8)
stamp = f"{ws}/canon/canon_manifest.json"
m = json.load(open(stamp, encoding="utf-8"))
m["canary"] = token
rules = f"{ws}/canon/RULES.md"
text = open(rules, encoding="utf-8").read()
if "GENERATED_AT_DEPLOY" not in text:
    print("DEPLOY FAIL: canon/RULES.md has no canary placeholder", file=sys.stderr)
    sys.exit(1)
text = text.replace("GENERATED_AT_DEPLOY", token)
with open(rules, "w", encoding="utf-8") as fh:
    fh.write(text)
# record the post-canary hash so the drift check still detects TAMPERING
m.setdefault("sha256", {})["canon/RULES.md"] = \
    hashlib.sha256(open(rules, "rb").read()).hexdigest()
with open(stamp, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print(f"canon: canary {token} stamped into manifest + rules tail")
PY

# gitignore block: canon files are deployed, not tracked.
python3 - "$MANIFEST" "$WORKSPACE/.gitignore" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
gi_path = sys.argv[2]
begin = "# >>> canon (deployed by CCSDD, not tracked) >>>"
end = "# <<< canon <<<"
block = [begin] + m["gitignore"] + [end]
try:
    lines = open(gi_path, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    lines = []
out, skip = [], False
for ln in lines:
    if ln == begin: skip = True
    if not skip: out.append(ln)
    if ln == end: skip = False
out += block
with open(gi_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
PY

# Untrack deployed paths: infra commit ONLY on the default branch with a
# clean index; any other state defers to a later run.
WORKSPACE="$WORKSPACE" python3 - "$MANIFEST" "$GIT_TOP" <<'PY'
import json, os, subprocess, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
top = sys.argv[2]

def git(*a):
    return subprocess.run(["git", "-C", top] + list(a),
                          capture_output=True, text=True)

untracked = []
for pat in m.get("gitignore", []):
    probe = pat.rstrip("/")
    r = git("ls-files", "-z", "--", probe)
    for f in r.stdout.split("\0"):
        if f:
            untracked.append(f)
# Pre-existing tracked files that the deploy will evict from the
# index (the working copy is NOT touched) must be announced - a
# project file silently disappearing from git tracking is a
# surprising side effect.
preexisting = [f for f in untracked
               if os.path.basename(f) in ("AGENTS.md", "CLAUDE.md")]
if preexisting:
    print("canon NOTICE: these tracked files will be untracked "
          "(kept on disk, covered by canon .gitignore): "
          + ", ".join(preexisting))
staged = git("diff", "--cached", "--name-only").stdout.split()
if staged:
    print("canon WARN: index has staged changes - untrack deferred "
          "(rerun on a clean index)")
    sys.exit(0)
branch = git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
default = (git("symbolic-ref", "--short", "refs/remotes/origin/HEAD")
           .stdout.strip().removeprefix("origin/")) or "main"
gi_abs = os.path.join(os.environ.get("WORKSPACE", top), ".gitignore")
gi_rel = os.path.relpath(gi_abs, top)
gi_stage = (not gi_rel.startswith("..")
            and os.path.isfile(gi_abs)
            and git("diff", "--name-only", "--", gi_rel).stdout.strip())
if not untracked and not gi_stage:
    sys.exit(0)
if branch != default:
    print(f"canon WARN: on branch '{branch}' (default '{default}') - "
          "untrack/gitignore commit deferred; rerun on the default branch")
    if gi_stage:
        git("add", "--", gi_rel)
    sys.exit(0)
if untracked:
    r = git("rm", "-r", "-q", "--cached", "--", *untracked)
    if r.returncode != 0:
        print(f"canon WARN: git rm --cached failed: {r.stderr.strip()[:200]}")
        sys.exit(0)
if gi_stage:
    git("add", "--", gi_rel)
c = subprocess.run(
    ["git", "-C", top, "-c", "user.name=canon-onboard",
     "-c", "user.email=canon-onboard@local",
     "commit", "-q", "-m",
     "chore(canon): untrack canon-deployed paths"],
    capture_output=True, text=True)
if c.returncode == 0:
    print(f"canon: untracked {len(untracked)} deployed path(s) "
          f"+ .gitignore update committed on '{default}'")
else:
    subprocess.run(["git", "-C", top, "reset", "-q"],
                   capture_output=True, text=True)
    print(f"canon WARN: untrack commit failed (index restored): "
          f"{c.stderr.strip()[:200]}")
PY

if [ ! -f "$WORKSPACE/canon/project.json" ]; then
  [ -n "$REPO_SLUG" ] || REPO_SLUG="owner/$(basename "$WORKSPACE")"
  python3 - "$WORKSPACE/canon/project.json" "$REPO_SLUG" "$TEXT_LANG" "$PROTECTED" "$REPO_LANG" <<'PY'
import json, sys
path, repo, lang, protected, rlang = sys.argv[1:6]
cfg = {
    "repo": repo,
    "text_language": lang,
    "protected_paths": ["canon/", ".devin/", ".windsurfrules", "AGENTS.md",
                      "partners/config.json"],
    # Fresh repo default: no project test suite is configured yet, so
    # the tester floor is explicitly opted out (visible in config,
    # not silently skipped). Point gate_checks.test_suite at the real
    # test command to activate it - attested via gate_run in the
    # credential-free worktree before merge.
    "gate_checks": {"test_suite_optional": True},
}
if rlang:
    cfg["repo_language"] = rlang
if protected:
    cfg["protected_paths"] += [p for p in protected.split(",") if p]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
fi

"$WORKSPACE/canon/bin/check_setup.sh" || {
  die "check_setup.sh failed in $WORKSPACE"
}

for a in "${ADAPTERS[@]}"; do
  "$ADAPTER_DIR/$a.sh" "$WORKSPACE" || die "adapter $a failed"
done

cat <<EOF

DEPLOY OK: canon v$CANON_VER -> $WORKSPACE
adapters applied: ${ADAPTERS[*]:-<none>}

Next steps for the operator:
  1. Open a fresh agent instance with working_directory = $WORKSPACE
  2. Its first move: read canon/RULES.md (last line must be
     CANARY_EOF_TOKEN:<token> - halt if absent) and re-run
     canon/bin/check_setup.sh
  3. Human gates stay with you: roadmap approve, contract sign-off
     (per roadmap item, before its implementation), escalation
     decisions. Merge is objective (reviewer APPROVEs + checks);
     a .changes fragment with manual_gate: true parks a PR for you.
  4. Provision the human sign-off identity once (outside the
     workspace, ssh-agent key only):
       canon/bin/human_sign.sh init
     Remote humans (laptop + ssh, no agent on this machine): run
     init + sign on the laptop with --out - and paste the
     CCSDD-SIGNOFF-1|<verdict>|<sha>|<ts>|<nonce>|<sig> line into
     the agent chat - the gate verifies it identically.
EOF
