#!/usr/bin/env bash
# adapters/generic.sh - runtime-agnostic glue for agents that read
# AGENTS.md (the de-facto cross-runtime entry convention). Writes a
# marked block pointing at canon/RULES.md; idempotent, coexists with
# other adapters' glue.
#
# Usage: generic.sh <workspace>
set -euo pipefail

die() { echo "adapter generic: $*" >&2; exit 1; }
[ $# -eq 1 ] || die "usage: $0 <workspace>"
WS=$(cd "$1" && pwd -P)
[ -f "$WS/canon/RULES.md" ] || die "no deployed canon at $WS/canon (run start_project.sh first)"

python3 - "$WS/AGENTS.md" <<'PY'
import sys
path = sys.argv[1]
begin = "# >>> canon entry (managed by CCSDD adapter: generic) >>>"
end = "# <<< canon entry <<<"
block = "\n".join([
    begin,
    "This repository is governed by the canon in `canon/`.",
    "",
    "1. Read `canon/RULES.md` first - it is the instance kernel; if its",
    "   last line is not `CANARY_EOF_TOKEN:<token>`, halt (rules",
    "   truncated).",
    "2. Role profiles live in `canon/agents/`; specs in `canon/specs/`;",
    "   gate scripts in `canon/bin/` (run `canon/bin/check_setup.sh`",
    "   before anything else - it fails closed).",
    "3. Never edit anything under `canon/` or this file's marked block.",
    end,
])
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    text = ""
if begin in text:
    i = text.index(begin)
    try:
        j = text.index(end, i) + len(end)
    except ValueError:
        # Stale/partial block (begin marker without end): replace only
        # the marker line, keep the rest of the file intact.
        j = i + len(begin)
    text = text[:i] + block + text[j:]
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += block + "\n"
open(path, "w", encoding="utf-8").write(text)
PY

echo "adapter generic: AGENTS.md canon entry installed"
