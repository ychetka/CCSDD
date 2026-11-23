#!/usr/bin/env bash
# design_spec_check.sh - mechanical gate between the designer and the
# code_writer (harness.md §4).
#
#   design_spec_check.sh --contract <file> --spec <file>
#
# --contract: a file holding the item's contract block (the item
#   section of roadmap.md, or the contract file itself for
#   text-format contracts). If it contains a `## Delegated decisions`
#   section, every axis declared as
#     - axis: <name> | constraint: <text>
#   must be resolved by the impl spec. In code-format contracts the
#   section lives inside a comment container that keeps the file
#   compilable: python `""" ... """` docstring or `#`-comments,
#   typescript `/** ... */` block or `//`-comments.
# --spec: the designer's impl spec (the `## Impl spec` block appended
#   to the item journal), with entries
#     ### axis: <name>
#     - decision: ...
#     - constraint_check: ...
#     - alternatives: ...
#
# Markdown fenced code blocks (``` and ~~~) are opaque on BOTH
# inputs - an `### axis:` inside a usage example is documentation,
# not a declaration, and a `- axis:` inside a contract's code sample
# is not a delegation.
#
# Exit 0: no declared axes (designer not required), or every declared
#   axis is covered by a spec entry carrying a non-empty decision.
# Exit 1: axes declared but --spec missing, a declared axis uncovered
#   or undecided, or the spec names an axis the contract did not
#   delegate (improvisation).
# Exit 2: usage / unreadable contract file.
set -euo pipefail

CONTRACT=""; SPEC=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "usage: design_spec_check.sh --contract <file> --spec <file>" >&2; exit 2; }
  case "$1" in
    --contract) CONTRACT=$2;; --spec) SPEC=$2;;
    *) echo "usage: design_spec_check.sh --contract <file> --spec <file>" >&2; exit 2;;
  esac; shift 2
done
[ -n "$CONTRACT" ] || { echo "design_spec_check: --contract required" >&2; exit 2; }
[ -r "$CONTRACT" ] || { echo "design_spec_check: contract file unreadable: $CONTRACT" >&2; exit 2; }

# Declared axes: "- axis: <name>" lines inside the section. The
# section may sit inside a comment/docstring container so the file
# still compiles: python `"""..."""` or `#`-lines, ts `/** ... */`
# or `//`-lines. Leading comment markers are stripped before
# matching (but `##` itself is kept, it is the section marker).
# Fenced code blocks are skipped BEFORE marker stripping.
AXES=$(CONTRACT="$CONTRACT" python3 - <<'PY'
import os, re
def strip_markers(line):
    line = line.strip()
    while line and not line.startswith("##") and \
            re.match(r'^(#|//|\*|/\*|\*/|""")', line):
        line = re.sub(r'^("""|/\*|\*/|//|#|\*)', "", line).strip()
    return line
def norm(name):
    # Unified normalization with fidelity_check.sh: lowercase,
    # [a-z0-9_-] only - case/whitespace can never make one axis
    # pass here and fail the fidelity floor.
    return re.sub(r"[^a-z0-9_-]", "", name.lower())
fence = None
insec = False
out = []
for raw in open(os.environ["CONTRACT"], encoding="utf-8",
                errors="replace").read().splitlines():
    s = raw.strip()
    fm = re.match(r"^(`{3,}|~{3,})", s)
    if fm:
        mark = fm.group(1)[0]
        if fence is None:
            fence = mark
        elif mark == fence:
            fence = None
        continue
    if fence is not None:
        continue
    line = strip_markers(raw)
    if re.match(r"^##\s+Delegated decisions", line):
        insec = True; continue
    if insec and re.match(r"^##\s", line):
        insec = False; continue
    if insec:
        m = re.match(r"^-\s+axis:\s*([^|]+)", line)
        if m:
            a = norm(m.group(1))
            if a: out.append(a)
print("\n".join(sorted(set(out))))
PY
)

