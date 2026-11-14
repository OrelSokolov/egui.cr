#!/usr/bin/env python3
"""Browser twin of bench/widgets_bench.cr: the SAME 19 cases (1000
static elements each, scrollable) as plain web pages with an FPS
counter — the oracle a browser sets for the same workload.

  python3 bench/browser/browser_bench.py            # generate bench/browser/*.html
  python3 bench/browser/browser_bench.py --run      # headless chrome, sorted report

Generated pages:
  case-01-label.html … case-19-nested.html — open one, scroll it, the
  HUD (top-right) shows the live rAF fps. ?auto=1 scrolls by itself.
  index.html — links to every case in one place.

Headless `--run` mode measures per-frame CPU (style+layout after a
scroll step, forced synchronously — the browser's analogue of our
pre-FFI ms/frame) and prints the report sorted by load, same format
as the Crystal bench.
"""

import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

N = int(os.environ.get("N", "1000"))
FRAMES = int(os.environ.get("FRAMES", "300"))

# (file slug, case name, js kind) — mirrors the Crystal DSL cases.
CASES = [
    ("label",     "1000 × label — обычные строки"),
    ("h1",        "1000 × h1 — крупный текст"),
    ("rich",      "1000 × rich — цвет/размер"),
    ("div",       "1000 × div — плоская заливка"),
    ("gradient",  "1000 × градиент — linear-gradient"),
    ("button-v",  "1000 × кнопка (в высоту)"),
    ("button-row","1000 × кнопка (в ряд, wrap)"),
    ("flex-row",  "1000 × flex-строка (3 ребёнка)"),
    ("card",      "1000 × карточка (fill+stroke+скругление)"),
    ("checkbox",  "1000 × checkbox"),
    ("radio",     "1000 × radio"),
    ("toggle",    "1000 × toggle-switch"),
    ("slider",    "1000 × slider"),
    ("progress",  "1000 × progress"),
    ("separator", "1000 × separator"),
    ("text-edit", "1000 × text_edit"),
    ("combo",     "1000 × combo"),
    ("svg",       "1000 × svg-иконка 16×16"),
    ("nested",    "1000 × nested box (box в box)"),
]

SVG_ICON = (
    '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" '
    'stroke="currentColor" stroke-width="2" stroke-linecap="round" '
    'stroke-linejoin="round"><polyline points="22 12 18 12 15 21 '
    '9 3 6 12 2 12"/></svg>'
)

