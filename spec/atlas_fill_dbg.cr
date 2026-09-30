# Headless repro of the inspector font_size drag, WITH the atlas reset:
# walk a full-frame charset across fractional sizes; whenever the atlas
# overflows, reset + re-bake (like sokol.cr's touch loop). At the end,
# after a final reset, every letter must render again (no cached blanks).

require "../src/egui/backend/sokol"

paths = Egui::SystemPorts::Fonts.search_paths
fonts = Egui::Backend::Sokol.fonts_from_system(paths)
abort "no system font" unless fonts
puts "backend: #{fonts.class}"

# Charset of the demo UI + inspector panel, spaces excluded (a space is
# a legitimate blank glyph; a dropped letter is indistinguishable from
# it in the Glyph struct).
text = "ИнспекторстилейПравыйкликполюбомувиджетуInspectF12панель" \
       "КнопкиявныеidСохранитьОтменаБезautoслучайныхбуквПрочее" \
       "eguiinspirationЧекбоксСкоростьПрогрессВыбранныйпунктТумблер" \
       "Не-стилизуемыйвиджетspinnerнетstylable-свойствЭлементКласс" \
       "СвойствоЗначениеfont_sizefillhoveractive0123456789.,:;()[]{}"

resets = 0
size = 9.0
while size <= 40.0
  fonts.walk(text, size) { |_p, _g| } # one "frame" at this size
  if fonts.reset_if_full
    resets += 1
    fonts.walk(text, size) { |_p, _g| } # re-bake, like the touch loop
  end
  size += 0.1
end

# After a final reset every glyph at a representative size must have
# real coverage — letters no longer stay dropped.
fonts.walk(text, 16.0) { |_p, _g| }
final_reset = fonts.reset_if_full
blanks = 0
fonts.walk(text, 16.0) do |_p, g|
  blanks += 1 if g.w == 0 || g.h == 0
end
puts "sizes 9.0..40.0 (0.1 step): resets=#{resets + (final_reset ? 1 : 0)}"
puts "blank glyphs at size 16 after final reset: #{blanks} (must be 0)"
exit 1 unless blanks == 0