if [ -z "$AXES" ]; then
  echo "design_spec_check: no delegated axes declared - designer not required"
  exit 0
fi

NAXES=$(printf '%s\n' "$AXES" | wc -l)
if [ -z "$SPEC" ] || [ ! -r "$SPEC" ]; then
  echo "design_spec_check: FAIL - $NAXES delegated axis/axes declared but no readable impl spec (--spec)" >&2
  exit 1
fi

# Spec axes with a non-empty decision inside their own block; NAMED
# is every axis heading regardless of decision. Both go through the
# same marker-strip + fence-skip pipeline as the contract so a spec
# example can neither invent nor silently cover an axis.
PARSED=$(SPEC="$SPEC" python3 - <<'PY'
import os, re
def strip_markers(line):
    line = line.strip()
    while line and not line.startswith("##") and \
            re.match(r'^(#|//|\*|/\*|\*/|""")', line):
        line = re.sub(r'^("""|/\*|\*/|//|#|\*)', "", line).strip()
    return line
def norm(name):
    return re.sub(r"[^a-z0-9_-]", "", name.lower())
fence = None
name, dec = "", False
named, decided = set(), set()
in_spec = False
has_spec = False
def flush():
    if name and dec:
        decided.add(name)
for raw in open(os.environ["SPEC"], encoding="utf-8",
                errors="replace").read().splitlines():
    s = raw.strip()
    fm = re.match(r"^(`{3,}|~{3,})", s)
    if fm:
        mark = fm.group(1)[0]
        if fence is None:
            fence = mark
        elif mark == fence:
            fence = None
        continue
    if fence is not None:
        continue
    line = strip_markers(raw)
    # Axes count only inside the '## Impl spec' section - a spec file
    # without that section violates the designer.md contract and must
    # fail loudly, not auto-pass with an empty axis set.
    if re.match(r"^##\s+Impl spec\b", line):
        flush(); in_spec = True; has_spec = True
        name = ""; dec = False; continue
    if re.match(r"^##\s", line):
        flush(); in_spec = False; name = ""; dec = False; continue
    m = re.match(r"^###\s+axis:\s*([^|]+)", line)
    if m:
        flush()
        if in_spec:
            name = norm(m.group(1)); dec = False
            if name: named.add(name)
        continue
    if re.match(r"^#{1,3}\s", line):
        flush(); name = ""; dec = False; continue
    if name and re.match(r"^\s*-\s+decision:\s*\S", line):
        dec = True
flush()
print("HAS_SPEC:" + ("1" if has_spec else "0"))
print("NAMED:" + ",".join(sorted(named)))
print("DECIDED:" + ",".join(sorted(decided)))
PY
)
NAMED=$(printf '%s\n' "$PARSED" | sed -n 's/^NAMED://p' | tr ',' '\n' | sed '/^$/d' | sort -u)
DECIDED=$(printf '%s\n' "$PARSED" | sed -n 's/^DECIDED://p' | tr ',' '\n' | sed '/^$/d' | sort -u)

HAS_SPEC=$(printf '%s\n' "$PARSED" | sed -n 's/^HAS_SPEC://p')
if [ "$HAS_SPEC" != "1" ]; then
  echo "design_spec_check: FAIL - spec file has no '## Impl spec' section" >&2
  exit 1
fi

MISSING=$(comm -23 <(printf '%s\n' "$AXES") <(printf '%s\n' "$DECIDED"))
EXTRA=$(comm -13 <(printf '%s\n' "$AXES") <(printf '%s\n' "$NAMED"))

if [ -n "$MISSING" ] || [ -n "$EXTRA" ]; then
  [ -n "$MISSING" ] && printf 'design_spec_check: FAIL - declared axes without a decided spec entry:\n%s\n' "$MISSING" >&2
  [ -n "$EXTRA" ] && printf 'design_spec_check: FAIL - spec resolves undeclared axes (improvisation):\n%s\n' "$EXTRA" >&2
  exit 1
fi
echo "design_spec_check: OK - $NAXES declared axis/axes covered"
