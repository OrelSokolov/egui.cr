# egui-cr — immediate-mode GUI for Crystal.
#
# A 1:1 architectural port of egui (Rust):
#
#   RawInput → Context#begin_frame → app update (Ui, widgets) →
#   Context#end_frame → paint commands → backend (sokol_gfx)
#
# The core (this file tree, minus backend/) is platform-pure and
# headless-testable; only src/egui/backend touches native code.

require "set"

require "./egui/math"
require "./egui/color"
require "./egui/smart_aim"
require "./egui/galley"
require "./egui/rich_text"
require "./egui/textures"
require "./egui/layer"
require "./egui/id"
require "./egui/sense"
require "./egui/input"
require "./egui/state"
require "./egui/memory"
require "./egui/painter"
require "./egui/fonts"
require "./egui/cursor_icon"
require "./egui/style"
require "./egui/response"
require "./egui/layout"
require "./egui/widgets/icons"
require "./egui/widgets/widget"
require "./egui/widgets/label"
require "./egui/widgets/button"
require "./egui/widgets/checkbox"
require "./egui/widgets/radio_button"
require "./egui/widgets/separator"
require "./egui/widgets/progress_bar"
require "./egui/widgets/spinner"
require "./egui/widgets/hyperlink"
require "./egui/widgets/slider"
require "./egui/widgets/drag_value"
require "./egui/widgets/text_edit"
require "./egui/widgets/image"
require "./egui/widgets/color_picker"
require "./egui/widgets/collapsing_header"
require "./egui/containers/combo_box"
require "./egui/containers/menu"
require "./egui/containers/scroll_area"
require "./egui/ui"
require "./egui/app"
require "./egui/context"
