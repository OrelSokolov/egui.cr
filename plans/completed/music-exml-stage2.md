# music_exml — этап 3: live-порт oracle/oracle_live (Vue → exml)

Записано 2026-11-11. Поверх этапа 2 (статический оракул 1:1) перенесено
**живое поведение** Vue-оракула `oracle/oracle_live/` (плеер/очередь,
акцент из обложки, поиск, коллекция альбома и плейлиста, notices, остров,
клавиши). Файлы oracle/* — read-only референс, не менялись.

## Файлы

- `examples/music_components/music_library.cr` — данные/утилиты 1:1 из
  app.js: 14 альбомов, LCG-генерация треков (сид 20261101+a·7919),
  плейлисты (0-й живой), make_accent/scale_hex/fmt_time/fake_level;
- `examples/music_components/music_player.cr` — `MusicPlayer`: порт
  data+methods корня Vue (очередь/shuffle/repeat/on_ended/prev>3c/лайки/
  notices 2.5c/навигация с history/настройки), тестируется без UI;
- `examples/music_components/music_app.cr` — класс `MusicExmlApp`
  (computed→store каждый кадр, actions, hotkeys, часы; MUSIC_PAGE —
  аналог location.hash оракула: album/playlist/search/genres/library/
  settings, опции ,paused);
- `examples/music_exml.cr` — тонкая точка входа (как html_gallery);
- `examples/music_components/music_tags.cr` — акцент из store
  (`MusicTags.accent(rt)` вместо константы), fake_level с атакой 22/
  спадом 9 и паузой 0.08 (состояние столбиков по node.path), mesh/hero
  цвета из атрибутов + дрейф при «Animate», oswitch с on_click,
  ibtn с color= (активные shuffle/repeat/heart — акцент), Esc в поиске
  — blur без очистки (как у Vue);
- `assets/music.exml` — параметризована: обложки/цвета/тексты из store,
  «From {context}», колонка Album только у плейлиста, hero/мета/лайки
  коллекции, очередь с «Nothing after this song», карточные ряды
  альбомов библиотеки чанками по 3 (аналог CSS-переноса);
- спеки: `spec/music_library_spec.cr` (контрольные точки LCG,
  пересчитанные независимо на Python; make_accent против node-эталона),
  `spec/music_player_spec.cr` (on_ended по 3 режимам, shuffle в голову,
  prev>3c, кол Play/Shuffle, лайки, история), `spec/music_exml_live_spec.cr`
  (capybara-сессия: кадры + действия → store/плеер, Space/Ctrl+→).

## Что теперь живое (паритет с oracle_live)

плеер по всей библиотеке (очередь, shuffle с start в голову, repeat
off/all/one, prev >3c, seek, громкость/mute с иконкой), акцент
follow_cover/picked (make_accent), mesh/hero/np-артист из цветов
обложки, поиск живой по вводу (top/до-5-песен/альбомы, жанр-плитка,
Ctrl+F), коллекция альбома И плейлиста (мета «N songs, M min»,
колонка Album, colPlay/colShuffle, лайк альбома, трек играет списком
коллекции), island с notice-подменой 2.5 с и развёрнутым мини-плеером,
лайки треков/альбомов с живым «Liked songs», сайдбар из libFilter со
счётчиками, newReleases по году, greeting по часам, настройки живые
(Background Mesh…None, Animate, панель, Look → «Not in this demo»),
клавиши Space/Ctrl+←→/Ctrl+L/F/P/Alt+← (Space не мешает печати).

Проверено: `crystal spec` 1137 примеров зелёные; скриншоты пяти страниц
`tmp/exml_*.png` (драйвер `tmp/exml_shot_driver.py`, title «exml live»),
живые проверки `tmp/live_shots.py` / `tmp/key_test.py` (XSetInputFocus
обязателен — без WM XTEST-ключи идут не в окно).

## Остаточные расхождения с oracle_live (осознанные)

- hover-переходы мгновенные: ECSS transition/:hover не действуют на
  painter-теги (гэп №1 этапа 2) — сглаживание остаётся работой тега;
- mesh — painter-аппроксимация радиальных градиентов с медленным
  дрейфом (не CSS-анимация блобов; GPU-эффекты — NATIVE_HTML_DEMO 3.3);
- repeat-one рисуется иконкой repeat (без «1»-бейджа) — отличают цвет
  акцента и notice;
- радиальные градиенты и 135° обложек — аппроксимации (гэп №3);
- карточные ряды библиотеки переносятся чанками по 3 (фикс. разметка),
  поиск/albums — один ряд с обрезкой (как в этапе 2);
- letter-spacing/text-shadow отсутствуют (гэп №6).

Статус: этап 3 (live) завершён 2026-11-11; следующие кандидаты —
акцент-оверрайд каскада (NATIVE_HTML_DEMO 3.5), GPU-эффекты фона (3.3).

---

# Этап 2 (история): оракул raven_music 1:1 на собственном фреймворке

Записано 2026-11-10. Порт статического HTML-оракула
`oracle/raven_music/` (пять окон 1360×860, тема Nocturne) на exml +
ECSS + кастомные теги — проверка декларативного стека NativeHTML на
реальной вёрстке. Задача формулировалась владельцем как «версия 1 к 1
html-оракула уже на фреймворке; что-то может не работать — не страшно,
нужен список того, что не работает».

## Файлы

- `examples/music_exml.cr` — приложение: store (данные 1:1 с oracle/
  raven_music/index.html), навигация, ECSS-сессия;
- `examples/music_components/music_tags.cr` — кастомные теги (аналог
  Rxml_register_tag Raven): `t icon cover vis mesh island panel col
  hbar mainarea pbar crow gap spring chip navitem ibtn playround
  gtile hero oswitch oswatch ocombo oslider logo avatar searchpill
  hline`;
- `assets/music.exml` — разметка: одна страница root/root, центр
  переключается `if="page_*"`; хром (header/sidebar/nowplaying/
  playerbar/island) — партиалы, данные — `<repeat>`;
- `assets/music.ecss` — тема Nocturne (правила читает `<panel class=>`);
- `tmp/exml_shot_driver.py` — скриншоты `tmp/exml_*.png` (xvfb + XTEST);
  сверка: `tmp/cmp_exml_*.png` с `tmp/oracle_win_*.png` (chromium).

Запуск: `rake build:dev[music_exml] && ./bin/music_exml`; отладка
геометрии — `MUSIC_GEOM=1`; разметка и тема горячо перезагружаются.

## Точность (скриншот против оракула)

Поэлементный аудит (группа за группой, DOM-замеры оракула ↔ гео-дампы
тегов, `MUSIC_GEOM=1` / `MUSIC_PAGE=<страница>`): FULL RMSE 39–45 из 255
по пяти окнам; по регионам: header 24, navbox 24–29, libbox 42,
центры страниц 18–50, now-playing 57, playerbar 42. Остаток —
полупрозрачные поверхности поверх mesh (нет композиции), аппроксимации
радиальных градиентов и метрики шрифта. Пиксель-в-пиксель совпали:
окно 1360×860, header 56, main 716, playerbar 88, center 708×700,
nowplaying 320, sidebar 300/120/572 (строки 54 через 56, cover 46+4),
quick-сетка 3×2 (340/563/786 × 180/240), транспорт 568/614/660/712/758,
правый кластер бара 1082/1118/1154/1190, слайвы карточных рядов Home
(секции шагом 101.75, ряд 65), Library (плейлисты 183→225, альбомы кап
286, вторая строка слайвом), Collection (hero 298, actions 76, heads 29).

Важно: в HTML-оракуле карточные ряды Home **сминаются флексом** до
64.8px (обложки видны 55px-слайвами, подписи срезаны), np-визуализатор
смят в 0, queue-карточка обрезана до ~68px — порт воспроизводит и это
(«flex-смятие» через фиксированные высоты окон + clip-каскад).

## Что не работает / чем заменено (находки порта)

1. **CSS-анимации столбиков** — предсказано владельцем: в ECSS
   `@keyframes` есть, но к painter-содержимому кастомных тегов не
   применяются. Визуализатор — painter-виджет `<vis>` (уровни
   `MusicTags.level`, сам зовёт `request_repaint`) — как
   `Rcustom_set_paint_callback` у Raven.
2. **Flexbox** (`flex:1`, `justify-*`, `align-items`, `gap`) — в exml и
   движке отсутствует (задумано non-goal). `<spring/>` считается
   контейнером по предрасчёту ширин детей (`estimate_width`);
   вертикальное центрирование — `seed_row_height`; flex-gap — `<gap>`
   с пропуском невлезающих в строку.
3. **Градиенты** — только вертикальные двухстоповые; `135°` обложек и
   радиальные mesh/hero — аппроксимации (`rect_gradient`,
   концентрические круги `MusicTags.radial`).
4. **Полупрозрачные поверхности поверх mesh** (`#0d0d12c8`) — сплошные
   цвета (нет композиции слоёв CSS).
5. **`position:absolute`** (обложка в углу genre-tile, остров) — painter
   в кастомном теге; остров — `ui.overlay(:top_center)`.
6. **`letter-spacing`** (.eyebrow/.kind), **`text-shadow`** (инициалы) —
   нет.
7. **Шрифт** — Roboto/DejaVu оракула против дефолта движка: метрики
   отличаются на несколько px (вклад в RMSE).
8. **Слайдеры/тумблеры/комбики настроек и бара** — статичная отрисовка
   (`oslider/oswitch/ocombo`): interact не подключён (оракул статичен).
9. **Router×Page**: пять отдельных `<page>` + `navigate` не годятся для
   1:1 — `Egui::Page` при глубине стека >1 втыкает свой 44px back-хедер
   и смещает геометрию. Страницы переключаются `if=` внутри одной
   страницы (расхождение контрактов Router/Page — кандидат на правку).
10. **`overflow:hidden`** — движковый `allocate_space` клампит размеры
    в остаток региона; контейнеры демо дают детям полубесконечные
    child-регионы + clip (костыль, не контракт).
11. **exml-парсер не принимал цифры в именах атрибутов** (`c1=`, `s20=`)
    — молча выбрасывал их как «junk». Исправлено в `src/egui/exml.cr`
    (regex `[a-zA-Z_][a-zA-Z0-9_]*`) — настоящая находка порта, спеки
    зелёные.
12. Интерактивны только навигация и карточки альбомов; чипы, кнопки
    плеера, поиск — декоративны (соответствует статичному оракулу).

## Что работает как ожидалось

`<repeat>` по данным + `{field}`-интерполяция, партиалы, `if=`,
кастомные теги через глобальный реестр `widget`, ECSS-правила классов с
`:hover`, горячая перезагрузка разметки и темы, overlay-остров,
иконки lucide/bootstrap через `Icon.from_file`, painter-текст с wrap.

Статус этапа: завершён 2026-11-10; следующие — 3.5 (акцент из обложки),
3.3 (GPU-эффекты фона), 3.8 (island ExpandOnHover).