PAGE = """<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<title>%(title)s</title>
<style>
  html, body { margin: 0; height: 100%%; }
  #scroll { height: 100vh; overflow-y: auto; font: 14px/1.45 system-ui, sans-serif; color: #e8e8e8; background: #16171a; padding: 8px; box-sizing: border-box; }
  button { margin: 2px 0; }
  .row { display: flex; flex-wrap: wrap; gap: 4px; }
  .flexrow { display: flex; align-items: center; gap: 8px; margin: 2px 0; }
  .flexrow .grow { flex: 1 1 0; }
  .divbox { background: rgba(40,44,52,1); height: 26px; line-height: 26px; margin: 2px 0; padding-left: 4px; }
  .gradbox { background: linear-gradient(135deg, #E92236 0%%, #571DCC 60%%, #26C6DA 100%%); height: 26px; line-height: 26px; margin: 2px 0; padding-left: 4px; }
  .card { background: rgba(32,36,44,1); border: 1px solid rgba(70,76,88,1); border-radius: 8px; padding: 6px 8px; margin: 4px 0; display: flex; align-items: center; gap: 8px; }
  .card .grow { flex: 1 1 0; }
  .outer { background: rgba(40,44,52,1); padding: 4px; margin: 2px 0; }
  .mid { border: 1px solid rgba(80,86,98,1); padding: 4px; }
  .inner { color: #ccc; }
  .switch { position: relative; width: 34px; height: 18px; }
  .switch input { opacity: 0; width: 0; height: 0; }
  .switch .tr { position: absolute; inset: 0; background: #444; border-radius: 9px; transition: .15s; }
  .switch .tr:after { content: ""; position: absolute; width: 14px; height: 14px; border-radius: 50%%; background: #ddd; top: 2px; left: 2px; transition: .15s; }
  .switch input:checked + .tr { background: #2f7d4f; }
  .switch input:checked + .tr:after { left: 18px; }
  .opt { display: flex; align-items: center; gap: 6px; margin: 2px 0; }
  input[type=text], select { margin: 2px 0; }
  h1 { font-size: 1.7em; margin: 8px 0; }
  hr { margin: 6px 0; }
  #hud { position: fixed; top: 8px; right: 8px; z-index: 999; background: rgba(16,16,24,.85); color: #7de6a0; font: 13px/1.4 ui-monospace, monospace; padding: 6px 10px; border-radius: 6px; border: 1px solid #5a5a6e; pointer-events: none; }
  #hud .dim { color: #9696a5; }
</style>
</head>
<body>
<div id="scroll"></div>
<div id="hud"><span id="fps">— fps</span><br><span class="dim" id="ms"></span></div>
<script>
const KIND = %(kind)r, N = %(n)d;

const scroll = document.getElementById('scroll');
const frag = document.createDocumentFragment();
const el = (tag, attrs, html) => {
  const e = document.createElement(tag);
  if (attrs) for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (html != null) e.innerHTML = html;
  return e;
};
for (let i = 0; i < N; i++) {
  switch (KIND) {
    case 'label':     frag.appendChild(el('div', null, 'Строка #' + i + ' — обычный текст')); break;
    case 'h1':        frag.appendChild(el('h1', null, 'Заголовок #' + i)); break;
    case 'rich':      frag.appendChild(el('div', null,
                        '<span style="color:rgb(' + ((i*7)%%255) + ',120,220);font-size:' + (11 + (i%%3)*4) + 'px">Цветной #' + i + '</span>')); break;
    case 'div':       frag.appendChild(el('div', {class: 'divbox'}, 'Div #' + i)); break;
    case 'gradient':  frag.appendChild(el('div', {class: 'gradbox'}, 'Градиент #' + i)); break;
    case 'button-v':  frag.appendChild(el('button', null, 'Кнопка #' + i)); break;
    case 'button-row':frag.appendChild(el('button', null, '#' + i)); break;
    case 'flex-row':  frag.appendChild(el('div', {class: 'flexrow'},
                        '<div class="grow">Строка #' + i + '</div><button>Открыть</button><div>·</div>')); break;
    case 'card':      frag.appendChild(el('div', {class: 'card'},
                        '<div class="grow">Карточка #' + i + '</div><button>⋯</button>')); break;
    case 'checkbox':  frag.appendChild(el('label', {class: 'opt'},
                        '<input type="checkbox"' + (i %% 2 == 0 ? ' checked' : '') + '>Опция #' + i)); break;
    case 'radio':     frag.appendChild(el('label', {class: 'opt'},
                        '<input type="radio" name="r"' + (i == 0 ? ' checked' : '') + '>Вариант #' + i)); break;
    case 'toggle':    frag.appendChild(el('label', {class: 'switch'},
                        '<input type="checkbox"' + (i %% 2 == 0 ? ' checked' : '') + '><span class="tr"></span>')); break;
    case 'slider':    frag.appendChild(el('input', {type: 'range', min: 0, max: 100, value: i %% 100})); break;
    case 'progress':  frag.appendChild(el('progress', {max: 100, value: i %% 100})); break;
    case 'separator': frag.appendChild(el('hr')); break;
    case 'text-edit': frag.appendChild(el('input', {type: 'text', value: 'поле #' + i})); break;
    case 'combo':     frag.appendChild(el('select', null,
                        '<option selected>Вариант ' + (i %% 3) + '</option><option>Вариант 1</option><option>Вариант 2</option>')); break;
    case 'svg':       frag.appendChild(el('div', null, %(svg)r)); break;
    case 'nested':    frag.appendChild(el('div', {class: 'outer'},
                        '<div class="mid"><div class="inner">Вложенный #' + i + '</div></div>')); break;
  }
}
if (KIND == 'button-row') {
  const row = el('div', {class: 'row'});
  row.appendChild(frag);
  scroll.appendChild(row);
} else {
  scroll.appendChild(frag);
}

// FPS HUD: rAF deltas over a sliding window.
const fpsEl = document.getElementById('fps'), msEl = document.getElementById('ms');
let last = performance.now(), dts = [];
function hud(t) {
  dts.push(t - last); last = t;
  if (dts.length > 60) dts.shift();
  if (dts.length > 10) {
    const mean = dts.reduce((a, b) => a + b, 0) / dts.length;
    fpsEl.textContent = Math.round(1000 / mean) + ' fps';
    msEl.textContent = mean.toFixed(2) + ' ms/frame';
  }
  if (AUTO) {
    scroll.scrollTop += 6;
    if (scroll.scrollTop + scroll.clientHeight >= scroll.scrollHeight) scroll.scrollTop = 0;
  }
  requestAnimationFrame(hud);
}
const AUTO = new URLSearchParams(location.search).get('auto') == '1';
requestAnimationFrame(hud);

// ?measure=1 — headless, two measurements per case:
//   scroll  — scrollTop step + forced reflow. A browser pays ~0
//             here: scrolling is compositor-side, layout stays clean.
//             (The number our engine must approach.)
//   reflow  — full layout invalidate per frame (container width
//             toggles ±1px), the browser's equivalent of our
//             "rebuild all 1000 widgets every frame".
// Result goes to <pre id="result"> (dump-dom picks it up) and console.
if (new URLSearchParams(location.search).get('measure') == '1') {
  const stats = (times) => {
    times.sort((a, b) => a - b);
    return {p50: times[times.length >> 1],
            mean: times.reduce((a, b) => a + b, 0) / times.length,
            p95: times[Math.floor(times.length * .95)],
            max: times[times.length - 1]};
  };
  const tsScroll = [], tsReflow = [];
  for (let f = 0; f < %(frames)d; f++) {
    scroll.scrollTop += 4;
    if (scroll.scrollTop + scroll.clientHeight >= scroll.scrollHeight) scroll.scrollTop = 0;
    let t0 = performance.now();
    scroll.offsetHeight; // force style+layout NOW
    tsScroll.push(performance.now() - t0);
    scroll.style.paddingRight = (f %% 2 ? '9px' : '8px'); // dirty EVERYTHING
    t0 = performance.now();
    scroll.offsetHeight;
    tsReflow.push(performance.now() - t0);
  }
  const res = {kind: KIND, n: N, frames: tsScroll.length,
               scroll: stats(tsScroll), reflow: stats(tsReflow)};
  const pre = document.createElement('pre');
  pre.id = 'result'; pre.textContent = JSON.stringify(res);
  document.body.appendChild(pre);
  console.log('BENCH ' + JSON.stringify(res));
}
</script>
</body>
</html>
"""

