#!/usr/bin/env python3
"""Inject a table-style legend below a rendered mermaid SVG.

Legend content is keyed by diagram name (from the file path) and locale
(en/ru from the docs/<lang>/ parent dir). Re-running restores the original
viewBox and replaces the previous LEGEND group — idempotent.

Usage: diagram_legend.py <svg_path> [svg_path ...]
"""
import re
import sys

FONT = "trebuchet ms,verdana,arial,sans-serif"
ROW_H = 24
SEC_H = 30
PAD = 22
COL_W = 520

# kind = (sample_kind, params, text) tuples per section
LEGENDS = {
    "item_lifecycle": {
        "title": {"en": "LEGEND", "ru": "ЛЕГЕНДА"},
        "cols": {
            "en": [
                ("NODES", [
                    ("node", ("#f5e6c8", "#8a6d1f"), "Human — supreme arbiter; acts only via signed envelope"),
                    ("node", ("#fde2e2", "#aa3333"), "Blocking gate — judge verdict / panel / merge decision"),
                    ("node", ("#e3f0ff", "#3366aa"), "Mechanical check — Gate 0, scope, floors, blood-sign"),
                    ("node", ("#ECECFF", "#9370DB"), "Process step / artifact"),
                ]),
                ("LINES", [
                    ("line", ("#333333", 2, None), "Main flow — required step"),
                    ("line", ("#333333", 2, "4 3"), "Conditional — retry / escalation / human touchpoint"),
                    ("sub", None, "Cluster box — lifecycle phase (1..5)"),
                ]),
            ],
            "ru": [
                ("УЗЛЫ", [
                    ("node", ("#f5e6c8", "#8a6d1f"), "Человек — верховный арбитр; только через конверт"),
                    ("node", ("#fde2e2", "#aa3333"), "Блокирующий гейт — вердикт судьи / панель / мерж"),
                    ("node", ("#e3f0ff", "#3366aa"), "Механическая проверка — Gate 0, scope, этажи, blood-sign"),
                    ("node", ("#ECECFF", "#9370DB"), "Шаг процесса / артефакт"),
                ]),
                ("ЛИНИИ", [
                    ("line", ("#333333", 2, None), "Основной поток — обязательный шаг"),
                    ("line", ("#333333", 2, "4 3"), "Условный — ретрай / эскалация / касание человека"),
                    ("sub", None, "Рамка-кластер — фаза жизненного цикла (1..5)"),
                ]),
            ],
        },
        "notation": {
            "en": [
                "👨‍💻 = human signature required (ssh-sig envelope, never text)",
                "⚖️ = frozen contract sha is the only benchmark",
                ".changes fragment = travel papers · gate_run = attestation record",
            ],
            "ru": [
                "👨‍💻 = требуется подпись человека (ssh-sig конверт, никогда текст)",
                "⚖️ = единственный эталон — sha замороженного контракта",
                "фрагмент .changes = сопроводительный · gate_run = запись аттестации",
            ],
        },
    },
    "cycle_structure": {
        "title": {"en": "LEGEND", "ru": "ЛЕГЕНДА"},
        "cols": {
            "en": [
                ("NODES", [
                    ("node", ("#f5e6c8", "#8a6d1f"), "Human — arbiter; key stays in ssh-agent, off workspace"),
                    ("node", ("#e8e0f5", "#5b4a8a"), "Reviewer — sits outside both committees"),
                    ("node", ("#eef7ee", "#3a7a3a"), "Artifact / journal / envelope store"),
                    ("node", ("#ECECFF", "#9370DB"), "Agent role (LLM session)"),
                    ("node", ("#ECECFF", "#9370DB", "4 4"), "Partner — external model reached via gateway"),
                ]),
                ("LINES", [
                    ("line", ("#333333", 2, None), "Owned flow — report / artifact / command"),
                    ("line", ("#333333", 2, "4 3"), "Consult / attestation / envelope decision"),
                    ("sub", None, "Cluster box — committee / trust domain"),
                ]),
            ],
            "ru": [
                ("УЗЛЫ", [
                    ("node", ("#f5e6c8", "#8a6d1f"), "Человек — арбитр; ключ в ssh-agent, вне workspace"),
                    ("node", ("#e8e0f5", "#5b4a8a"), "Рецензент — вне обоих комитетов"),
                    ("node", ("#eef7ee", "#3a7a3a"), "Хранилище — артефакт / журнал / конверт"),
                    ("node", ("#ECECFF", "#9370DB"), "Роль агента (LLM-сессия)"),
                    ("node", ("#ECECFF", "#9370DB", "4 4"), "Партнёр — внешняя модель через шлюз"),
                ]),
                ("ЛИНИИ", [
                    ("line", ("#333333", 2, None), "Свой поток — отчёт / артефакт / команда"),
                    ("line", ("#333333", 2, "4 3"), "Консультация / аттестация / конверт решения"),
                    ("sub", None, "Рамка-кластер — комитет / домен доверия"),
                ]),
            ],
        },
        "notation": {
            "en": [
                "Gateway brokers every partner call (quota + inflight reaper + journal)",
                "Human input reaches the system only as a signed envelope",
            ],
            "ru": [
                "Любой вызов партнёра идёт через шлюз (квота + reaper + журнал)",
                "Ввод человека доходит только в виде подписанного конверта",
            ],
        },
    },
    "code_design": {
        "title": {"en": "LEGEND", "ru": "ЛЕГЕНДА"},
        "cols": {
            "en": [
                ("NODES", [
                    ("node", ("#eef7ee", "#3a7a3a"), "Store — config / journal / state file"),
                    ("node", ("#fde2e2", "#aa3333"), "Gate script — blocks the flow on failure"),
                    ("node", ("#f5e6c8", "#8a6d1f"), "Security-critical — integrity check / exec sandbox"),
                    ("node", ("#eeeeee", "#555555", "4 4"), "External system — forge CLI / ssh / partners"),
                    ("node", ("#ECECFF", "#9370DB"), "Script / component"),
                ]),
                ("LINES", [
                    ("line", ("#333333", 2, None), "Call / produces / owns"),
                    ("line", ("#333333", 2, "4 3"), "Gate 0 guard («first line») / config read / attestation"),
                    ("sub", None, "Cluster box — subsystem layer"),
                ]),
            ],
            "ru": [
                ("УЗЛЫ", [
                    ("node", ("#eef7ee", "#3a7a3a"), "Хранилище — конфиг / журнал / файл состояния"),
                    ("node", ("#fde2e2", "#aa3333"), "Скрипт-гейт — блокирует поток при сбое"),
                    ("node", ("#f5e6c8", "#8a6d1f"), "Критично для безопасности — целостность / exec-песочница"),
                    ("node", ("#eeeeee", "#555555", "4 4"), "Внешняя система — forge CLI / ssh / партнёры"),
                    ("node", ("#ECECFF", "#9370DB"), "Скрипт / компонент"),
                ]),
                ("ЛИНИИ", [
                    ("line", ("#333333", 2, None), "Вызов / производит / владеет"),
                    ("line", ("#333333", 2, "4 3"), "Защита Gate 0 («первая строка») / чтение конфига / аттестация"),
                    ("sub", None, "Рамка-кластер — слой подсистемы"),
                ]),
            ],
        },
        "notation": {
            "en": [
                "Every gate runs Gate 0 first — manifest sha256 + external stamp + adapter pins",
                "Agents exec only via canon/bin; project commands run through project_run.sh",
            ],
            "ru": [
                "Каждый гейт начинается с Gate 0 — sha256 манифеста + внешний штамп + пины адаптеров",
                "Агенты исполняют только canon/bin; команды проекта — через project_run.sh",
            ],
        },
    },
}


