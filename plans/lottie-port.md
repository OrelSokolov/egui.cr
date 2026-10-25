# Lottie → чистый Crystal: standalone-шард `lottie.cr`

Контекст: фаза 1 готова — rlottie C-shim за флагом `LOTTIE=1` (см.
`backend/rlottie_shim.c`, `backend/rlottie.cr`, `Rakefile`), реальный
контент (8 Noto-эмодзи + spinner) рендерится и прогоняется через smoke.
Этот план — фаза 2: интерпретатор Lottie на чистом Crystal как ОТДЕЛЬНЫЙ
шард (репозиторий `OrelSokolov/lottie.cr`), по образцу nanosvg.cr /
freetype.cr / highlight.cr. Критично: шард самостоятельный — не зависит
от egui.cr; egui подключает его как dependency и закрывает им seam
`Egui::Lottie::Renderer`.

## Что уже проверено (опорные факты)

- **Датасет один-к-одному существует и сгенерирован.** rlottie
  отдаёт пре-растровое дерево сцены (`lottie_animation_render_tree`,
  `vendor/rlottie/inc/rlottiecommon.h`): слои/маски/matte + ноды с
  путями, цветами, градиентами (разрешённые координаты), штрихами.
  Шим дампит его в JSON (`egui_cr_lottie_dump_tree`), 45 дампов по
  9 ассетам лежат в `spec/dataset/lottie/` — это контракт порта:
  геометрия 1:1 с эталоном с точностью до float-эпсилона, метадата
  строго. Побайтового равенства пикселей с rlottie не будет и не
  нужно (растеризаторы разные: у него свой, у нас ftgrays из
  nanosvg.cr — как у nanosvg C/Crystal-близнецов, только векторный
  уровень вместо растрового).
- **Растеризатор есть и программно доступен.** `lib/nanosvg` (шард
  nanosvg.cr) — `NanoSVG::Image`/`Shape`/`Path`/`Paint` полностью
  конструируемы (`model.cr`: properties с дефолтами), растеризация —
  `NanoSVG::Rasterizer.rasterize(image, tx, ty, scale, w, h)` →
  straight-alpha RGBA8. Тот же пиксельный контракт, что у шима.
- **Реальный сабсет измерен.** Скан 9 ассетов (assets/lottie/):
  - слои: `ty:4` (shape), `ty:3` (null/parent), `ty:0` (precomp — в
    🔥😂😢, у 6 из 9 `"assets":[]`);
  - шейпы: `sh` (path), `rc` (rect), `el` (ellipse), `gr` (group),
    `tr` (transform), `fl` (fill), `st` (stroke), `gf`/`gs` (градиенты);
  - НЕТ: `sr` (star), `tm` (trim), `rp` (repeater), `mm`/`dd`, масок,
    mattes, эффектов, текста, картинок.
- **Анимированные свойства** — включая анимированные ПУТИ (keyframes по
  вершинам/касательным `ks`) и анимированные стопы градиентов: это ядро
  работы, а не растровая часть.
- **Эталон для A/B** — rlottie-шим: метадата (w/h/fps/frames/duration)
  сверяется ТОЧНО, пиксели — с допуском (растеризаторы разные:
  rlottie свой, у нас ftgrays из nanosvg.cr; побайтовой идентичности,
 как у nanosvg C/Crystal-близнецов, здесь НЕ будет — и не надо).

## Архитектура шарда

```
src/
  lottie.cr            # public API
  lottie/
    model.cr           # Comp/Layer/ShapeItem/Property — плоские классы
    parser.cr          # JSON (stdlib JSON::Any) → model; ничего не считает
    property.cr        # Property(T): static | keyframed; sample(frame)
    interpolator.cr    # линейный, hold (h:1), cubic i/o (безье-солвер)
    evaluator.cr       # model + frame → плоский список готовых примитивов
    raster.cr          # примитивы → программная NanoSVG::Image → RGBA8
```

Public API — ровно seam `Egui::Lottie::Renderer` (но без egui-типов):

```crystal
module Lottie
  class Animation
    def self.parse(json : String) : Animation?          # nil = битый
    def width : Int32; def height : Int32
    def frame_count : Int32; def fps : Float64; def duration : Float64
    # Прямой аналог rlottie: аспект сохранён, letterbox прозрачный.
    def render(frame : Int32, buf : Bytes, w : Int32, h : Int32) : Bool
  end
end
```

Зависимости: `nanosvg` (shard). Всё остальное — stdlib (`json`, `math`).

### Конвейер кадра

1. `parser` — один раз, как NanoSVG.parse (в egui — мемоизация по
   source, как `NanoSvgCr.@@images`).