INDEX = """<!DOCTYPE html>
<html lang="ru"><head><meta charset="utf-8"><title>widgets bench</title>
<style>body{background:#16171a;color:#e8e8e8;font:14px system-ui,sans-serif;padding:16px}a{color:#7ab0f0;line-height:1.9}</style>
</head><body>
<b>widgets bench — %(n)d элементов на страницу</b><br>
<span style="color:#9696a5">открыть страницу и скроллить; ?auto=1 — автоскролл</span><br>
%(links)s
</body></html>
"""


def generate():
    links = []
    for i, (slug, title) in enumerate(CASES, 1):
        html = PAGE % {
            "title": title, "kind": slug, "n": N,
            "frames": FRAMES, "svg": SVG_ICON,
        }
        path = os.path.join(HERE, "case-%02d-%s.html" % (i, slug))
        with open(path, "w", encoding="utf-8") as f:
            f.write(html)
        links.append('<a href="case-%02d-%s.html">%s</a><br>' % (i, slug, title))
    with open(os.path.join(HERE, "index.html"), "w", encoding="utf-8") as f:
        f.write(INDEX % {"n": N, "links": "\n".join(links)})
    print("generated %d cases + index.html into %s" % (len(CASES), HERE))


def chrome_bin():
    for c in ("google-chrome-stable", "google-chrome", "chromium-browser", "chromium"):
        p = shutil.which(c)
        if p:
            return p
    sys.exit("no chrome/chromium found in PATH")


def run():
    exe = chrome_bin()
    results = []
    for i, (slug, title) in enumerate(CASES, 1):
        path = os.path.join(HERE, "case-%02d-%s.html" % (i, slug))
        url = "file://%s?measure=1" % path
        cmd = [exe, "--headless=new", "--disable-gpu", "--no-first-run",
               "--window-size=1100,800", "--dump-dom", url]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        m = re.search(r'<pre id="result">(\{.*?\})</pre>', proc.stdout, re.S)
        print("[%d/%d] %-12s %s" % (i, len(CASES), slug, "." if m else "FAIL"), flush=True)
        if not m:
            sys.stderr.write(proc.stderr[-2000:] + "\n")
            continue
        res = json.loads(m.group(1))
        results.append((title, res))
    if not results:
        sys.exit("no results")
    print("\n== browser report — по убыванию reflow ms/frame (p50) ==")
    print("  %10s %10s  %6s  %6s  %s" % ("reflow ms", "scroll ms", "rf fps", "p95", "case"))
    results.sort(key=lambda r: -r[1]["reflow"]["p50"])
    for rank, (title, res) in enumerate(results, 1):
        p50 = res["reflow"]["p50"]
        fps = 1000.0 / p50 if p50 > 0 else 0
        print("  %2d. %8.2f %10.2f  %6d  %6.2f  %s"
              % (rank, p50, res["scroll"]["p50"], fps, res["reflow"]["p95"], title))


if __name__ == "__main__":
    if "--run" in sys.argv:
        generate()
        run()
    else:
        generate()