def sample_svg(kind, params, x, y):
    sw, sh = 90, 16
    cy = y + (ROW_H - sh) / 2
    if kind == "node":
        f, s = params[0], params[1]
        dash = params[2] if len(params) > 2 else None
        d = f' stroke-dasharray="{dash}"' if dash else ""
        return (f'<rect x="{x}" y="{cy}" width="{sw}" height="{sh}" '
                f'fill="{f}" stroke="{s}" stroke-width="2"{d} rx="3"/>')
    if kind == "line":
        c, w, dash = params
        d = f' stroke-dasharray="{dash}"' if dash else ""
        ly = y + ROW_H / 2
        return (f'<line x1="{x}" y1="{ly}" x2="{x + sw}" y2="{ly}" '
                f'stroke="{c}" stroke-width="{w}"{d}/>')
    if kind == "sub":
        return (f'<rect x="{x}" y="{cy - 2}" width="{sw}" height="{sh + 4}" '
                f'fill="#f5f5f0" stroke="#999988" stroke-width="1.5" rx="4"/>')
    return ""


def column_svg(rows, title, x, y):
    out = [f'<text x="{x}" y="{y + 18}" font-size="15" font-weight="bold" '
           f'fill="#333">{title}</text>']
    ry = y + SEC_H
    for kind, params, text in rows:
        out.append(sample_svg(kind, params, x, ry))
        out.append(f'<text x="{x + 104}" y="{ry + 17}" font-size="12.5" '
                   f'fill="#222">{text}</text>')
        ry += ROW_H
    return "".join(out), ry


