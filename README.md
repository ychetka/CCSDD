# CCSDD — Committee Cycle Spec-Driven Development

Multi-agent software delivery governed by specification, contracts and
signed human gates — English is the primary documentation language.

The documentation set ships in two languages; each language folder is
self-contained (docs + diagrams).

## English — `docs/en/`

- [README](docs/en/README.md) — product overview, layout, quick start,
  deploy steps, adapters, human gates.
- [methodology](docs/en/methodology.md) — what CCSDD is, the problem it
  solves, core primitives, inheritance map (SDD, OpenSpec, SDLC,
  Agile, GitOps, SLSA, maker–checker), what we deliberately reject.
- diagrams/
  - [item lifecycle](docs/en/diagrams/item_lifecycle.svg) — plan → contract
    → implementation → assembly → release, gates and escalation loops.
  - [cycle structure](docs/en/diagrams/cycle_structure.svg) — committees,
    roles, boundaries, artifacts.
  - [code design](docs/en/diagrams/code_design.svg) — canon component map:
    Gate 0, exec wrappers, verification gates, merge/release core.
  - `.mmd` sources alongside every `.svg` (edit the source, re-render
    with `mmdc`).

## Russian (second language) — `docs/ru/`

Russian is the secondary documentation language; it mirrors `docs/en/`
one-to-one and is not independently versioned.

- [README](docs/ru/README.md) — product overview, layout, quick start,
  deploy steps, adapters, human gates (in Russian).
- [methodology](docs/ru/methodology.md) — what CCSDD is, the problem it
  solves, core primitives, inheritance map, what we deliberately reject
  (in Russian).
- diagrams/
  - [item lifecycle](docs/ru/diagrams/item_lifecycle.svg) — the pipeline
    stages, gates and escalation loops.
  - [cycle structure](docs/ru/diagrams/cycle_structure.svg) — committees,
    roles, boundaries, artifacts.
  - [code design](docs/ru/diagrams/code_design.svg) — canon component map.
  - `.mmd` sources alongside every `.svg`.

## Conventions

- `👨‍💻` — human gate; `»` — escalation; `✕` — forced stop.
- Dotted arrows ending at `👨‍💻` = the decision is made by the human
  at that point.
- Mermaid `.mmd` sources are authoritative; `.svg` files are generated.
  Render: `mmdc -i <mmd> -o <svg> -p <puppeteer-config>`, then
  `python3 tools/diagram_legend.py <svg>` injects the table-style
  legend below the diagram (idempotent, English/Russian by path).
