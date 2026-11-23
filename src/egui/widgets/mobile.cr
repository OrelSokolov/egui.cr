# Mobile widget set (plans/todo/mobile_widgets.md) — the aggregate
# require. One line in egui.cr pulls in every mobile widget/container
# plus their `Egui::Ui` sugar helpers (each file reopens Ui, so the
# aggregate must sit AFTER "./egui/ui").
#
#   widgets/switch.cr          (#1  mobile switch)
#   widgets/snackbar.cr        (#2  snackbar/toast)
#   widgets/list_tile.cr       (#3  list tile / list view)
#   containers/bottom_nav.cr   (#4  bottom navigation bar)
#   containers/app_bar.cr      (#5  top app bar)
#   widgets/fab.cr             (#6  floating action button)
#   widgets/card.cr            (#7  card)
#   widgets/chip.cr            (#8  chip)
#   widgets/badge.cr           (#9  badge)
#   widgets/stepper.cr         (#10 stepper)
#   widgets/avatar.cr          (#11 avatar)
#   widgets/search_bar.cr      (#12 search bar)
#   containers/bottom_sheet.cr (#13 bottom sheet)
#   widgets/dialog.cr          (#14 mobile AlertDialog)
#   widgets/pull_to_refresh.cr (#15 pull-to-refresh indicator)
#   widgets/swipe_item.cr      (#16 swipe actions / dismissible)
#   containers/pager.cr        (#17 swipe pager)
#   widgets/page_indicator.cr  (#17 page dots)
#   widgets/range_slider.cr    (#18 range slider)
#   widgets/pin_input.cr       (#19 PIN / OTP input)
#   widgets/rating_bar.cr      (#20 rating bar)
#   widgets/circular_progress.cr (#21 circular progress)
#   widgets/skeleton.cr        (#22 skeleton placeholder)
#   widgets/tooltip.cr         (#23 tooltip)
#   containers/safe_area.cr    (#24 safe-area insets wrapper)

require "./switch"
require "./snackbar"
require "./list_tile"
require "./fab"
require "./card"
require "./chip"
require "./badge"
require "./stepper"
require "./avatar"
require "./search_bar"
require "./dialog"
require "./pull_to_refresh"
require "./swipe_item"
require "./page_indicator"
require "./range_slider"
require "./pin_input"
require "./rating_bar"
require "./circular_progress"
require "./skeleton"
require "./tooltip"
require "../containers/bottom_nav"
require "../containers/app_bar"
require "../containers/bottom_sheet"
require "../containers/pager"
require "../containers/safe_area"
