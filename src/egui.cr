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
require "./egui/layer"
require "./egui/id"
require "./egui/sense"
require "./egui/input"
require "./egui/state"
require "./egui/memory"
require "./egui/painter"
require "./egui/fonts"
require "./egui/style"
require "./egui/response"
require "./egui/layout"
require "./egui/widgets/widget"
require "./egui/widgets/label"
require "./egui/widgets/button"
require "./egui/widgets/collapsing_header"
require "./egui/ui"
require "./egui/app"
require "./egui/context"
