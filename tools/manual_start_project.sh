#!/usr/bin/env bash
# manual_start_project.sh - interactive wizard for a human operator.
# Collects deploy parameters (project dir, git/remote, repo slug,
# language, canon source, target runtimes), shows the exact command
# line for confirmation, then execs start_project.sh with plain args.
#
# Nothing is modified until the final confirmation.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEPLOY="$SCRIPT_DIR/start_project.sh"
ADAPTER_DIR="$SCRIPT_DIR/../adapters"
[ -x "$DEPLOY" ] || { echo "manual_start_project: $DEPLOY not found/not executable" >&2; exit 1; }

ask() {  # ask VAR "prompt" [default]
  local var="$1" prompt="$2" def="${3:-}" val
  if [ -n "$def" ]; then printf '%s [%s]: ' "$prompt" "$def" >&2
  else printf '%s: ' "$prompt" >&2; fi
  read -r val
  printf -v "$var" '%s' "${val:-$def}"
}

confirm() { # confirm "prompt" -> 0 on yes
  local val
  printf '%s [y/N]: ' "$1" >&2
  read -r val
  case "$val" in y|Y|yes|да|Да|ДА) return 0 ;; *) return 1 ;; esac
}

echo "=== Manual project onboarding (canon deploy) ==="
echo "Press Enter to accept a [default]. Ctrl-C to abort."
echo

# --- 1. workspace ---
ask WORKSPACE "Project directory (repo root or its parent)" ""
WORKSPACE="${WORKSPACE%/}"
[ -n "$WORKSPACE" ] || { echo "ERROR: workspace path is required" >&2; exit 1; }
if [ ! -d "$WORKSPACE" ]; then
  confirm "Directory '$WORKSPACE' does not exist - create it?" \
    && mkdir -p "$WORKSPACE" \
    || { echo "aborted" >&2; exit 1; }
fi
WORKSPACE=$(cd "$WORKSPACE" && pwd -P)

# --- 2. git repository ---
GIT_TOP=$(git -C "$WORKSPACE" rev-parse --show-toplevel 2>/dev/null \
       || git -C "$WORKSPACE/code" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$GIT_TOP" ]; then
  echo "No git repository found under $WORKSPACE."
  if confirm "Initialize git here (git init + branch main)?"; then
    git -C "$WORKSPACE" init -b main >/dev/null 2>&1 \
      || { git -C "$WORKSPACE" init >/dev/null \
           && git -C "$WORKSPACE" symbolic-ref HEAD refs/heads/main; }
    GIT_TOP=$(cd "$WORKSPACE" && git rev-parse --show-toplevel)
  else
    echo "ERROR: the canon requires a git repository" >&2; exit 1
  fi
fi
echo "git top: $GIT_TOP"

# --- 3. remote / repo slug ---
REMOTE_URL=$(git -C "$GIT_TOP" remote get-url origin 2>/dev/null || true)
DETECTED=""
if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
  DETECTED="${BASH_REMATCH[1]}"
fi
if [ -z "$REMOTE_URL" ]; then
  ask NEW_REMOTE "Git remote URL (empty = skip for now)" ""
  if [ -n "$NEW_REMOTE" ]; then
    git -C "$GIT_TOP" remote add origin "$NEW_REMOTE" 2>/dev/null \
      || git -C "$GIT_TOP" remote set-url origin "$NEW_REMOTE"
    REMOTE_URL="$NEW_REMOTE"
    [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]] && DETECTED="${BASH_REMATCH[1]}"
  fi
else
  echo "origin: $REMOTE_URL"
fi
ask REPO_SLUG "Repo slug owner/name for project.json" "${DETECTED:-owner/$(basename "$GIT_TOP")}"

# --- 4. language ---
ask TEXT_LANG "Text language for artifacts (en|ru)" "ru"
case "$TEXT_LANG" in en|ru) ;; *) echo "ERROR: must be en or ru" >&2; exit 1 ;; esac

# --- 5. canon source ---
DEFAULT_CANON=$(cd "$SCRIPT_DIR/../canon/root" 2>/dev/null && pwd -P || true)
ask CANON "Canon source dir (the product's canon/root)" "$DEFAULT_CANON"
[ -d "$CANON/canon" ] || { echo "ERROR: '$CANON' is not a canon root (no canon/ tree inside)" >&2; exit 1; }

# --- 6. target runtimes (adapters) ---
echo
echo "Available runtime adapters in $ADAPTER_DIR:"
AVAIL=()
for f in "$ADAPTER_DIR/"*.sh; do
  n=$(basename "$f" .sh); AVAIL+=("$n"); echo "  - $n"
done
ask PICK "Adapters to apply, comma-separated (empty = none)" "${AVAIL[*]// /,}"
ADAPTERS=()
IFS=',' read -ra want <<< "$PICK"
for w in "${want[@]}"; do
  w=$(echo "$w" | tr -d ' ')
  [ -z "$w" ] && continue
  [ -x "$ADAPTER_DIR/$w.sh" ] || { echo "ERROR: unknown adapter '$w'" >&2; exit 1; }
  ADAPTERS+=("$w")
done

# --- 7. optional extras ---
ask PROTECTED "Extra protected paths, comma-separated (empty = none)" ""

ALLOW_UNTAGGED=0
MANIFEST="$CANON/../MANIFEST.json"
CANON_REPO=$(git -C "$CANON" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$CANON_REPO" ] && [ -f "$MANIFEST" ]; then
  VER=$(python3 -c "import json;print(json.load(open('$MANIFEST'))['canon_version'])" 2>/dev/null || echo "?")
  if ! git -C "$CANON_REPO" rev-parse -q --verify "refs/tags/v$VER" >/dev/null 2>&1 \
     && ! git -C "$CANON_REPO" rev-parse -q --verify "refs/tags/canon-v$VER" >/dev/null 2>&1; then
    echo "NOTE: canon v$VER has no release tag (v$VER) in $CANON_REPO."
    confirm "Deploy anyway (--allow-untagged-canon, logged drift incident)?" \
      && ALLOW_UNTAGGED=1 \
      || { echo "aborted: release the canon first (canon_pub.sh + tag)" >&2; exit 1; }
  fi
fi

# --- summary + confirm ---
ARGS=(--workspace "$WORKSPACE" --repo "$REPO_SLUG" --text-lang "$TEXT_LANG" --canon "$CANON")
for a in "${ADAPTERS[@]}"; do ARGS+=(--adapter "$a"); done
[ -n "$PROTECTED" ] && ARGS+=(--protected-paths "$PROTECTED")
[ "$ALLOW_UNTAGGED" = "1" ] && ARGS+=(--allow-untagged-canon)

echo
echo "=== DEPLOY PLAN ==="
echo "  workspace   : $WORKSPACE"
echo "  git_top     : $GIT_TOP"
echo "  repo_slug   : $REPO_SLUG"
echo "  text_lang   : $TEXT_LANG"
echo "  canon       : $CANON"
echo "  adapters    : ${ADAPTERS[*]:-<none>}"
echo "  protected   : ${PROTECTED:-<defaults only>}"
echo "  command     : $DEPLOY ${ARGS[*]}"
echo
confirm "Proceed with deployment?" || { echo "aborted" >&2; exit 1; }

exec "$DEPLOY" "${ARGS[@]}"
