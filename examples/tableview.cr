# TableView demo — a Synaptic-style package list: a GTK-model/view
# table over a ListStore of a few hundred fake packages, with a search
# filter (toolbar), click-to-sort columns, drag-resizable headers,
# multi-selection (Ctrl/Shift/arrows/Ctrl+A) and row activation on
# double-click (install/remove toggle).
#
# MVC-миграция (plans/frontend-backend-split.md фаза 4): backend
# приложения — examples/tableview_components/backend.cr (модель +
# PackagesController + `resources "packages"`), вид —
# tableview_components/pkg_app.cr. Этот файл — только точка входа.

require "./tableview_components/pkg_app"
require "../src/egui/driver_selector"

Egui.run(PkgApp.new,
  title: "egui-cr — TableView (Synaptic-style package list)",
  width: 1100, height: 700)
