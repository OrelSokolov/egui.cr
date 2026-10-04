# Shards Roadmap — кроссплатформенные интеграции и новые порты

План развития системных интерфейсов по двум трекам:

- **Трек A** — порты уровня ядра egui.cr (`src/egui/system_ports/` + input),
  не выносятся в шарды (завязаны на sokol/event loop).
- **Трек B** — общие кроссплатформенные шарды по образцу
  [sysinfo.cr](https://github.com/OrelSokolov/sysinfo.cr): без зависимостей
  от GUI-цикла, shell-out реализация, три desktop-платформы.

Прецедент: `sysinfo.cr` — отдельный шард (Linux `/proc`, macOS
libproc+Mach, Windows Toolhelp32), в egui-cr подключён только как
`development_dependencies` (демка `examples/system_monitor.cr`); фреймворк
от него не зависит.

## Наработки в positron.cr, которые можно вынести в шарды

`~/positron.cr` — host-shim UI фреймворк (webview) с гексагональной
архитектурой **ports & adapters**. Там уже есть готовые интерфейсы и
реализации, пересекающиеся с нашими планами:

| Поверхность | В positron.cr | Что переиспользовать |
|---|---|---|
| Tray | `src/positron/ports/tray_port.cr` + адаптеры (AppIndicator / Win / mac) | порт-интерфейс целиком; Linux-адаптер |
| Theme detect | `plugins/theme/` (Linux gsettings; mac/win — заглушки) | интерфейс `ThemeInfo`; Linux-детект; mac/win дописать shell-out'ом |
| Clipboard (images/files) | `plugins/clipboard/linux.cr` — GTK pixbuf → PNG | перенос чтения images/files в egui-порт |
| Dialogs | `plugins/dialogs/` — нативные GtkMessageDialog | НЕ переносим: у нас zenity/kdialog без GTK-зависимости; наоборот, наш shell-out слой может стать общим шардом |
| Notifications | `plugins/notifications/` | fire-and-forget; добавить click-callback |
| Preferences / secure_storage / deep_links / display | `plugins/...` | интерфейсы как референс для будущих портов |

Стратегии различаются: positron — нативные биндинги (`@[Link("gtk-3")]`,
WebView2) + compile-time фабрики по `{% if flag %}`; egui.cr — installable
`Implementation` (runtime-инъекция от бэкенда) и shell-out'ы, без нативных
библиотек в бинарнике. Общие шарды делаем по egui-стратегии (shell-out),
нативные адаптеры positron'а остаются его внутренним делом.

## Трек A — порты ядра egui.cr

### A1. IME (port + input events) — приоритет 1

`text_edit.cr` сейчас заявляет «multi-line and IME follow». Без IME
невозможен CJK-ввод. Интерфейс: installable `Implementation` от
sokol-shim'а + `Event::Type::Ime` (`Enabled/Preedit/Commit`) и
`InputState.ime` (preedit string + composition rect). Статус: не начато.

### A2. Focus/activation events — приоритет 2

`WindowFocused(bool)` в `input.cr` отсутствует (событие в sokol уже есть).
Потребители: пауза рендера при потере фокуса (`plans/0percent_cpu.md`),
снятие mouse grab, поведение notepad «unsaved changes». Тривиально.

### A3. Cursor grab / relative mouse

`MouseGrab.lock/unlock` — canvas-приложения (paint) и игры. У sokol есть
`sapp_lock_mouse` — выставить в shim и провести в порт. Статус: не начато.

### A4. Monitor enumeration

`system_ports/screen.cr` даёт только primary monitor. Для
`plans/multiwindow-plan.md` нужен `Screen.monitors : Array(Monitor)`
(geometry + dpi_scale), чтобы размещать окна на конкретном мониторе.

## Трек B — отдельные шарды

### B1. `theme.cr` — детект системной темы — приоритет 3

Dark/light + accent color + high-contrast. В egui.cr нет вообще; в
positron.cr интерфейс есть (`plugins/theme/adapter.cr`, Linux через
gsettings), mac/win — заглушки. Shell-out закрывает все три платформы
~100 строк: `gsettings get ... color-scheme` / `defaults read -g
AppleInterfaceStyle` / реестр `AppsUseLightTheme`. egui.cr сразу
реагирует на смену системной темы. Прямой кандидат на общий шард.

### B2. `locale.cr` — язык/регион/форматы — приоритет 4

Язык, first day of week, формат дат/чисел. Конкретный потребитель уже
в репо: `date_picker.cr` захардкожен Monday-first — в US-локали календарь
должен начинаться с воскресенья. Плюс дефолтная локаль для будущей i18n
(`plans/framework-todo.md` → i18n) и выбор CJK fallback-шрифтов.

### B3. `file_watcher.cr` — inotify / FSEvents / ReadDirectoryChangesW

Потребители: notepad (внешнее изменение файла), ecss (сейчас поллинг
mtime в `ecss.cr` — watcher даст событие вместо периодического wakeup),
asset-reload в paint.

### B4. `single_instance.cr` — lock-file / named mutex

Второй инстанс notepad'а должен активировать первый. Связка с
positron'овским `deep_links`: второй инстанс передаёт URL первому.

### B5. Расширение `sysinfo.cr`

Сделано: CPU-проценты (per-core busy%), сеть (rx/tx rates) —
`examples/system_monitor.cr` полностью переведён на sysinfo и стал
кроссплатформенным. Осталось: battery (charge%, power source), uptime.

### B6. Перенос из positron.cr в egui.cr (не шард, а порт + адаптер)

- **Tray port** — минимизация notepad'а в трей; интерфейс взять из
  `positron/ports/tray_port.cr`.
- **Clipboard images/files** — сейчас text-only (`sapp_*_clipboard_string`);
  paste-image-from-clipboard в paint. GTK-реализация чтения pixbuf → PNG
  есть в `positron/plugins/clipboard/linux.cr`.
- **Notifications с callback** — click-on-notification будит окно
  (связка tray + single_instance).

## Приоритеты

| # | Что | Трек | Почему таким порядком |
|---|---|---|---|
| 1 | IME port | A | без него text_edit неполноценен |
| 2 | Focus events | A | тривиально; нужен для 0% CPU плана |
| 3 | `theme.cr` | B | ~100 строк, три платформы, мгновенный win |
| 4 | `locale.cr` | B | закрывает баг date_picker |
| 5 | Monitor enumeration | A | блокер multiwindow |
