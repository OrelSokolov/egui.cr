# Подсветка синтаксиса + промежуточное представление рендеринга + LaTeX-формулы

> **Статус: план согласован, не начато.** Решения зафиксированы по итогам
> обсуждения: грамматико-ориентированный движок подсветки (порт ядра
> highlight.js), DOM-образный IR вместо HTML-движка, формулы LaTeX через
> SVG с попиксельным оракулом MathJax. Фазы — §4–§6.

Контекст: markdown-виджет (`src/egui/widgets/markdown.cr`) рендерится из
ad-hoc модели `Array(Block)` (`kind : Symbol` + `text : String`; таблицы
сериализованы через `\x1F`; inline-разбор захоронен в
`RichText#styled_runs` внутри виджета). Кодоблоки рисуются моноширинно
без подсветки. Впереди — порт mathjs и рендеринг формул. Вопрос был:
сделать ли HTML-рендер-движок как промежуточное представление.

TL;DR: полный HTML-движок не делаем — его дорогость не в парсинге, а в
inline-flow layout (каскад, наследование, переносы), который виджетному
рендереру не нужен и не тянет. Вместо этого: (1) подсветка — порт
компактного ядра highlight.js, грамматики как данные ⇒ все языки;
(2) markdown → DOM-образное IR-дерево; (3) формулы — раскладка → SVG →
nanosvg, оракул — SVG-вывод MathJax (у него HTML+CSS-вывод требует
настоящего CSS layout и невоспроизводим, SVG-вывод — картинка, тривиально
сравнивается попиксельно).

## 1. Решения

1. **Подсветка — грамматико-ориентированный движок, порт highlight.js.**
   Требование — поддержка всех языков в будущем. Значит: движок один раз,
   грамматики — данные. Ядро highlight.js компактно (стек модов,
   begin/end-матчинг, keyword-классификация, relevance), грамматики —
   JS-объектные литерали, портируются в Crystal почти 1:1; regex-литералы
   JS ≈ PCRE2 Crystal (lookbehind, `\p{…}`, backreferences — есть).
   Грамматики с JS-колбэками (`on:begin` — их мало) портируются руками
   или откладываются. Модуль проектируется с нулевой связностью с egui —
   вынос в отдельный шард по образцу nanosvg.cr / freetype.cr позже
   механический.
2. **IR вместо HTML-движка.** Рендерер — стек виджетов со своим layout.
   HTML как формат ничего не добавляет к возможностям — только ещё один
   вход. IR делаем DOM-образным: узлы-элементы, inline-спаны, свойства
   стиля теми же именами, что в ecss. Тогда HTML-фронтенд потом (если
   понадобится) — это парсер → IR, а не layout-движок.
3. **LaTeX — через SVG.** nanosvg уже вендорен, svg-виджет есть. Оракул —
   SVG-вывод MathJax, отрендеренный в PNG; сравнение попиксельное.

## 2. Текущее состояние (что ломаем)

- `Markdown.parse` (markdown.cr:127) — чистая строковая нарезка в
  `Array(Block)`; fence info-строка (язык кодоблока) выбрасывается.
- `render_code` (markdown.cr:452) — моноширинный Label, без подсветки.
- Inline-разбор (`**bold**`, ссылки) — внутри `RichText#styled_runs`,
  переиспользовать из markdown-дерева нельзя.
- Таблицы — `text` блока с `\x1F`-разделителями.

## 3. Отклонённые альтернативы

- **TextMate-грамматики + свой движок** (формат VSCode): тысячи готовых
  грамматик, но движок заметно сложнее — injections, anchored regexes,
  специфика oniguruma.
- **tree-sitter**: настоящие AST и максимум точности, но C-зависимости и
  генераторы парсеров — тяжело для задачи подсветки и деплоя.
- **Полный HTML/CSS layout-движок**: многолетний проект, не нужный
  виджетному рендереру; стилизация уже покрыта ecss.
