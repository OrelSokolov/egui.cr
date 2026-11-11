# egui.cr html positions — entry point: runs the HtmlPositionsApp
# defined in examples/html_positions_components/html_positions_app.cr.

require "../src/egui/driver_selector"
require "./html_positions_components/html_positions_app"

Egui.run(HtmlPositionsApp.new, title: "egui.cr — html positions",
  width: 900, height: 620,
  icon: {rgba: ICON_64_RGBA, width: 64, height: 64}, inspector: :hidden)
