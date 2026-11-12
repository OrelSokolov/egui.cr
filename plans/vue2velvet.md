# vue2velvet — конвертер Vue SFC → egui.cr

Решение 2026-11-11: конвертер **1 к 1 для html + css**. JS-код НЕ
переносится вообще — ни сейчас, ни потом: script-половина
портируемого компонента пишется вручную или нейронкой ПО ОТЧЁТУ
конвертера (какие слоты/списки/экшены разметка ждёт от Crystal-класса).
Формула порта: `vue2velvet Component.vue` → `Component.exml` +
`Component.ecss` + отчёт → нейронка пишет `class Component <
Egui::Exml::Component` по отчёту.

Имя: **vue2velvet** (пользовательское; «Velvet» — рабочее имя
целевого фреймворка в разговоре, в коде/доках продукт остаётся
egui.cr / NativeHTML до отдельного решения о переименовании).

## Фундамент (уже сделано)

- **Vue-алиасы в exml** (план vue-aliases.md реализован в exml.cr):
  `v-if`/`v-show`/`v-model`/`v-text`/`:x`/`v-bind:`/`@click`/
  `v-on:` десугарятся на парсе, `v-for="x in xs"`/`(x, i)`/`:key` →
  синтез `<repeat>`-обёртки с `key=`/`index=`, `v-else` — зеркало
  сиблинга. Диагностика — `Exml.warnings`. Спеки:
  `spec/vue_aliases_spec.cr`. Значения — только голые имена слотов
  (выражения JS — предупреждение, expression-движка нет и не будет).
  ⇒ конвертер пропускает директивы **дословно**: выход уже легален.

## Что делает конвертер (механика, без выдумок)

| Vue | → exml | Где |
|---|---|---|
| `<template>` | внутренности → `.exml`-фрагмент | `top_block` |
| `<style>` (все блоки) | конкатенация → `.ecss` дословно | `all_blocks` |
| `<script>` | НИЧЕГО; строка отчёта «пишется нейронкой» | отчёт |
| `{{ x }}` | `{x}` в тексте и в атрибутах | `interp` |
| текст элемента | `text="…"` (парсер exml текст-ноды не читает): `<p>{{x}}</p>` → `<label text="{x}"/>` | `serialize_elem` |
| `class="a b"` | точечный путь `"a.b"` (конвенция ECSS) | `map_elem` |
| `<select>`+`<option>` | `<combo options="A,B,C">` (текст опции; value-ключи — вне подмножества) | `serialize_select` |
| `input[type=range/checkbox]` | `slider`/`checkbox`; прочие типы — `input` + запись в отчёт | `map_elem` |

Словарь тегов TAG_MAP: div/section/article/aside/header/footer/nav
→ box; h1..h6 → heading; p/span/strong/em/small/code/label → label;
select → combo; hr → separator; progress → progress. Всё без
словарной пары (ul/li, a, img, table, main, br, …) остаётся Custom-
нодой и попадает в отчёт — честное «нет полусвойств»: не угадываем,
как рендерить.

## Отчёт — техзадание для нейронки

После конвертации вывод parses через `Exml.parse_fragment` (бесплатная
верификация: warnings десугара видны сразу) и собирает:
- mapped-теги; unmapped HTML (Custom); Vue-компоненты (PascalCase →
  имена для `Component`-классов); mixed-content (текст выпал);
- **slots to publish** (`rt.strings`/`rt.floats`) — все `{x}` и
  `bind`; поля строк (`{item.name}`) и индексы (`{i}`) исключены —
  их покрывает `rt.rows`;
- **lists to publish** (`rt.rows`), **actions** (`rt.actions`),
  **conditions** (`if=`/`v-if` слоты);
- строку-образец `class X < Egui::Exml::Component; exml "x.exml"`.

## Файлы

| Файл | Роль |
|---|---|
| `src/egui/vue2velvet.cr` | модуль: SFC-сплит, мини-парсер шаблона (элементы/атрибуты/текст/комментарии, void-теги, толерантные закрывашки), сериализатор, отчёт |
| `tools/vue2velvet.cr` | CLI: `vue2velvet Component.vue [-o DIR]` |
| `spec/vue2velvet_spec.cr` + `spec/dataset/hello_card.vue` | сквозной тест на SFC без JS (v-if, v-for+(item,i), :key, v-model, {{ }}) |
| `spec/vue_aliases_spec.cr` | спеки фундамента (алиасы) |
| shard.yml `binaries.vue2velvet` | поставка через carat |

## Ограничения v1 (зафиксировано, не молчание)

- value-ключевые `<option :value>`: берётся текст (labels — то, что
  показывает combo).
- `scoped`: атрибут отбрасывается, скоуп остаётся точечными путями
  классов (запись в отчёте); `lang="scss|less"` — копируется
  дословно с предупреждением, ECSS не распарсит.
- mixed content (`<p>текст <span>…</span></p>`): элементы живут,
  текстовые прогоны выпадают и попадают в отчёт — нейронка правит.
- Вложенные `<template>`-обёртки Vue (`<template v-if>`), v-html,
  v-slot — вне подмножества (warnings exml на верификации).

## Дальше (не сейчас)

- Расширение TAG_MAP по мере роста словаря exml (ul/li, a/img —
  после появления соответствующих элементов, NativeHTML §5.3).
- `--watch` (hot-reload конвертации) если понадобится.
- Пакетная конвертация каталога (`vue2velvet src/`).
