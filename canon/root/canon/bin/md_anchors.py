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
    marker is NOT part of the slug - it is a separate anchor."""
    heading = CUSTOM_ID_RE.sub("", heading)
    return PUNCT_RE.sub("", heading.strip().lower()).replace(" ", "-")


def strip_fenced(body):
    """Remove fenced code blocks (``` and ~~~) - headings inside them
    are not anchors and links inside them are not live links."""
    body = re.sub(r"```[\s\S]*?```", "", body)
    return re.sub(r"~~~[\s\S]*?~~~", "", body)


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
    for l in body.splitlines():
        if l.startswith("#"):
            h = gh_anchor(l.lstrip("# ").strip())
            n = seen.get(h, 0)
            seen[h] = n + 1
            anchors.add(h if n == 0 else "%s-%d" % (h, n))
    anchors |= set(HTML_ANCHOR_RE.findall(body))
    anchors |= set(CUSTOM_ID_INNER.findall(body))
    return {a.lower() for a in anchors}
