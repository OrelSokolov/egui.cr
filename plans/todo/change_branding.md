# change_branding: egui → Velour

План переименования фреймворка **egui-cr → Velour**. Пока только план —
ничего не переименовываем, пока не утверждён.

Важно: Rust-проект [egui](https://github.com/emilk/egui) — это внешняя
сущность (референс-архитектура). Все упоминания *upstream egui* как
проекта остаются как есть; переименовывается только наш бренд
(репозиторий, shard, модуль, окружение).

---

## 0. Текущее состояние (замеры)

| Слой | Что | Объём |
|---|---|---|
| Репозиторий | `/Users/oleg/egui.cr`, git remote `OrelSokolov/egui.cr.git` | 1 |
| shard.yml | `name: egui-cr`, version 0.5.2 | 1 файл |
| Код: каталог | `src/egui/` (~140 файлов) → `src/velour/` | 209 файлов упоминают `egui`, ~2 200 вхождений (без учёта регистра) |
| Код: модуль | `module Egui` в ~60+ файлах; `Egui::` — 840 вхождений в src | |
| Код: прочее | `EguiCrActivity` (Android, 6 вхождений), `EguiCrTrayTarget`, `EguiGen` | |
| Подключение | `require "../src/egui"` — 154 (examples+spec+bench), `require "egui"` — в доке egui_gen и у внешних пользователей | ~250 require-строк |
| env-переменные | `EGUI_*` — 28 штук (`EGUI_DPR`, `EGUI_SDF`, `EGUI_MSAA`, `EGUI_EMBEDDED`, …) | src + Rakefile + spec |
| Сборка | Rakefile + backend/*.c + crosspack.yml: `libegui_cr_sokol.a`, `libegui-cr/…` — ~674 вхождения `egui_cr` / `egui-cr` | |
| Скрипты | `scripts/egui_gen.cr` (+ его вызовы из Rakefile/доков) | 1 файл + вызовы |
| Спеки | 152 файла с `Egui::` | spec/*.cr |
| Примеры | 87 файлов с `Egui::` | examples/*.cr, bench/*.cr |
| Доки | README.md, SPEC.md, DEMO.md, LICENSE, PRICING.md, MARKETING-ROADMAP.md, SHARDS-ROADMAP.md, ANDROID_SUPPORT_PLAN.md, METAL.md, VULKAN.md, AGENTS.md, docs/{ARCHITECTURE,ANALYSIS,TERMINAL}.md | 13 файлов |
| Артефакты | `bin/*`, `bin/*.dwarf`, `builds/*.app`, `lib/*.a`, `lib/*.o` | пересобрать, не переименовывать руками |
| История | `plans/completed/*`, `crystal_bug_reports/*`, старые планы в `plans/todo/*` | **не трогаем** (история проекта) |

---

## 1. Целевые имена

| Было | Станет |
|---|---|
| egui-cr (shard, пакет, бренд) | **velour** |
| `src/egui/` | `src/velour/` |
| `module Egui` / `Egui::X` | `module Velour` / `Velour::X` |
| `require "egui"` / `require "../src/egui"` | `require "velour"` / `require "../src/velour"` |
| `EGUI_*` env-переменные | `VELOUR_*` |
| `libegui_cr_<name>.a`, `libegui-cr/<app>` | `libvelour_<name>.a`, `lib/velour/<app>` |
| `scripts/egui_gen.cr` | `scripts/velour_gen.cr` |
| `EguiCrActivity` | `VelourActivity` |
| репозиторий `egui.cr` | `velour.cr` (или `velour` — решить) |
| каталог `/Users/oleg/egui.cr` | `/Users/oleg/velour.cr` |

Открытые вопросы (решить до старта):
1. Имя репозитория: `velour.cr` (симметрично старому) или `velour`?
2. ~~`EGUI_*` env: сразу сломать или держать алиасы?~~ — **решено: алиасы
   остаются** (см. §1.1 и этап 3).
3. `tools/vue2velour.cr` — имя уже содержит «velour», не трогаем.
4. Ссылки на upstream egui в доках и комментариях («порт архитектуры egui»)
   — оставить формулировку «inspired by egui (Rust)» и ссылки на upstream.

### 1.1 Алиасы обратной совместимости (остаётся навсегда, не только на релиз)

Старые имена продолжают работать через слой совместимости:

- **env-переменные**: код читает `VELOUR_*`, но если переменная не задана —
  фолбэк на старую `EGUI_*` (одна точка: helper вида
  `Velour.env("DPR")` в `src/velour/context.cr` / `cli.cr`; в логах —
  warning «EGUI_DPR is deprecated, use VELOUR_DPR» один раз за процесс).
- **`require "egui"`**: компат-файл `src/egui.cr` (после переноса кода в
  `src/velour/`) — просто `require "./velour"`; ломается только если
  пользователь ставил по пути `src/`, что вне shard-установки.
- **Модуль**: `alias Egui = Velour` в `src/velour.cr` — весь старый код
  с `Egui::X` компилируется без правок. Новый код пишем только `Velour::`.
  В предупреждениях о депрекейшене не нуждается: алиас не мешает ничему.
- В доках — раздел «Compatibility» в README: что работает, что считается
  устаревшим.

---

## 2. Этапы

### Этап 0 — базлайн (полдня)
- `rake build:native && rake spec` — зафиксировать зелёное состояние.
- Тег/ветка `pre-velour` для отката.

### Этап 1 — namespace в коде (самый большой, механический)
- `git mv src/egui src/velour`.
- Замена в `src/`, `spec/`, `examples/`, `bench/`, `tools/`:
  - `module Egui` → `module Velour`; `Egui::` → `Velour::`;
    `include Egui` → `include Velour` (проверить, есть ли такое);
  - `require "../src/egui…"`, `{% unless env("EGUI_EMBEDDED") %}` и т.п.;
  - `env("EGUI_…")` → `env("VELOUR_…")` (28 имён, список в §0).
- `EguiCrActivity` → `VelourActivity` (Android-слой: `etc/arm64-v8a`? нет —
  Java/Kotlin обёртка в crosspack/android-шаблонах; найти по grep).
- `EguiCrTrayTarget`, `EguiGen` — точечно.
- Проверка: `crystal spec` (или `rake spec`) — зелёный.
- Один коммит на этап; замена только по целым словам, чтобы не задеть
  `egui` внутри ссылок на upstream.

### Этап 2 — сборка и нативный слой
- `shard.yml`: `name: egui-cr` → `name: velour`; переписать description
  («immediate-mode GUI for Crystal, inspired by the egui architecture…»);
  пути `lib/egui-cr/…` если есть.
- `Rakefile`: `ARCHIVES` (`libegui_cr_sokol.a` и др. — 674 вхождения
  `egui_cr`/`egui-cr` вместе с backend), пути `bin/`, задачи.
- `backend/*.c`, `backend/shaders/`: include-пути, `spv`-хедеры
  (`EGUI_SDF_MASK_SPV_H`-guard'ы → `VELOUR_…`).
- `crosspack.yml`: `name: egui-cr`, maintainer, summary, путь
  `bin/widgets_gallery: ../lib/egui-cr/widgets_gallery`.
- `scripts/egui_gen.cr` → `scripts/velour_gen.cr` + все вызовы
  (Rakefile, доки, шапки сгенерированных файлов `src/gen/*_gen.cr`).
- Локальные статические либы: `lib/libegui_cr_*.a`, `lib/*.o` —
  пересобрать через `rake build:native`, руками не переименовывать.
- `lib/.shards.info`, `shard.lock` — регенерируются (`shards install`).
- Проверка: `rake build:native && rake build:examples` — зелёный.

### Этап 3 — env-переменные и слой совместимости
- Все `EGUI_*` → `VELOUR_*` в коде, Rakefile, спеках, доках.
- Helper `Velour.env(name)` (или эквивалент в одной точке): берёт
  `VELOUR_<NAME>`, при отсутствии — `EGUI_<NAME>` + разовый
  deprecation-warning в stderr.
- `alias Egui = Velour` в `src/velour.cr`, компат-файл `src/egui.cr`
  → `require "./velour"` (см. §1.1).
- Проверить, что все места чтения env в коде идут через helper
  (grep `env("EGUI_` / `ENV[\"EGUI_` после замены — должно быть 0 вне helper).

### Этап 4 — пользовательская поверхность
- README.md (заголовок «egui.cr — Easy crossplatform GUI…», alt у логотипа),
  SPEC.md, DEMO.md, LICENSE, PRICING.md, MARKETING-ROADMAP.md,
  SHARDS-ROADMAP.md, ANDROID_SUPPORT_PLAN.md, METAL.md, VULKAN.md,
  docs/{ARCHITECTURE,ANALYSIS,TERMINAL}.md, AGENTS.md.
- **README: раздел «Origin» / история проекта.** Тезисы (написать честно,
  не по-маркетинговому):
  - Проект начинался как эксперимент: «попробуем порт подхода egui
    (immediate mode: Context / Ui / Memory / Response) на Crystal —
    посмотрим, что получится».
  - Оказалось, что подход egui критически недостаточен для вменяемой
    производительности *разработки* (не только рендера): immediate mode
    не даёт needed-уровня компонентности, состояния, реактивности и
    переиспользования, которые проект наработал поверх — exml/ecss,
    компоненты, MVC, reactive-слой.
  - От оригинальной идеи (1:1 порт egui) почти ничего не осталось —
    осталась инфраструктура (sokol-драйвер, шрифты, отрисовка) и опыт;
    архитектура выросла в свою.
  - Раздел нужен, чтобы (а) честно отвязать бренд от egui, (б) объяснить
    почему алиасы `Egui::`/`require "egui"` существуют, (в) задать
    ожидания людям, приходящим с Rust-egui.
- Раздел «Compatibility» (см. §1.1): алиасы env и require, что устарело.
- `assets/icon.png` alt-тексты, `assets/*.exml` если упоминают egui.
- HTML-заголовки/окна примеров (title «egui…»), `assets/macos_camera_info.plist`.
- Ссылки `github.com/OrelSokolov/egui.cr` в доках → новый URL (после
  переименования на GitHub, см. этап 5).
- `HTML_ALIASES.md`, `DEMO.md` — сверить демонстрационные пути.

### Этап 5 — репозиторий и внешние ссылки (требует подтверждения!)
- GitHub: Settings → Rename repository `egui.cr` → новое имя
  (GitHub поставит redirect со старого URL, но shard-ссылки вида
  `github: OrelSokolov/…` в чужих shard.yml лучше обновить).
- Локальный каталог `/Users/oleg/egui.cr` → `/Users/oleg/velour.cr`
  (влияет на абсолютные пути в IDE/скриптах — предупредить).
- Проверить внешние зависимости, если они ссылаются обратно
  (lottie.cr, freetype.cr, nanosvg.cr — их README/примеры).
- Публикация под новым именем (shards, если публиковался).

### Этап 6 — финальная проверка
- `grep -ri egui` по рабочему дереву (исключая `plans/completed`,
  `crystal_bug_reports`, `oracle/`, ссылки на upstream egui **и слой
  совместимости**: `src/egui.cr`, helper `Velour.env`, `alias Egui`) —
  должно остаться ~0.
- Прогнать спек-кейс «алиасы работают»: сборка старого кода с
  `require "egui"` + `Egui::Context` + `EGUI_DPR=2` (без `VELOUR_DPR`) —
  компилируется, читает значение, warning в stderr.
- `rake build:native && rake build:examples && rake spec`.
- Собрать и запустить руками: `hello`, `widgets_gallery` (по AGENTS.md —
  глазами проверяет пользователь).
- Android/iOS: `rake android <app>`, `rake ios <app>` — проверить
  `EguiCrActivity` в шаблонах и манифестах.
- Обновить этот файл в `plans/completed/`.

---

## 3. Риски

- **Массовая замена по подстроке** заденет ссылки на Rust-egui. Только
  целые слова: `Egui::`, `module Egui`, `src/egui`, `EGUI_`, `egui_cr`,
  `egui-cr`, `require "egui"`. Свободное слово «egui» в текстах — руками.
- **env-переменные** — внешний контракт (скрипты пользователя, CI).
  Решено: не ломаем — алиасы остаются постоянно (§1.1), не «на релиз».
  Из этого следует: в этапе 6 grep не должен требовать нуля вхождений
  в компат-слое (`src/egui.cr`, helper `Velour.env`, `alias Egui`).
- **Имя каталога репозитория** зашито в абсолютных путях (oracle-скрипты,
  `tmp/*_probe.cr` используют `require "/Users/oleg/egui.cr/…"` — grep
  перед переименованием каталога).
- **Артефакты** (`bin/`, `builds/`, `lib/*.a`) не переименовывать —
  только пересборка, иначе сломаются пути в Rakefile/crosspack.
- **Исторические доки** (`plans/completed/*`, `crystal_bug_reports/*`)
  — не трогаем, это история, а не поверхность продукта.
- Android/iOS-шаблоны crosspack: имя `EguiCrActivity` может сидеть в
  сгенерённых манифестах — проверить сборку обоих платформ.

## 4. Оценка

- Этапы 1–3: один-два вечера механики + прогоны спеков/сборок.
- Этапы 4–5: полвечера на доки + действия на GitHub вручную.
- Этап 6: прогон полного цикла сборки (macOS сначала; Android/iOS отдельно).
