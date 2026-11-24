# CCSDD Documentation / Документация

The documentation set ships in two languages; each language folder is
self-contained (docs + diagrams).

Документация поставляется на двух языках; каждая языковая папка
самодостаточна (документы + схемы).

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
  - `.mmd` sources alongside every `.svg` (edit the source, re-render
    with `mmdc`).

## Русский — `docs/ru/`

- [README](docs/ru/README.md) — обзор продукта, укладка, быстрый старт,
  шаги деплоя, адаптеры, гейты человека.
- [methodology](docs/ru/methodology.md) — что такое CCSDD, решаемая
  задача, базовые примитивы, карта наследования (SDD, OpenSpec, SDLC,
  Agile, GitOps, SLSA, maker–checker), что сознательно не взято.
- diagrams/
  - [жизненный цикл пункта](docs/ru/diagrams/item_lifecycle.svg) — план →
    контракт → имплементация → сборка → релиз, гейты и петли эскалаций.
  - [структура цикла](docs/ru/diagrams/cycle_structure.svg) — комитеты,
    роли, границы, артефакты.
  - рядом с каждым `.svg` лежит исходник `.mmd` (править источник,
    перерендеривать через `mmdc`).

## Conventions / Конвенции

- `👨‍💻` — human gate / гейт человека; `»` — escalation / эскалация;
  `✕` — forced stop / принудительная остановка.
- Dotted arrows ending at `👨‍💻` = the decision is made by the human at
  that point / Пунктирные стрелки в `👨‍💻` = в этом месте решение
  принимает человек.
- Mermaid `.mmd` sources are authoritative; `.svg` are generated.
  Render: `mmdc -i <mmd> -o <svg>` then optionally
  `python3 svg_legend.py <svg>` (injects the table legend below the
  diagram; idempotent). `svg_legend.py` is an optional author/CI-side
  helper that lives at the *development* repository root
  (`ai_controller_2/svg_legend.py`) — it is not tracked inside this
  package; skip the step when it is absent (the SVG is valid either
  way).
  / Исходники `.mmd` первичны; `.svg` генерируются: `mmdc` +
  опционально `svg_legend.py` (табличная легенда под диаграммой;
  скрипт лежит в корне dev-репозитория `ai_controller_2`, в пакет
  не входит — при его отсутствии шаг пропускается).