- **Hand-written лексер только для Crystal**: точен для одного языка, но
  не масштабируется на требование «все языки».

## 4. Фаза 1 — движок подсветки + подключение в markdown

1. **Ядро** `src/egui/syntax/engine.cr` (+ фасад `syntax.cr`):

   ```crystal
   module Egui
     module Syntax
       class Mode                      # порт JS-мода highlight.js
         property begin : Regex?
         property end : Regex?
         property keywords : Hash(String, Array(String))?
         property contains : Array(Mode)
         property sub_class : String?  # scope: "string", "title.function"…
         property return_begin : Bool   # + return_end, exclude_begin/end,
                                        #   ends_parent, ends_with_parent,
                                        #   self_mode — как в highlight.js
       end

       struct Token
         getter scope : String         # "keyword", "comment", "number"…
         getter text : String
       end

       class Engine
         def initialize(@root : Mode); end
         def highlight(code : String) : Array(Token); end
       end

       REGISTRY = {} of String => Mode  # "crystal" => …, "json" => …
       def self.[](lang : String) : Mode?
       def self.highlight(code : String, lang : String) : Array(Token)?
     end
   end
   ```

   Портируется из highlight.js `lib/core.js`/`lib/highlight.js`: цикл по
   стеку модов, `keywordPattern`, обработка `return_begin/end`,
   `ends_with_parent` — ~90% движка.

2. **Грамматики** — один файл на язык, `src/egui/syntax/grammars/`:
   `crystal` первой (порт `crystal.js` из highlight.js), затем простые:
   `json`, `bash`, `yaml`, `javascript`, `python`, `rust`, `c`.
3. **Палитра** `src/egui/syntax/palette.cr`: scope-имя → `Color32`;
   GitHub Light + GitHub Dark (тёмная — по `visuals.dark_mode`), фон
   кодоблока не меняется.
4. **Markdown**: fence info-строка сохраняется в `Block#lang`;
   `render_code` при известном языке → `Syntax.highlight` → TextRuns с
   цветами палитры, иначе — как сейчас.
5. **Спеки** `spec/syntax_engine_spec.cr`: инвариант
   `tokens.map(&.text).join == исходник`; golden-токенизация сниппетов
   (Crystal с heredoc+интерполяцией, JSON, JS).
6. **Демо**: кодоблоки ` ```crystal `, ` ```json ` в материале
   `examples/markdown.cr`; скриншот `scripts/make_screenshots.py`.

## 5. Фаза 2 — IR-рефактор markdown

- `Doc::Node` — DOM-образное дерево: блочные узлы (paragraph, heading,
  `code(lang, tokens)`, list, table настоящими ячейками, quote, image,
  math) + inline-узлы (text, styled span, link, image, math).
- `Markdown.parse` → фронтенд, производящий IR; рендер ходит по дереву.
- Inline-разбор поднимается из `RichText#styled_runs` в общий
  inline-парсер (markdown и RichLabel переиспользуют).
- Подсветка фазы 1 ложится без переделок: `code(lang)` уже в модели.
- Опционально: рассмотреть `markd` (CommonMark, чистый Crystal) вместо
  самописного блокового парсера — 650+ спецификационных тестов бесплатно.

## 6. Фаза 3 — LaTeX через SVG (после mathjs-порта)

Порт раскладки формул (по мотивам KaTeX/MathJax) → генерация SVG →
nanosvg → текстура. В IR — узел `math` (блочный и inline). Оракул:
SVG-вывод MathJax → PNG, попиксельное сравнение (скриншот-инфраструктура
уже есть — `scripts/make_screenshots.py` и Co).

## 7. Критерий готовности фазы 1

- ` ```crystal `-блок в markdown-демо подсвечен, светлая и тёмная темы.
- Инвариант покрытия и golden-спеки зелёные.
- Неизвестный язык и код без info-строки рендерятся как раньше.
- Модуль `Syntax` не импортирует ничего из egui, кроме `Color32`
  (и это — только в палитре; ядро вообще без egui-типов).
