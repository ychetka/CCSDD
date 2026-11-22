#!/usr/bin/env bash
# roadmap_hash.sh - mechanical frozen_hash for canon/roadmap.md items.
#
#   roadmap_hash.sh --verify [--item <slug>]
#   roadmap_hash.sh --fill   [--item <slug>]
#   roadmap_hash.sh --compute --item <slug>
#
# Canonicalization (roadmap.template.md): the item block text with
# the mutable fields status/pr/issue/frozen_hash REMOVED, remaining
# lines right-trimmed, joined by \n in file order, sha256 of that.
#
# --verify: recompute every item carrying a frozen_hash field and
#   compare. Exit 0 when all recorded hashes match; exit 1 naming
#   drifted items. FAIL-CLOSED: an item whose frozen_hash field is
#   missing or still a placeholder fails verification - a deleted
#   field would otherwise hide post-freeze edits.
# --fill: write the computed hash into items whose frozen_hash is
#   empty or a placeholder (<sha256...>); never overwrites a
#   recorded hash - drift is for --verify to surface, not to hide.
# --compute: print the hash for one item, no writes.
set -euo pipefail
CANON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
RM="$CANON_DIR/roadmap.md"

MODE=""; ITEM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verify|--fill|--compute) MODE=$1; shift;;
    --item) ITEM=$2; shift 2;;
    *) echo "usage: roadmap_hash.sh --verify|--fill|--compute [--item <slug>]" >&2; exit 2;;
  esac
done
[ -n "$MODE" ] || { echo "usage: roadmap_hash.sh --verify|--fill|--compute [--item <slug>]" >&2; exit 2; }
[ "$MODE" = "--compute" ] && [ -z "$ITEM" ] && { echo "roadmap_hash: --compute needs --item" >&2; exit 2; }
[ -f "$RM" ] || { echo "roadmap_hash: $RM missing" >&2; exit 1; }

MODE="${MODE#--}" RM="$RM" ITEM="$ITEM" python3 - <<'PY'
import hashlib, os, re, sys

rm_path, mode, want = os.environ["RM"], os.environ["MODE"], os.environ["ITEM"]
# additional_acceptance_notes is mutable state the Architecture
# Committee appends AFTER freeze (§4.4a) - including any deeper-
# indented continuation lines of its value block.
MUTABLE = re.compile(
    r"^\s*-\s*(status|pr|issue|frozen_hash|additional_acceptance_notes)\s*:")
FH = re.compile(r"^(\s*-\s*frozen_hash\s*:\s*)(.*)$")
ITEM_RE = re.compile(r"(?m)^##\s+Item\s*:\s*(\S+)\s*$")
PLACEHOLDER = re.compile(r"^<.*>$|^-$|^(sha256)?$")

lines = open(rm_path, encoding="utf-8").read().split("\n")
# item blocks: from `## Item: <slug>` to the next `## ` heading.
marks = [(i, ITEM_RE.match(l).group(1))
         for i, l in enumerate(lines) if ITEM_RE.match(l)]
blocks = []
for k, (start, slug) in enumerate(marks):
    end = marks[k + 1][0] if k + 1 < len(marks) else len(lines)
    for j in range(start + 1, end):
        if lines[j].startswith("## "):
            end = j
            break
    blocks.append((start, end, slug))

def canon_hash(block_lines):
    kept = []
    skip_ind = None
    for l in block_lines:
        s = l.strip()
        ind = len(l) - len(l.lstrip())
        if skip_ind is not None:
            # Deeper-indented lines belong to the mutable field's
            # value block (e.g. a multi-line notes scalar); a blank
            # line inside that block is skipped too.
            if not s or ind > skip_ind:
                continue
            skip_ind = None
        if MUTABLE.match(l):
            skip_ind = ind
            continue
        kept.append(l.rstrip())
    while kept and kept[-1] == "":
        kept.pop()
    return hashlib.sha256("\n".join(kept).encode()).hexdigest()

def cur_hash(start, end):
    for l in lines[start:end]:
        m = FH.match(l)
        if m:
            v = (m.group(2) or "").strip()
            if not PLACEHOLDER.match(v):
                return v
    return None

rc = 0
for start, end, slug in blocks:
    if want and slug != want:
        continue
    blk = lines[start:end]
    computed = canon_hash(blk)
    recorded = cur_hash(start, end)
    if mode == "compute":
        print(computed); sys.exit(0)
    if mode == "verify":
        if recorded is None:
            # fail-closed: an unfrozen (or field-deleted) item means
            # the plan was never frozen or was tampered with.
            print(f"roadmap_hash: UNFROZEN item '{slug}': no recorded "
                  f"frozen_hash - run --fill via the freeze flow")
            rc = 1
            continue
        if recorded != computed:
            print(f"roadmap_hash: DRIFT item '{slug}': recorded {recorded[:16]}.. != computed {computed[:16]}..")
            rc = 1
    elif mode == "fill":
        if recorded is not None:
            continue
        done = False
        for j in range(start, end):
            m = FH.match(lines[j])
            if m:
                lines[j] = f"{m.group(1)}{computed}"
                done = True
                break
        if done:
            print(f"roadmap_hash: filled frozen_hash for '{slug}': {computed[:16]}..")
        else:
            print(f"roadmap_hash: item '{slug}' lacks a frozen_hash field - cannot fill", file=sys.stderr)

if mode == "verify" and want and not any(s == want for _, _, s in blocks):
    print(f"roadmap_hash: item '{want}' not found", file=sys.stderr); sys.exit(2)
if mode == "fill":
    with open(rm_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
if mode == "verify" and rc == 0:
    print("roadmap_hash: all recorded frozen_hash values verified")
sys.exit(rc)
PY