2. `evaluator.sample(frame)` — интерполяция всех Properties на момент
   кадра, раскрутка дерева: precomp → слои (снизу вверх, back-to-front;
   parenting через null-слои), группы → шейпы, матрицы 2×3
   перемножаются в путь к листу. Выход: массив
   `{paths[], fill|stroke paint, opacity, fill_rule}` в координатах
   композиции.
3. `raster` — один `NanoSVG::Image` на кадр: paths → `NanoSVG::Path`
   (bezier-сегменты — у Lottie и NanoSVG совпадающая модель
   cubic-to), градиенты → `Paint::Gradient` (пересчёт Lottie
   start/end/выделения в координаты; `p`-процентный bbox-режим
   аналогичен svg objectBoundingBox — как в `bbox_gradient_percentages`
   в nanosvg_cr.cr). `Rasterizer.rasterize` в buf.
4. Кэш: переиспользовать выделенные массивы Image/shapes между кадрами
   (clear+fill, не new) — 60 fps без GC-давления (Boehm; урок
   notepad-на-больших-файлах).

### Интерполяция (сердце порта)

`Property(T)`, где T ∈ {Float64, Vec2(с z), Vec3 цвета, PathData,
GradientStops}:

- `a:0` — статичное `k`.
- `a:1` — keyframes `[{t, s, e?, i:{x,y}, o:{x,y}, h?}]`:
  - `h:1` — hold (ступенька);
  - `i/o` — cubic-bezier контрабные точки easing'а per-компонент
    (массивы); солвер — стандартный 1-D cubic-bezier easing
    (Ньютон + бисекция, ~60 строк, пишем в шарде — готового в
    кодовой базе нет, в style_transitions только lerp/пороги);
  - многомерные свойства: у компонентов МОГУТ быть разные кривые;
  - сегмент ищется бинарно по `t` (кадры — монотонная ось).
- Отдельно: `s` с делением на `x/y`-подсвойства (позиция с разделёнными
  осями) — Noto этим пользуется, сверить при парсинге.

## Фазы (каждая заканчивается зелёным A/B против rlottie)

### A. Статика (каркас) — ✅ СДЕЛАНО
Шард `tmp/lottie.cr` (инкубация до переезда в репозиторий
OrelSokolov/lottie.cr): parser/model/property/evaluator/raster,
~1.6k строк. Метадата 9/9 строго против manifest; реплей
spinner.f0 + emoji_2764.f0 индекс-в-индекс (геометрия ≤1e-3, цвета
точно); пиксельный A/B с шимом (tmp/lottie_ab_probe.cr): Δcov
0.000, средняя Δ 0.2–0.3/255. Зафиксированные конвенции rlottie:
totalFrame = op−ip+1, duration = (op−ip)/fps (float32), цвет
(uint8)(f32·255), ноды рисуются bottom-up = reverse(документ),
замкнутый путь = n кубиков (s в keyframes путей обёрнут в массив).
Приёмка фазы A выполнена.

### B. Время — ✅ СДЕЛАНО
Keyframes + интерполяторы + анимированные пути/трансформы + parenting.
Приёмка выполнена: реплей ВСЕХ 15 дампов spinner/2764/1f44d
индекс-в-индекс (геометрия ≤1e-3, цвета точно) + пиксельный A/B
(tmp/lottie_ab_probe.cr, f0 и средние кадры: spinner f30, 2764 f55):
Δcov 0.000, средняя Δ 0.2–0.3/255. Зафиксированные семантики rlottie
(всё вычитано из lottiemodel.h / lottieparser.cpp / vinterpolator):
- сегменты: `[kf.t, next.t)`; `frame <= first.t → start`;
  `frame >= last.end → end`; последний kf: end_time = собственный t;
- пост-обработка трека при парсинге: каждый новый kf сначала чинит
  ПРЕДЫДУЩИЙ (`prev.end_time = kf.t`; если у нового есть `s` и нет
  `e` → `prev.end_value = kf.s` — e-fallback, работает и после
  hold, квирк воспроизведён); `h:1` → end_value/end_time = свои;
  kf без `i` И без `h` (терминатор) отбрасывается ПОСЛЕ фиксапа;
- интерполятор создаётся ТОЛЬКО по ключу `i` («o» сам по себе не
  считается); без интерполятора progress = 0 (не линейно!) — так и
  работают hold; VInterpolator(outTangent, inTangent): «o» первым;
- Easing = Gecko SMIL KeySpline: LUT 11 + Ньютон (4 итер.) при
  initial slope ≥ 0.02, иначе бисекция (макс 10 итер., 1e-7);
