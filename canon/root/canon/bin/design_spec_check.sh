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
AXES=$(awk '
  {
    line=$0
    sub(/^[[:space:]]+/,"",line)
    while (line !~ /^##/ && line ~ /^(#|\/\/|\*|\/\*|\*\/|""")/) {
      sub(/^("""|\/\*|\*\/|\/\/|#|\*)/,"",line)
      sub(/^[[:space:]]+/,"",line)
    }
    if (line ~ /^##[[:space:]]+Delegated decisions/) { insec=1; next }
    if (line ~ /^##[[:space:]]/ && insec) { insec=0 }
    if (insec && line ~ /^-[[:space:]]+axis:/) {
      sub(/^-[[:space:]]+axis:[[:space:]]*/,"",line)
      sub(/[[:space:]]*\|.*/,"",line)
      # Unified normalization with fidelity_check.sh: lowercase,
      # [a-z0-9_-] only - case/whitespace can never make one axis
      # pass here and fail the fidelity floor.
      line=tolower(line); gsub(/[^a-z0-9_-]/,"",line)
      if (line != "") print line
    }
  }' "$CONTRACT" | sort -u)

if [ -z "$AXES" ]; then
  echo "design_spec_check: no delegated axes declared - designer not required"
  exit 0
fi

NAXES=$(printf '%s\n' "$AXES" | wc -l)
if [ -z "$SPEC" ] || [ ! -r "$SPEC" ]; then
  echo "design_spec_check: FAIL - $NAXES delegated axis/axes declared but no readable impl spec (--spec)" >&2
  exit 1
fi

# Spec axes with a non-empty decision inside their own block.
DECIDED=$(awk '
  /^###[[:space:]]+axis:/ {
    if (name != "" && dec != "") print name
    name=$0; sub(/^###[[:space:]]+axis:[[:space:]]*/,"",name)
    sub(/[[:space:]]*\|.*/,"",name)
    name=tolower(name); gsub(/[^a-z0-9_-]/,"",name); dec=""
    next
  }
  /^#{1,3}[[:space:]]/ && !/^###[[:space:]]+axis:/ {
    if (name != "" && dec != "") print name
    name=""; dec=""; next
  }
  name != "" && /^[[:space:]]*-[[:space:]]+decision:[[:space:]]*[^[:space:]]/ { dec=1 }
  END { if (name != "" && dec != "") print name }' "$SPEC" | sort -u)

NAMED=$(awk '/^###[[:space:]]+axis:/ {
    name=$0; sub(/^###[[:space:]]+axis:[[:space:]]*/,"",name)
    sub(/[[:space:]]*\|.*/,"",name)
    name=tolower(name); gsub(/[^a-z0-9_-]/,"",name)
    if (name != "") print name }' "$SPEC" | sort -u)

MISSING=$(comm -23 <(printf '%s\n' "$AXES") <(printf '%s\n' "$DECIDED"))
EXTRA=$(comm -13 <(printf '%s\n' "$AXES") <(printf '%s\n' "$NAMED"))

if [ -n "$MISSING" ] || [ -n "$EXTRA" ]; then
  [ -n "$MISSING" ] && printf 'design_spec_check: FAIL - declared axes without a decided spec entry:\n%s\n' "$MISSING" >&2
  [ -n "$EXTRA" ] && printf 'design_spec_check: FAIL - spec resolves undeclared axes (improvisation):\n%s\n' "$EXTRA" >&2
  exit 1
fi
echo "design_spec_check: OK - $NAXES declared axis/axes covered"
