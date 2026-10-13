# System tray (перенос из positron.cr)

> **Статус: план, кода нет.** Источник — рабочая реализация в
> `~/positron.cr/` (портирована с getlantern/systray и её форка
> OrelSokolov/systray). Ниже — инвентаризация донора, целевой дизайн
> под паттерн `SystemPorts` и фазами, с рисками по платформам.

## Что берём из positron.cr

| Файл донора | Строк | Судьба |
|---|---|---|
| `src/positron/tray_item.cr` | 31 | копия, namespace → `Egui` |
| `src/positron/icon_source.cr` | 27 | копия, namespace → `Egui` |
| `src/positron/ports/tray_port.cr` | 49 | не нужен: в egui.cr порт = статический модуль, не абстрактный класс |
| `adapters/macos/tray.cr` | 299 | логика целиком, но сидит на общем ObjC-слое донора (`adapters/macos/objc.cr`, 429 строк) |
| `adapters/windows/tray.cr` | 281 | логика целиком, вытащить подмножество Win32-структур из `adapters/windows/win32.cr` |
| `adapters/linux/app_indicator_tray.cr` | 370 | переписывать: завязан на работающий GTK main loop |

`TrayItem` (id, parent_id, title, tooltip, disabled, checked, checkable,
hidden; сепаратор = title `"-"`) и `IconSource` (bytes + `:png/:svg/:ico`)
платформонезависимы и переносятся без правок.

## Целевой дизайн в egui.cr

Паттерн — как у остальных портов (`system_ports/notification.cr`):
один файл на порт, headless-тестируемость, нативная реализация либо
инлайн по флагам платформы, либо installable runner от бэкенда.

```
src/egui/system_ports/tray.cr        — публичный API + TrayItem + IconSource
                                        + очередь кликов (headless)
src/egui/backend/objc_min.cr         — урезанный ObjC-слой (только macOS)
src/egui/backend/tray_darwin.cr      — NSStatusBar/NSStatusItem
src/egui/backend/tray_windows.cr     — Shell_NotifyIconW + TrackPopupMenu
```

