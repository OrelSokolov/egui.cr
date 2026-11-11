# html_gallery — план

Два артефакта с ОДНИМ списком демо (71 карточка):

1. **`examples/html_gallery.html`** — HTML-аналог (эталон): настоящая
   страница, каждая демо-карточка = слева ТРИ readonly-<textarea
   (Crystal / ECSS / EXML — табы в правом верхнем углу карточки),
   справа — живой результат в браузере. Сверху строка поиска, фильтрует
   карточки по тексту кода (JS только у фильтра и табов).
2. **`examples/html_gallery.cr`** — бинарник (egui.cr, `require
   "egui/html"`): та же структура — поиск сверху, скролл всего контента,
   карточка = табы Crystal/ECSS/EXML + активная readonly-панель кода
   слева + отрисованный результат справа. Интерактивное состояние —
   через `Signal` (переживает фильтрацию карточек).

Назначение — поиск багов рендера: карточки в аналоге и в бинарнике
идентичны по коду и результату, сравнение бок-о-бок.

Правило честности: демо-стили ограничены подмножеством движка. Карточки,
где механизм другой (градиенты → `Button#gradient`/canvas2d,
appear-анимации), помечены. Юниты длины (`50%`, `rem`) парсятся ECSS,
но виджетами не применяются — карточек с ними нет.

## Список демо (71)

### Text (13)
h1..h6 · p · p+color · p+font-size · span · span+br ·
strong/em/code · mark · small · sub/sup · pre · hr · blockquote

### Lists (4)
ul>li · ol>li · ol start:5 · nested ul in ol

### Fills & backgrounds (10)
div+background · palette strip · rgba translucent · div+stroke ·
border-radius:16 · radius ramp 0/8/16/28 · padding:16 ·
padding-x vs padding-y · fill+stroke+radius combo · nested fills

### Gradients (3; как есть: Button#gradient + canvas2d)
linear 2-stop (Button) · radial (canvas2d) · multi-stop (canvas2d)

### Layout & sizing (6)
block flow nesting · span no-wrap row · width+height pinned ·
wrapping row · columns(3) · page frame mock (header/nav/aside/main/footer)

### Containers (5)
fieldset+legend · details closed · details open · dialog (modal) · iframe

### Forms (16)
input · input+placeholder · input disabled · select · button ·
button+background · button gradient · button disabled · button+title ·
checkbox · radio · range slider · textarea · progress · progress+text · meter

### States & attributes (5)
p+title tooltip · hidden · classes+rule · inline style beats class · data_testid

### Animations (5)
appear: fade · appear: drop · hover transition · animated progress · spinner

### Media & links (4)
a link · img natural · img width/height (aspect) · img alt/title

## Найденные баги движка (галерея + headless-проверка, 2026-11-11)

1. ~~**`Ui#pre` ломает поток**~~ — **исправлено**: `ScrollArea#render`
   всегда занимал всю доступную высоту родителя, в неограниченном
   родителе — 1e6 (миллион пикселей пустоты после pre-блока, скролл
   умирал). Фикс: `pre` в html.cr теперь контентной высоты (строки ×
   line_height), как браузерный `<pre>`. Общий случай (scroll_area с
   auto-высотой в неограниченном родителе) остаётся открытым.
2. ~~**Колесо глотается нераскручиваемыми sink'ами**~~ — **исправлено
   (scroll chaining)**: `Memory` теперь хранит sink'и с признаками
   `can_v`/`can_h` (`Memory::ScrollSink`), и `begin_frame` выбирает
   верхний sink, способный скроллить ось колеса; sink под ним получает
   дельту (правило браузеров). ScrollArea декларирует оси по
   prev_content (сентинел −1 = первый кадр), TextArea — вертикаль при
   переполнении > 4px и никогда для readonly (deviation задокументирована
   в textarea.cr). Спеки обновлены под ScrollSink (1080 зелёных).
3. **SelectableLabel не кульится скроллом** — в scroll area с 400
   label + 400 selectable: label рисуются только видимые (13/400),
   selectable — все 400/400 (y до 24627). Раздувает command list.
   (не чинилось — движковая задача)

## Статус

- [x] plans/html_gallery.md — этот план
- [x] examples/html_gallery.html — HTML-аналог (71 карточка, 3 ОТКРЫТЫЕ
      панели кода Crystal/ECSS/EXML с подписями, без табов)
- [x] examples/html_gallery.cr — вход (9 строк) + компонент
      examples/html_gallery_components/html_gallery_app.cr
      (рефакторинг 02:11); карточки = 3 открытых readonly-панели
- [x] bin/html_gallery — собран, скролл проверен: колесо в трёх полосах
      (код-панели/середина/результаты) доводит до последней карточки и
      возвращается наверх; iframe-карточка — статичный мок (живое окно
      перехватывало колесо)
- [x] полные спеки: 1080 examples, 0 failures