- позиция с `to`/`ti` (Value<Position>): интерполяция ПО ДУГЕ безье
  через tAtLength — бисекция с допуском 0.01 ЕДИНИЦ ДЛИНЫ, hypot —
  приближение alpha-max+beta-min (0.375, ~7% ошибки) — вся
  арифметика в Float32 портирована буквально (иначе дрейф ~0.01px);
  кэш: to/ti → абсолютные, длина ~0 → путь отключается;
- parenting: matrix = own затем parent рекурсивно (Layer::matrix);
  видимость слоя `in <= f <= out` (ВКЛЮЧИТЕЛЬНО, lottieitem.cpp);
- одна нода на paint: Fill/Stroke красит ВСЮ накопленную геометрию
  группы одним путём (конкатенация subpath'ов), paint без геометрии
  всё равно даёт пустую ноду (1f44d: stroke+fill без путей → 2
  пустые ноды); групповой `tr` парсится как layer-ks;
- скаляры в keyframes приходят массивами (`s:[0]`) — берём [0]
  (getValue(float)).

### C. Noto-покрытие — ✅ СДЕЛАНО
Precomp (`ty:0` + refId, `child_time = trunc((frame − st)/sr)`), null-слои,
parenting per-comp scope, групповой `tr`, `gf/gs` (linear+radial,
анимированные стопы), эллипс/плоский rect, дроп прозрачных paint-нод.
Приёмка выполнена: реплей ВСЕХ 45 дампов 9 ассетов индекс-в-индекс
(геометрия ≤1e-3, цвета/стопы точно) + пиксельный A/B 9/9 (f0 и
средний кадр: Δcov ≤ 0.001, средняя Δ ≤ 4.7/255 —
`tmp/lottie_ab_probe.cr`). Carve-out'ов в спеке больше нет.

Зафиксированные семантики rlottie (фаза C):

- **Бюджеты построения render-tree** (вендорный lottieitem.cpp, в
  апстриме НЕТ): `kMaxLayerNodes = 100000` и `kMaxShapeContentBudget
  = 15000`, списываются при конструировании в back-to-front порядке
  (reverse JSON), рекурсивно включая precomp-ассеты; счётчики ОБЩИЕ
  на композицию — ассет, засвеченный двумя precomp-слоями, платит
  дважды (1f622: вторая копия теряет брови и DROP 2). `cost >
  remaining` → item ВЫБРАСЫВАЕТСЯ из дерева и из растра (1f389:
  4 из 10 конфетти реально не рендерятся). `contentItemCost`:
  анимированный `sh`-путь = 1024 (kMaxPolyPoints), статический =
  число флат-точек (moveTo + 3×кубики, минимум 1), polystar
  статический = точек (clamp 1..1024), анимированный = 1024, всё
  остальное = 1. Дропы у нас per-INSTANCE (две precomp-копии шарят
  объекты модели — ключ `(instance_id, объект)`), instance-id
  выдаётся при списании и повторяется при evaluate.
- Градиенты: linear — start/end абсолютные; radial — center/focal
  (focal у всех ассетов = center), cradius через avg_scale матрицы
  (допуск их `1.41421f` ≠ √2). Стопы в дампе НЕ включают
  layer/group/paint альфу → в `resolve_gradient` alpha=1.0;
  combined opacity едет в `DrawPath.opacity`. dump `gradient.type`
  = enum (0/1), наш t (1/2) = dg.type + 1.
- Матты (растровая часть): в вендоре `hasMatte()` = слой с `tt` —
  он ВИДИМЫЙ маскируемый; паринг — «tt-слой + следующий не-tt слой
  выше него в back-to-front обходе»; `td` парсер вендора вообще не
  читает (информационный). Реализация: per-layer буферы, tt=1/3 →
  alpha ×= src.alpha (DestIn), tt=2/4 → alpha ×= (1−src.alpha)
  (DestOut), src сам не рисуется; luma (3/4) редкостны — альфа-часть
  та же.
- **Грабля NanoSVG**: `flatten_shape` идёт по `path.pts` сырым
  указателем как по ОДНОМУ subpath (x0,y0 + тройки по 3), без
  bounds-checks — второй MoveTo внутри одного Path читается как
  bezier-контролы и мусорит заливку (1f622-брови = 2 subpath).
  Каждый subpath = отдельный `NanoSVG::Path` (как C-парсер);
  в пределах слоя draws подаются reversed (первый эмитнутый draw —
  верхний, а растерайзер красит в порядке массива).
- Ellipse (addOval): moveTo на 12 часов + 4 прямых кубика без
  LineTo; плоский rect (addRect): moveTo(x+w,y) + 4 LineTo +
  close, направление обхода от `d`.
- Дроп paint-нод: Fill/Stroke с `uint8(255·alpha)==0` → skip;
  градиенты при `po.abs <= 1e-6`.
- «last-kf без e → default end value» (`default_value`):
  Float64→0, Vec2→(0,0), Color→БЕЛЫЙ (r=g=b=1), PathData/стопы→пусто.
- Датасет stateless: генератор (`scripts/make_lottie_dataset.cr`)
  строит from_data внутри цикла кадров, duration зафиксирован до
  free — регенерация воспроизводима.

### C1. Матты/градиенты в растре — ✅ (входит в C)
Растеризатор: solid/gradient fill+stroke через программную
NanoSVG-Image; градиенты → `Paint::Gradient` (linear — проекция на
ось start→end в gy, radial — концентрический unit-circle у center,
xform в координатах композиции); композитинг — src-over в
straight-alpha (целочисленный div255), матты — см. выше.

### D. Общие ассеты (после релиза C)
`tm` (trim path — спиннеры/лоды), `sr` (star/polygon), `rp`
(repeater), `dd`/`mm`. Приёмка: отдельный датасет hand-crafted JSON.

### E. Вне scope первого релиза
Маски, mattes, эффекты (`ef`), текст, изображения, expressions.
Ограничения фиксируются в README шарда (как «NanoSVG игнорирует
`<text>`» в egui).

## Верификация и тесты

- **Датасет-контракт СГЕНЕРИРОВАН** (не план — факт): 45 дампов
  геометрии + manifest лежат в `spec/dataset/lottie/`, тул —
  `scripts/make_lottie_dataset.cr` (шим: `egui_cr_lottie_dump_tree`,
  обход `lottie_animation_render_tree` → JSON). Формат дампа:
  `{"asset","frame","size","tree"}`; дерево слоёв с `keypath/alpha/
  visible/matte/masks/clip`, ноды с `path{pts,elm}` (elm — коды
  VPath::Element: 0=MoveTo, 1=LineTo, 2=CubicTo, 3=Close; каждый
  CubicTo ест 3 точки), `color`, `stroke`, `gradient` (разрешённые
  координаты + стопы), `image`. Регенерация затирает каталог —
  результат коммитится.
- **Юнит**: интерполяторы (точные значения кривых на опорных t),
  матрицы, парсер на минимальных hand-crafted JSON (по одному на фичу,
  стиль spec/lottie_spec.cr / spinner.json).
- **A/B против rlottie — реплей датасета**: метадата 9 ассетов
  (manifest.json) — строгое равенство; дерево — структурное равенство
  (число нод, keypath-ы, elm-последовательности точно); координаты —
  `|Δ| ≤ 1e-3`; цвета и стопы — округление до 1/255; штрихи точно.
- **Golden frames**: RGBA-рендеры самого порта (детерминированный
  CPU-растеризатор → побайтово воспроизводимы) в `spec/dataset/` —
  регрессия без rlottie; пиксельные допуски против шима
  (coverage ±0.02, средняя Δ ≤ 8/255) — только финальный sanity.
- **Perf-бюджет**: emoji 1024² ≤ 8 мс/кадр в --release на M-серии
  (60 fps с запасом); 128² ≤ 0.5 мс. Бенч в стиле bench/lucide_bench.cr.

## Интеграция в egui.cr (по готовности фазы C)

1. `shard.yml`: `lottie: github OrelSokolov/lottie.cr`.
2. `src/egui/backend/lottie_cr.cr` (~20 строк): `Lottie::Animation`
   → `Egui::Lottie::Renderer`; require в ядро (зависимость чистая,
   флаг не нужен).
3. Пример `examples/lottie.cr` переключается на чистый порт;
   rlottie-шим остаётся в дереве как dev-A/B эталон (аналог
   `external_rasterizer`), флаг `LOTTIE=1` уходит после пары релизов.
4. Мобильные: порт собирается везде, где Crystal — Android/iOS без
   единого нового toolchain-шага (исходная мотивация фазы 2).

## Объём и риски

- Оценка: parser+model ~1.2k строк, property+interpolator ~0.8k,
  evaluator ~1.5k, raster ~0.8k, спеки+датасет ~1.5k. Итого ~5-6k —
  фазы A-C это ~70%.
- Риски:
  - fill rule / направление обхода путей Lottie (nonzero vs evenodd,
    `r:1`) — расхождение заливок; митигация: флаг на Path есть в
    nanosvg.cr модели;
  - градиенты в bbox-единицах при анимированном bbox (пересчёт на
    каждый кадр по фактическим bounds путей — как nanosvg);
  - координатный flip Y (Lottie y-вниз, как у NanoSVG — совпадает);
  - производительность интерполяции путей в --release: профилировать
    на фазе B, при нужде — кэш разрешённых сегментов между кадрами.
- Роллбэк: шим остаётся рабочим путём всё время порта — переключение
  строчкой require.