Публичный API (в духе positron'ского `TrayPort`, но модульно):

```crystal
Egui::SystemPorts::Tray.supported?                    # Bool
Egui::SystemPorts::Tray.create(icon, tooltip = nil)   # из update (main thread)
Egui::SystemPorts::Tray.set_icon(icon) / set_tooltip(t)
Egui::SystemPorts::Tray.add_item(id, title, *, checkable, checked, disabled, parent_id)
Egui::SystemPorts::Tray.add_separator(id)
Egui::SystemPorts::Tray.remove_item(id) / show_item(id) / hide_item(id)
Egui::SystemPorts::Tray.show / hide / quit
Egui::SystemPorts::Tray.on_click(& : Int32 ->)        # регистрация обработчика
Egui::SystemPorts::Tray.pending_clicks : Array(Int32) # опрос из update
```

**Доставка кликов** — ключевое отличие от positron: там коллбэк зовётся
прямо из ObjC target-action / WndProc, а у нас UI живёт в `update`.
Кладём id в `@pending` (mutex не нужен: и клики, и update на main
thread на macOS/Windows), `update` опрашивает `pending_clicks` и
чистит. `on_click` оставить как sugar поверх очереди для реактивных
приложений.

**Иконка по умолчанию** — `assets/icon.png` (macOS) и `assets/icon.ico`
(Windows) уже в репо; читать в `IconSource` при `create(icon: nil)`.

Регистрация: `require "./tray"` в `system_ports/system_ports.cr`,
подключение бэкендов — из `backend/sokol.cr` по флагам `darwin`/`win32`.

## Фаза 1 — ядро (headless + спеки)

- `system_ports/tray.cr`: `TrayItem`, `IconSource`, очередь кликов,
  no-op реализация по умолчанию (`supported?` → false), installable
  native runner (образец — `Notification.use_native`).
- `spec/system_ports_spec.cr` дополнить: item-модель, очередь кликов,
  separator, submenu через parent_id.
- Пример `examples/tray.cr` (десктоп-only гвард).

## Фаза 2 — macOS

- `backend/objc_min.cr` — подмножество positron'ского `objc.cr`
  (~150–200 строк из 429): `cls/sel`, `send0/send1/send3`,
  `nsstr/nsdata`, bool/int аргументы, `new_class/class_addMethod/
  bind_target/target_for` для target-объекта меню, `ObjC::Call`
  (NSInvocation) — нужен ровно один раз, для `statusItemWithLength:`
  c double `-1.0`.
- `backend/tray_darwin.cr` — перенос `StatusBarTray` с сохранением
  фиксов из systray_darwin.m: `setVisible:true` после создания
  (пользовательский ⌘-drag-хайд персистентный), нормализация иконки
  к 16×16 `setSize:` + `setTemplate:false`, явный `imagePosition`,
  `setAutoenablesItems:false`, toggle checkable вручную.
- Выкинуть из донора `App.ensure_app` — NSApplication уже поднят
  sokol'ом; `update` и так на main thread.
- Проверка руками: пример `examples/tray.cr` — иконка, меню с
  сепаратором/checkable/подменю, tooltip, клики меняют UI.

## Фаза 3 — Windows

- Вытащить из positron `win32.cr` только tray-подмножество в
  `tray_windows.cr` (прецедент — локальный `LibUser32` в
  `system_ports/message_box.cr`): `WndClassExW`, `CreateWindowExW`
  (HWND_MESSAGE), `Shell_NotifyIconW` + `NotifyIconDataW`,
  `MenuItemInfoW`/`InsertMenuItemW`/`TrackPopupMenu`,
  `LoadImageW` (ICO), GDI+ PNG→HICON (у positron `hicon_from_png`).
- Sokol на Windows качает `PeekMessage` для всего потока — WndProc
  скрытого message-окна будет получать `WM_APP+1` без доработок.
- Сохранить фикс KB135788 (`SetForegroundWindow` + `WM_NULL` после
  `TrackPopupMenu` — иначе меню не закрывается кликом мимо).
- Проверка: кросс-компиляция (`crosspack.yml`) + запуск на живой
  Windows-машине.

## Фаза 4 — Linux: StatusNotifierItem напрямую по DBus (решение — вариант B)

Прямой перенос адаптера positron невозможен: он весь на `g_idle_add` →
GTK main loop, а в egui.cr цикл крутит sokol. **Решение: не тянуть
AppIndicator/GTK вообще** — реализовать протокол StatusNotifierItem
(SNI) сам, поверх DBus. Это соответствует архитектуре egui.cr (sokol
уже сам работает с X11/Wayland, лишних GUI-зависимостей нет) и
убирает runtime-зависимость от `libayatana-appindicator3`/GTK3,
которых на Arch/Fedora KDE может не быть.

**Совместимость с DE:** KDE Plasma — родной хост SNI (протокол
исторически KSNI, plasmashell хостит его из коробки, меню рисует сам
через DBusMenu — чекбоксы/подменю работают). XFCE/MATE/Cinnamon —
норм. GNOME — нужен экстеншн (Ubuntu AppIndicator/KStatusNotifier);
без него иконки не видно — это документируем, не боремся.

Состав работ:

1. **DBus-транспорт.** Свой минимальный клиент: системных шин не
   нужно — только session bus. Транспорт — Unix-сокет из
   `$DBUS_SESSION_BUS_ADDRESS`; сериализация DBus (маршаллинг
   заголовков/тел, сигнатуры) инлайн, без shard-зависимостей.
   Альтернатива рассмотреть при реализации: `libdbus`/`sd-bus` через
   FFI, если ручной маршаллер разрастётся — но стартуем с ручного,
   объём протокола для трея ограничен.
2. **Регистрация:** запрос имени `org.kde.StatusNotifierItem-PID-1`
   (`org.freedesktop.DBus.RequestName`), затем регистрация у
   `org.kde.StatusNotifierWatcher` (`RegisterStatusNotifierItem`)
   с fallback на `org.freedesktop.StatusNotifierWatcher`.
   Отсутствие Watcher'а на шине = `supported?` false (или retry).
3. **Интерфейс `org.kde.StatusNotifierItem`** (свойства → сигнал
   `PropertiesChanged`): `Category`, `Id`, `Title`, `IconName`,
   `IconPixmap` (ARGB32-массив — конвертация PNG → сырые пиксели
   через существующий `image_codec`), `ToolTip`, `Status`
   (Active/Passive = show/hide), `Menu` (object path DBusMenu).
4. **DBusMenu-экспортёр** (`com.canonical.dbusmenu`): дерево из
   `TrayItem` (id → DBusMenu id), `GetLayout` (дерево с
   properties: label, enabled, visible, toggle-state, children),
   `GetGroupProperties`, события `AboutToShow`, `MenuEvent`/
   `ItemActivation` → клики в `pending_clicks`. Сигнал
   `LayoutUpdated` при мутациях пунктов.
5. **Потоковая модель:** DBus-сокет в выделенном сокет-дожде Crystal
   (наш IO — неблокирующий, отдельный `Fiber` + read-loop), мутации
   меню — постинг в исходящий буфер, клики — в очередь. Никакого
   чужого main loop.
6. **Иконки:** SNI ждёт `IconName` (тематическая) или `IconPixmap`
   (сырые пиксели). `IconSource.png?` → декод через
   `src/egui/image_codec.cr` → premultiplied ARGB32. SVG для KDE
   можно отдать через `IconThemePath` + `IconName` (файл в tempdir,
   как у positron'ского адаптера). ICO — конвертнуть в PNG-ветку
   или warn.

Спеки: маршаллер DBus (рукопожатие AUTH EXTERNAL, кодирование
строк/структур/вариантов/массивов), дерево DBusMenu → `GetLayout`
ответ, `PropertiesChanged`-генерация. Ручная проверка — на машине
с KDE/GNOME+экстеншном.

## Риски / открытые вопросы

- **Живучесть ObjC-объектов**: в доноре target-объект меню и status
  item держатся strong-ссылками класса; при переносе в модуль
  (нет инстанса) — держать в class-ivar'ах, `quit` при выходе
  ( deregister из sokol-callback'а выхода, аналог `SystemPorts::Quit`).
- **Кристалльный линк ObjC-рантайма**: `objc_msgSend` с fixed-arity
  трюком донора (лишние NULL-аргументы игнорируются ABI) — сверить,
  что кристалльные объявления не конфликтуют с существующими шимами.
- **PNG→HICON на Windows**: у positron GDI+ хелпер в `win32.cr` —
  перенести вместе с адаптером.
- **Ручной DBus-маршаллер (Фаза 4)**: объём протокола легко
  недооценить (AUTH, выравнивание, варианты). Точка выхода —
  FFI на `libdbus`/`sd-buf` без смены дизайна порта; решение
  принимать по факту размера маршаллера, а не заранее.
- **Множественные вызовы `create`** — определить семантику (re-create:
  `quit` + `create`, как `removeStatusItem:` + новый item).
- Проверка на KDE/GNOME живьём — недоступна из этого окружения,
  ограничимся код-ревью + ручным тестом на доступных машинах.
