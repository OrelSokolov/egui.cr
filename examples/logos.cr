# Egui::Svg demo — the logo.svg design (letter E) in several variants.
# The SVG source is parsed and painted as vectors, so one slider
# rescales every logo live with no rasterization.

require "../src/egui"
require "../src/egui/backend/sokol"
require "./icon"
require "./logo_variants"

class LogosApp < Egui::App
  @size = 96.0_f64

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("logo.svg variants — Egui::Svg widget")
      ui.label("#{LOGO_VARIANTS.size} variants with the letter E, vector-rendered from SVG source.")
      ui.separator
      ui.horizontal do |row|
        row.label("size:")
        row.slider(@size, 24.0..256.0) { |v| @size = v }
        row.label("#{"%.0f" % @size} px")
      end
      ui.separator
      ui.scroll_area do |scroll|
        LOGO_VARIANTS.each_slice(3) do |chunk|
          scroll.columns(3) do |cols|
            cols.each_with_index do |col, i|
              if variant = chunk[i]?
                name, source = variant
                col.label(name)
                col.svg(source, Egui::Vec2.new(@size, @size))
              end
            end
          end
        end
      end
    end
  end
end

Egui::Backend::Sokol.run(LogosApp.new, title: "egui-cr — logo.svg variants",
  width: 900, height: 700,
  icon: {rgba: ICON_64_RGBA, width: 64, height: 64}, inspector: :hidden)
