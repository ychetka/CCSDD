---
name: hygiene
description: Deterministic gate of outgoing texts (canon/bin/hygiene_check.sh) — not an agent and not an LLM, mechanics inside the ship_*/repo_* publish wrappers. Catches attribution, secrets, language, forbidden paths; rejects, never rewrites.
---

# hygiene — deterministic gate of outgoing texts

Module: canon/bin/hygiene_check.sh. This is NOT an agent and NOT
an LLM — mechanics inside the publish wrappers (ship_*, repo_*).

## What it catches (classes, not strings)

- attribution/advertising: Generated with, Co-Authored-By,
  Signed-off-by from tools, AI/tool names in sign-off, emoji
  footers
- secrets: tokens, keys, pem blocks, password patterns
- language: Cyrillic when repo_language=en (default; explicit opt-out
  via repo_language in canon/project.json)
- license headers: missing in new files where required
- forbidden files/paths in the published change

## Contract

stdin (text) or --diff-base <ref> (diff) -> exit 0 + silence, or
exit 1 + JSON {violations: [{class, line, hint}]}

## Semantics

- Fail closed: crash/timeout/missing script = publication blocked.
- Reject, not rewrite: violations are returned to the calling
  agent; the text is fixed by whoever knows the meaning
  (session/author).
- Rules are class-based: a new form of advertising is caught by
  category, not by an exact string.
