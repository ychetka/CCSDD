#!/usr/bin/env python3
"""md_anchors.py - shared GitHub-Flavored-Markdown anchor/link logic.

Single implementation consumed by docs_check.sh, spec_anchor_check.sh
and any other markdown gate - two private copies of the slugger and
the link parser drifted before (fence sets, {#id} handling, titled
links); one module keeps every boundary identical by construction.

Slug rules follow github-slugger:
  lowercase -> drop punctuation (unicode word chars, '-' and ' '
  kept) -> spaces become '-'; duplicate headings get -1, -2, ...
  '1.2 Title' slugs to '12-title' (dots removed) - same as GitHub.
Custom anchors '{#id}' and HTML <a name|id="x"> register verbatim.
"""
import re

PUNCT_RE = re.compile(r"[^\w\- ]", re.UNICODE)
CUSTOM_ID_RE = re.compile(r"\{#[^}]+\}")
CUSTOM_ID_INNER = re.compile(r"\{#([^}\s]+)\}")
HTML_ANCHOR_RE = re.compile(r'(?:name|id)\s*=\s*["\']([^"\']+)["\']')


def gh_anchor(heading):
    """GitHub slug for a heading line's text. An explicit {#custom-id}
    marker is NOT part of the slug - it is a separate anchor. ATX
    closing hashes ('## Title ##') are stripped before slugging, and
    whitespace left behind by removed punctuation is trimmed so a
    'Title!' heading slugs to 'title', never 'title-'."""
    heading = CUSTOM_ID_RE.sub("", heading)
    heading = re.sub(r"\s+#+\s*$", "", heading.strip())
    return PUNCT_RE.sub("", heading.lower()).strip().replace(" ", "-")


_FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})")


def strip_fenced(body):
    """Remove fenced code blocks - headings inside them are not
    anchors and links inside them are not live links.

    Line automaton (same contract as design_spec_check.sh /
    fidelity_check.sh): a fence opens on a leading run of >=3 of the
    SAME marker char and closes only on a run of that char with
    length >= the opening run. The lazy-regex form matched the first
    three backticks of a ```` ````markdown ```` fence against an
    inner ``` fence, unmasking the rest of the block."""
    out = []
    fchar = flen = None
    for ln in body.splitlines():
        s = ln.strip()
        if fchar is not None:
            if s and set(s) <= {fchar} and len(s) >= flen:
                fchar = None
            continue
        m = _FENCE_RE.match(ln)
        if m:
            fchar, flen = m.group(1)[0], len(m.group(1))
            continue
        out.append(ln)
    return "\n".join(out)


def strip_nonlink(body):
    """strip_fenced plus inline code spans - `[a](b)` inside `code`
    is literal text, not a link."""
    body = strip_fenced(body)
    return re.sub(r"`[^`\n]+`", "", body)


def collect_anchors(body):
    """Full anchor set of a markdown body: GitHub-style heading slugs
    (-1/-2 duplicates), <a name|id="x"> and {#custom-id}."""
    anchors = set()
    seen = {}
    # One registry for every anchor kind, consumed in document order:
    # a later '## Foo' after an earlier <a id="foo"> must get -1, and
    # a heading's own '{#id}' occupies that id before the slug lands.
    for l in body.splitlines():
        inline = []
        if l.startswith("#"):
            h = gh_anchor(l.lstrip("# ").strip())
            n = seen.get(h, 0)
            seen[h] = n + 1
            anchors.add(h if n == 0 else "%s-%d" % (h, n))
        inline += HTML_ANCHOR_RE.findall(l)
        inline += CUSTOM_ID_INNER.findall(l)
        for a in inline:
            anchors.add(a)
            seen[a] = seen.get(a, 0) + 1
    return {a.lower() for a in anchors}
