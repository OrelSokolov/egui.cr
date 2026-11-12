# egui-cr chat — entry point for the h2code TUI two-zone model port.
# The app itself lives in examples/chat_components/chat_app.cr (also
# driven headless by bench/chat_bench.cr): monospace, the TUI dark
# palette, braille spinner, ┃ streaming bar, pulsing CI circle.

require "../src/egui/driver_selector"
require "./chat_components/chat_app"
require "./chat_components/pick_font"

pick_terminal_font

app = ChatApp.new
app.welcome!
Egui.run(app, title: "h2code — chat (двухзонная модель)",
  width: 760, height: 580, inspector: :hidden)
