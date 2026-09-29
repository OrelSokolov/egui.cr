# Headless benchmark of the lucide icon catalog (see
# examples/icons_browser.cr): same app, same viewport culling, driven
# by Egui::Bench instead of the sokol backend. Measures the CPU part
# of a frame BEFORE any FFI/GPU work — where the Crystal side of
# "cursor moves over a full screen of icons" actually spends its time.
#
#   crystal build bench/lucide_bench.cr -o bin/lucide_bench \
#     --link-flags "-L$(pwd)/lib" && ./bin/lucide_bench
#
# The real font backend (FreeType, light-hint fallback) is mandatory:
# the headless monospace estimate would make measure() free and the
# bench would measure a different program than the one shipping.
# LUCIDE_NO_CULL=1 stress mode is honored like in the example.

require "../src/egui"
require "../src/egui/backend/sokol"

class LucideIconsApp < Egui::App
  CELL_W = 116.0
  BUTTON_H = 64.0
  ICON_FONT = 34.0
  CAPTION_FONT = 13.0

  ICONS = {{ begin
    files = `ls -1 #{__DIR__}/../icons/lucide/*.svg`
    files.split("\n").select { |f| f.size > 0 }.sort.map do |f|
      {f.split("/")[-1].split(".")[0], read_file(f)}
    end
  end }}

  @query = ""
  @fps = 0.0
  @hotkeys_ready = false
  @focus_search = false

  def update(ctx : Egui::Context) : Nil
    if (dt = ctx.input.dt) > 0.0
      target = 1.0 / dt
      @fps = @fps > 0.0 ? @fps + (target - @fps) * 0.15 : target
    end
    ctx.request_repaint

    unless @hotkeys_ready
      ctx.hotkeys.bind("Ctrl+F", ACTION_FOCUS_SEARCH)
      @hotkeys_ready = true
    end
    if ctx.consume_action(ACTION_FOCUS_SEARCH)
      @focus_search = true
      ctx.request_repaint
    end

    ctx.menu_bar do |bar|
      bar.menu_button("Debug") do |menu|
        menu.menu_item("Show FPS") { }
      end
    end

    ctx.central_panel do |ui|
      fg = ui.style.visuals.text_color
      q = @query.downcase.gsub(/[\s_]+/, "-")
      matches = q.empty? ? ICONS : ICONS.select { |name, _| name.includes?(q) }

      ui.horizontal do |row|
        row.add(Egui::Button.new("")
          .icon(Egui::Icon.from_file(:lucide, :search, tint: fg)))
        search = row.text_edit_singleline(@query, hint: "search #{ICONS.size} icons…",
          focus_id: "lucide-search") { |t| @query = t }
        search.request_focus if @focus_search
        @focus_search = false
        row.label("#{matches.size}/#{ICONS.size}")
      end
      ui.separator

      ui.scroll_area do |scroll|
        if matches.empty?
          scroll.label("no icons match #{@query.inspect}")
          next
        end
        gap = scroll.style.spacing.item_spacing.y
        row_h = BUTTON_H + gap + CAPTION_FONT * Egui::Fonts::LINE_H_FACTOR
        clip = scroll.painter.clip
        n = {(scroll.available_width / CELL_W).floor.to_i, 1}.max
        no_cull = ENV["LUCIDE_NO_CULL"]? == "1"
        matches.each_slice(n) do |slice|
          y = scroll.cursor.y
          if !no_cull &&
             (y + row_h < clip.min.y - row_h || y - row_h > clip.max.y)
            scroll.allocate_space(Egui::Vec2.new(0.0, row_h))
          else
            scroll.columns(n) do |cols|
              cols.each_with_index do |col, i|
                next unless (icon = slice[i]?)
                name, source = icon
                col.add_sized(Egui::Vec2.new(col.available_width, BUTTON_H),
                  Egui::Button.new("")
                    .icon(Egui::Icon.cached("lucide", name, fg, source))
                    .style { |s| s.font_size = ICON_FONT }
                )
                col.add(Egui::Label.new(caption(ctx, name, col.available_width),
                  size: CAPTION_FONT, wrap: false, userselect: false))
              end
            end
          end
        end
      end

      text = "#{"%.0f" % @fps} fps · #{"%.1f" % (1000.0 / @fps)} ms"
      w = ctx.fonts.measure(text, 14.0).x
      ui.painter.text(Egui::Pos2.new(ui.max_rect.right - w - 12.0,
        ui.max_rect.min.y + 20.0), text, 14.0, fg)
    end
  end

  ACTION_FOCUS_SEARCH = Egui::HotkeyAction.new("lucide.focus_search")

  private def caption(ctx : Egui::Context, name : String,
                      max_w : Float64) : String
    text = name.gsub("-", "_")
    return text if ctx.fonts.measure_cached(text, CAPTION_FONT).x <= max_w
    cut = text.size
    while cut > 1 &&
          ctx.fonts.measure_cached(text[0, cut] + "…", CAPTION_FONT).x > max_w
      cut -= 1
    end
    text[0, cut] + "…"
  end
end

# Real font stack, like Sokol#on_init picks one.
paths = Egui::SystemPorts::Fonts.search_paths
font = Egui::Backend::FreetypeFonts.from_system(paths) ||
       Egui::Backend::LightHintedFonts.from_system(paths)
if font
  puts "fonts: #{font.class.name}"
else
  puts "fonts: NONE — headless monospace estimate (measure() unrealistic)"
end

app = LucideIconsApp.new
app.ctx.fonts = font if font

width = (ENV["BENCH_W"]? || "1920").to_f64
height = (ENV["BENCH_H"]? || "1080").to_f64

# The scenario from the bug report: nothing happens except the cursor
# moving over a full screen of icons. The bench's default injected
# mouse move covers it (moves hover/interact each frame like the real
# event stream would).
Egui::Bench.run(app, width: width, height: height, warmup: 5, frames: 20)
