#!/usr/bin/env bash
# adapters/devin.sh - adapt a deployed neutral canon/ tree for the
# Devin runtime. Idempotent; safe to re-run after canon upgrades.
#
# Devin glue produced inside <workspace>:
#   .devin/               real dir, per-entry symlinks into canon/
#     agents -> ../canon/agents
#     bin    -> ../canon/bin
#     specs  -> ../canon/specs
#     canon_manifest.json -> ../canon/canon_manifest.json
#     project.json        -> ../canon/project.json
#     config.json         COMPILED from canon/config/policy.json
#   .windsurfrules        symlink -> canon/RULES.md (Devin reads it;
#                         the canary tail lives inside canon/)
#
# Usage: devin.sh <workspace>
set -euo pipefail

die() { echo "adapter devin: $*" >&2; exit 1; }
[ $# -eq 1 ] || die "usage: $0 <workspace>"
WS=$(cd "$1" && pwd -P)
CANON="$WS/canon"
[ -d "$CANON/bin" ] && [ -d "$CANON/agents" ] && [ -d "$CANON/specs" ] \
  || die "no deployed canon tree at $CANON (run start_project.sh first)"
[ -f "$CANON/RULES.md" ] || die "$CANON/RULES.md missing"
POLICY="$CANON/config/policy.json"
[ -f "$POLICY" ] || die "$POLICY missing"

# --- .devin symlink farm -----------------------------------------
# A real directory (not a whole-dir symlink) so devin-specific real
# files (config.json) can live next to the canon-linked entries.
mkdir -p "$WS/.devin"
link() { # link <target-name-inside-.devin> <relative-source>
  local name="$1" src="$2"
  if [ -L "$WS/.devin/$name" ] || [ -e "$WS/.devin/$name" ]; then
    if [ -L "$WS/.devin/$name" ] && [ "$(readlink "$WS/.devin/$name")" = "$src" ]; then
      return 0
    fi
    cp -a "$WS/.devin/$name" "$WS/.devin/$name.bak.$(date +%s)" 2>/dev/null || true
    rm -rf "${WS:?}/.devin/$name"
  fi
  ln -s "$src" "$WS/.devin/$name"
}
link agents           "../canon/agents"
link bin              "../canon/bin"
link specs            "../canon/specs"
link canon_manifest.json "../canon/canon_manifest.json"
[ -f "$CANON/project.json" ] && link project.json "../canon/project.json" || true

# --- .windsurfrules -> canon/RULES.md -----------------------------
if [ -e "$WS/.windsurfrules" ] && [ ! -L "$WS/.windsurfrules" ]; then
  cp -p "$WS/.windsurfrules" "$WS/.windsurfrules.bak"
  rm "$WS/.windsurfrules"
fi
[ -L "$WS/.windsurfrules" ] && rm "$WS/.windsurfrules"
ln -s canon/RULES.md "$WS/.windsurfrules"

# --- compile .devin/config.json from the neutral policy -----------
python3 - "$POLICY" "$WS/.devin/config.json" <<'PY'
import json, sys
policy = json.load(open(sys.argv[1], encoding="utf-8"))
ex = policy.get("exec") or {}
deny = [f"Exec({v})" for v in ex.get("deny", [])]
# canon/bin + the symlinked .devin/bin alias both allowed
allow = []
for v in ex.get("allow", []):
    allow += [f"Exec({v})", f"Exec(./{v})"]
    if v == "canon/bin/":
        allow += ["Exec(.devin/bin/)", "Exec(./.devin/bin/)"]
out = {"permissions": {"deny": deny, "allow": allow}}
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY

echo "adapter devin: .devin/ links + config.json + .windsurfrules -> canon/RULES.md"
