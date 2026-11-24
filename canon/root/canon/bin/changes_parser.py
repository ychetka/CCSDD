# changes_parser.py - the ONE parser for .changes/*.md fragments.
#
# Five scripts used to carry five slightly different copies of this
# front-zone extraction, and the differences were exploitable: a
# comment line could terminate parsing before `manual_gate: true`,
# and 'issue: [#10, #11]' parsed in one gate but not another.
#
# Contract (kept identical to spec_anchor_check's documented zone):
#   * optional '---' fence at line 1 opens a YAML-ish frontmatter
#     block that ends at the next '---' line;
#   * without a fence the front zone is the leading run of
#     'key: value' / blank / comment lines - it ends at the first
#     other line (a '# header' IS a header here, not a comment -
#     comments are only legal INSIDE a fenced block);
#   * keys are lowercase words; values are returned with one layer
#     of surrounding quotes stripped ('user_visible: "false"' ->
#     'false') - callers compare against literal tokens.
#
# Usage as a library:
#   sys.path.insert(0, os.path.join(os.environ["CANON_DIR"], "bin"))
#   from changes_parser import front_fields, issue_numbers, is_true
import re

_KEY = re.compile(r"^\s*([a-z_]+)\s*:\s*(.*?)\s*$")


def strip_quotes(value):
    return str(value or "").strip().strip('"').strip("'")


def front_fields(body):
    """Fragment front zone -> {key: value}.

    Fenced form ('---' first line): every line until the closing
    '---' is scanned; blank lines and '#' comment lines are skipped.
    Unfenced form: the leading run of 'key: value' lines (blank
    lines and '#'-comment lines between fields are tolerated ONLY
    until the first real header or prose line).
    """
    fields = {}
    lines = body.splitlines()
    if not lines:
        return fields
    if lines[0].strip() == "---":
        for ln in lines[1:]:
            s = ln.strip()
            if s == "---":
                break
            m = _KEY.match(ln)
            if m:
                fields[m.group(1)] = strip_quotes(m.group(2))
            # comments/blank/prose inside the fence are inert
        return fields
    for ln in lines:
        s = ln.strip()
        if not s:
            continue  # blank lines inside the front zone are inert
        if s.startswith("#"):
            break      # markdown header - front zone is over
        m = _KEY.match(ln)
        if not m:
            break      # first prose line ends the zone
        fields[m.group(1)] = strip_quotes(m.group(2))
    return fields


def issue_numbers(value):
    """'10', '#10', '[10, 11]', '"10"', '10 # comment' -> [int,...].

    The trailing '# words' form is a comment ONLY when digits have
    already been seen ('issue: 10 # main task'); a bare '#10' is a
    GitHub-style ref, not a comment.
    """
    v = (value or "").strip()
    # Drop a trailing free-text comment only when it is NOT a ref:
    # '#10' is a GitHub ref, '# task' is prose.
    v = re.sub(r"\s+#\s*[^\d#].*$", "", v, count=1)
    return sorted({int(n) for n in re.findall(r"#?(\d+)", v)})


def is_true(value):
    return strip_quotes(value).lower() in ("true", "yes", "1")


# --- roadmap.md '## Item:' meta fields --------------------------------
# One contract for roadmap_hash.sh, epic_merge.sh and
# verify_constraints.sh - they used to parse the same block three
# incompatible ways (contiguous-only vs whole-block incl. fenced
# code examples, which both spoofed `- status:`/`- risk_flags:` out
# of prose and hid real fields behind continuation lines).
_ITEM_HEAD = re.compile(r"^##\s+Item\s*:", re.I)
_FIELD = re.compile(r"^\s*-\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*?)\s*$")
_HEADING = re.compile(r"^#{1,6}\s")
_FENCE = re.compile(r"^\s*(`{3,}|~{3,})")


def _item_zone(lines):
    """Yield (i, kind, key, value) for each line of the header zone.

    kind 'field' -> '- key: value' line; kind 'cont' -> an indented
    continuation line or a deeper-indented nested '- bullet' (value
    = stripped text, key = None). Blank lines, '# comment' lines and
    fenced-code content are transparent (not yielded). The iterator
    stops at the first line that ends the zone: a markdown heading
    or a non-indented line that is none of the above.
    """
    fchar = flen = None
    for i, ln in enumerate(lines[1:], start=1):
        s = ln.strip()
        if fchar:
            if set(s) <= {fchar} and len(s) >= flen:
                fchar = None
            continue
        fm = _FENCE.match(ln)
        if fm:
            fchar, flen = fm.group(1)[0], len(fm.group(1))
            continue
        if _HEADING.match(ln):
            return                    # next section - zone over
        if not s or s.startswith("#"):
            continue                  # blank line / comment
        # Meta fields are column-0 bullets per roadmap.template.md;
        # a deeper-indented '- key: v' belongs to a nested list
        # under the previous field ('- research_questions:' style),
        # it is continuation content, not a declaration.
        m = _FIELD.match(ln) if ln[0] == "-" else None
        if m:
            yield (i, "field", m.group(1).lower(), m.group(2))
            continue
        if ln[0] in (" ", "\t"):
            yield (i, "cont", None, s)
            continue                  # continuation / nested bullet
        return                        # prose line ends the header zone


def item_fields(block):
    """Meta '- key: value' fields of one '## Item:' roadmap block.

    Header zone = from the '## Item: <slug>' line to the first
    '### '/'## ' heading. Inside the zone: fenced code blocks are
    transparent, blank lines, '# comment' lines and deeper-indented
    continuation lines of a field value are skipped; the zone ends
    at the first non-indented line that is none of the above. A
    '- k: v' bullet inside prose or a code fence never counts as a
    field. Values keep raw text (callers strip []/# comments).
    """
    lines = block.splitlines()
    if not lines:
        return {}
    if _ITEM_HEAD.match(lines[0]):
        pass                          # lines[0] is the title - skipped
    elif not (lines[0].startswith("-") and _FIELD.match(lines[0])):
        # Block passed without its heading line: the title remainder
        # (' <slug>') is an indented continuation - skip it.
        lines = lines[1:]
    else:
        # Block starting directly on a field line: _item_zone skips
        # lines[0] as the title, so re-emit it manually.
        fields = {}
        m = _FIELD.match(lines[0])
        fields[m.group(1).lower()] = m.group(2)
        fields.update({k: v for _, kind, k, v in _item_zone(lines)
                       if kind == "field"})
        return fields
    return {k: v for _, kind, k, v in _item_zone(lines)
            if kind == "field"}


def item_field_lines(lines):
    """[(index_in_lines, key, value)] for header-zone field lines.

    Same zone contract as item_fields but reports the physical line
    positions - roadmap_hash --fill needs them to rewrite
    '- frozen_hash: <placeholder>' in place. `lines` starts AT the
    '## Item:' line (index 0 = heading).
    """
    return [(i, k, v) for i, kind, k, v in _item_zone(lines)
            if kind == "field"]


def item_zone(lines):
    """Public form of _item_zone: [(i, 'field'|'cont', key, value)].

    Callers needing the nested-list form (`- risk_flags:` followed
    by deeper-indented '- flag' bullets) inspect 'cont' entries;
    lines[0] is the '## Item:' heading (skipped).
    """
    return list(_item_zone(lines))