def notation_svg(lines, title, x, y):
    out = [f'<text x="{x}" y="{y + 18}" font-size="15" font-weight="bold" '
           f'fill="#333">{title}</text>']
    ry = y + SEC_H
    for text in lines:
        out.append(f'<text x="{x}" y="{ry + 14}" font-size="12.5" '
                   f'fill="#222">· {text}</text>')
        ry += ROW_H
    return "".join(out), ry


def detect(path):
    base = path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    m = re.search(r"(?:^|/)docs/(en|ru)/", path)
    return base, (m.group(1) if m else "en")


def inject_legend(svg, kind, lang):
    spec = LEGENDS[kind]
    svg = re.sub(r'<g id="LEGEND".*?</g>\s*</svg>', "</svg>", svg, flags=re.S)
    orig = re.search(r'data-pp-orig-viewbox="([\d. ]+)"', svg)
    m = re.search(r'viewBox="([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)"', svg)
    if orig:
        svg = svg.replace(m.group(0), f'viewBox="{orig.group(1)}"', 1)
        m = re.search(r'viewBox="([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)"', svg)
    vx, vy, vw, vh = map(float, m.groups())

    lx, ly = 30, vy + vh + 30
    cols = spec["cols"][lang]
    legend_w = COL_W * len(cols) + PAD * 2

    parts, ends = [], []
    for i, (title, rows) in enumerate(cols):
        s, e = column_svg(rows, title, lx + PAD + i * COL_W, ly + 44)
        parts.append(s)
        ends.append(e)
    s, e = notation_svg(
        spec["notation"][lang], "NOTATION" if lang == "en" else "ОБОЗНАЧЕНИЯ",
        lx + PAD + len(cols) * COL_W, ly + 44)
    parts.append(s)
    ends.append(e)
    legend_w = COL_W * (len(cols) + 1) + PAD * 2

    legend_h = max(ends) - ly + PAD
    box = (f'<g id="LEGEND" font-family="{FONT}">'
           f'<rect x="{lx}" y="{ly}" width="{legend_w}" height="{legend_h}" '
           f'fill="#ffffff" stroke="#616161" stroke-width="2" rx="4"/>'
           f'<text x="{lx + legend_w / 2}" y="{ly + 30}" font-size="19" '
           f'font-weight="bold" text-anchor="middle" fill="#111">'
           f'{spec["title"][lang]}</text>'
           f'{"".join(parts)}</g>')

    new_vh = ly + legend_h + 20 - vy
    svg = svg.replace(
        m.group(0),
        f'viewBox="{vx} {vy} {max(vw, lx + legend_w + 20)} {new_vh}"')
    if not orig:
        svg = svg.replace(
            "<svg ", f'<svg data-pp-orig-viewbox="{vx} {vy} {vw} {vh}" ', 1)
    return svg.replace("</svg>", box + "</svg>")


def main():
    for path in sys.argv[1:]:
        kind, lang = detect(path)
        if kind not in LEGENDS:
            print(f"skip {path}: no legend spec")
            continue
        svg = open(path, encoding="utf-8").read()
        open(path, "w", encoding="utf-8").write(inject_legend(svg, kind, lang))
        print(f"legend injected: {path}")


if __name__ == "__main__":
    main()
