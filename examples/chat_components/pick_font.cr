# Shared entry-point helper: the monospace stack the chat apps use.
# Lives in components so both entry points (examples/chat.cr,
# examples/chat_100k.cr) pick the same faces; required ONLY from entry
# points (it touches Egui::Driver::Sokol, which the headless bench
# build never pulls in).
#
# DejaVu Sans Mono primary (the terminal's own face), Noto Sans
# Symbols2 as the fallback that owns the braille spinner glyphs (the
# mono faces don't carry U+28xx).
def pick_terminal_font : Nil
  candidates = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/ubuntu/UbuntuMono-R.ttf",
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "C:\\Windows\\Fonts\\consola.ttf",
    "C:\\Windows\\Fonts\\lucon.ttf",
  ]
  fallbacks = [
    "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
    "/usr/share/fonts/truetype/freefont/FreeMono.ttf",
  ]
  primary = candidates.find { |c| File.exists?(c) }
  return unless primary
  paths = [primary] + fallbacks.select { |c| File.exists?(c) }
  font = Egui::Driver::Sokol.fonts_from_system(paths)
  Egui::Driver::Sokol.select_fonts(font) if font
end
