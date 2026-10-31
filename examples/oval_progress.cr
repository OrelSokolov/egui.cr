# OvalProgress demo — the pill progress bar component
# (assets/components/oval_progress.exml) driven from an exml document:
# a slider-bound instance, an animated one, static variants and a
# live color inspector (three color_edit32 pickers driving the
# component's three color parameters through the store).
# Run from the repo root: crystal run examples/oval_progress.cr

require "../src/egui/backend_selector"
require "./oval_progress_components/oval_progress"

DEMO_EXML = <<-EXML
<exml>
  <page id="root/root" title="OvalProgress">
    <central>
      <heading text="OvalProgress"/>
      <label text="slider-driven: {demo}"/>
      <oval_progress frac="{demo}" height="14"/>
      <separator/>
      <label text="animated wave: {wave}"/>
      <oval_progress frac="{wave}" height="22" pad="3"
                     from="#f9b8a8" to="#d9452b"/>
      <separator/>
      <oval_progress frac="0.25" height="10" pad="1"/>
      <oval_progress frac="0.55" height="18" pad="4"
                     track="#e8ecf2" from="#a2f0c1" to="#0f9d58"/>
      <oval_progress frac="0.8" height="30" pad="5"
                     from="#f7d794" to="#e8a020"/>
      <separator/>
      <label text="colors — live, from the inspector panel below"/>
      <oval_progress frac="0.72" height="20" pad="3"
                     track="{c_track}" from="{c_from}" to="{c_to}"/>
      <separator/>
      <slider bind="demo" min="0" max="1"/>
    </central>
  </page>
</exml>
EXML

class OvalProgressDemo < Egui::App
  @renderer = Egui::Exml::Renderer.new
  @rt = Egui::Exml::Runtime.new
  @exml : Egui::Exml::Document
  @t = 0.0

  def initialize
    super
    @exml = Egui::Exml.parse(DEMO_EXML)
    # oval_strip is global (the `widget` registry); oval_progress is a
    # per-renderer component — the linter needs it listed.
    Egui::Exml.validate(@exml, known_custom: %w(oval_progress))
      .each { |issue| STDERR.puts "exml: #{issue}" }
    @renderer.component(OvalProgress.new)
    @rt.floats["demo"] = 0.35
    # the inspector panel's current colors (start at the defaults)
    @rt.strings["c_track"] = "#43454c"
    @rt.strings["c_from"] = "#7fd0f9"
    @rt.strings["c_to"] = "#1667d9"
  end

  def update(ctx : Egui::Context) : Nil
    # the animated wave needs frames even without input
    @t += ctx.input.dt
    @rt.floats["wave"] = (Math.sin(@t * 2.0) + 1.0) / 2.0
    ctx.request_repaint
    @renderer.render_routes(ctx, @exml, @rt)
    color_inspector(ctx)
  end

  # The three color parameters, editable live: pickers write "#hex"
  # slots, the markup interpolates them into the preview bar. The row
  # scrolls horizontally — a color edit is ~250px wide, three don't
  # always fit the window. No max_height: the viewport fills whatever
  # the panel gives it, re-measured every frame (drag the panel edge
  # and the scroll height follows).
  private def color_inspector(ctx : Egui::Context) : Nil
    ctx.bottom_panel("colors") do |ui|
      ui.scroll_area(hbar: :bottom) do |row|
        row.horizontal(wrap: false) do |h|
          {"c_track" => "track", "c_from" => "from",
           "c_to" => "to"}.each do |slot, name|
            h.label(name)
            h.color_edit32(demo_color(@rt.strings[slot]?)) do |c|
              @rt.strings[slot] = "##{c.r.to_s(16).rjust(2, '0')}" \
                                  "#{c.g.to_s(16).rjust(2, '0')}" \
                                  "#{c.b.to_s(16).rjust(2, '0')}"
            end
            h.label("  ")
          end
        end
      end
    end
  end

  private def demo_color(hex : String?) : Egui::Color32
    if (s = hex) && s.size == 7 &&
       (r = s[1, 2].to_u8?(16)) && (g = s[3, 2].to_u8?(16)) &&
       (b = s[5, 2].to_u8?(16))
      Egui::Color32.new(r, g, b, 255_u8)
    else
      Egui::Color32.rgb(0xd9, 0xd9, 0xd9)
    end
  end
end

Egui.run(OvalProgressDemo.new, title: "egui.cr — OvalProgress",
  inspector: :hidden)
