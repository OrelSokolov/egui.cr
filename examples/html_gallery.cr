# egui-cr html gallery — entry point: runs the HtmlGalleryApp defined
# in examples/html_gallery_components/html_gallery_app.cr.

require "../src/egui/driver_selector"
require "./html_gallery_components/html_gallery_app"

Egui.run(HtmlGalleryApp.new, title: "egui.cr — html gallery",
  width: 1100, height: 800,
  icon: {rgba: ICON_64_RGBA, width: 64, height: 64}, inspector: :hidden)
