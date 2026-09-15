# Headless FreeType smoke test: load the macOS system font through
# FreetypeFonts, rasterize glyphs in both hinting modes, print metrics.
require "../src/egui/backend/sokol"

paths = Egui::SystemPorts::Fonts.search_paths
font = Egui::Backend::FreetypeFonts.from_system(paths)
unless font
  puts "FAIL: FreetypeFonts did not load any of #{paths}"
  exit 1
end
puts "loaded=#{font.loaded?} hinted=#{font.hinted?}"

{12.0, 16.0, 24.0}.each do |size|
  asc, desc = font.metrics_at(size)
  w = font.measure("Handgloves handgloves 0123", size)
  puts "size=#{size} asc=#{asc.round(2)} desc=#{desc.round(2)} " \
       "line=#{(asc - desc).round(2)} width=#{w.x.round(2)}"
end

puts "\n-- smooth (default on darwin) --"
font.debug_bitmap('A', 16)
puts
font.debug_bitmap('e', 16)

puts "\n-- hinted --"
font.hinted = true
font.debug_bitmap('A', 16)
puts
font.debug_bitmap('e', 16)
