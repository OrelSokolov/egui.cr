# egui-cr demo: the lucide icon provider (`icons/lucide`, ISC).
#
# `Egui::Icon.from_file(provider, name, tint:)` needs the provider
# and name as LITERALS at the call site — the macro reads the SVG
# file at compile time — so the gallery below is unrolled with
# {% for %} over compile-time data. That is exactly like handwritten
# per-icon calls: one referenced file per button, nothing else lands
# in the binary (the provider folder on disk ships all 1856 icons).

require "../src/egui"
require "../src/egui/backend/sokol"

class LucideIconsApp < Egui::App
  # Rows of six — they map straight to horizontal button rows below.
  # Icon names use `_` where the file name has a `-`
  # (:volume_2 → volume-2.svg, :triangle_alert → triangle-alert.svg).
  SECTIONS = [
    {"Files & editing", [
       [:save, :folder, :folder_open, :copy, :clipboard, :pencil],
       [:trash, :download, :upload, :file_text, :calendar, :mail],
     ]},
    {"Navigation & system", [
       [:search, :settings, :user, :menu, :ellipsis, :eye],
       [:arrow_right, :external_link, :log_out, :power, :house, :lock],
     ]},
    {"Media", [
       [:play, :pause, :skip_forward, :volume_2, :music],
       [:camera, :image, :star, :heart, :bell],
     ]},
    {"Symbols", [
       [:check, :x, :plus, :minus, :info, :triangle_alert],
       [:sun, :moon, :refresh_cw, :terminal],
     ]},
  ]

  def update(ctx : Egui::Context) : Nil
    ctx.window("lucide icons", Egui::Pos2.new(40.0, 40.0), width: 640.0) do |ui|
      total = SECTIONS.sum { |_, rows| rows.sum(&.size) }
      ui.label("#{total} icons embedded at compile time — only the referenced files land in the binary")
      ui.scroll_area(max_height: 480.0) do |scroll|
        {% for section in SECTIONS %}
          scroll.heading({{ section[0] }})
          {% for row in section[1] %}
            scroll.horizontal do |row|
              fg = row.style.visuals.text_color
              {% for name in row %}
                row.add(Egui::Button.new({{ name.stringify }})
                  .icon(Egui::Icon.from_file(:lucide, {{ name }}, tint: fg)))
              {% end %}
            end
          {% end %}
        {% end %}

        # Icon-only buttons: empty label — the icon box sizes the
        # button (Button falls back to the estimated line height).
        scroll.heading("Icon-only buttons")
        scroll.horizontal do |row|
          fg = row.style.visuals.text_color
          {% for name in [:play, :pause, :skip_forward, :star, :heart, :bell, :terminal, :power] %}
            row.add(Egui::Button.new("")
              .icon(Egui::Icon.from_file(:lucide, {{ name }}, tint: fg)))
          {% end %}
        end

        # One icon, several tints: each color parses (and caches) its
        # own copy, resolving the set's `currentColor`. Tint is a
        # runtime value — only the icon name has to be a literal.
        scroll.heading("Tints")
        scroll.horizontal do |row|
          [Egui::Color32.rgb(30, 30, 30), Egui::Color32.rgb(200, 40, 40),
           Egui::Color32.rgb(40, 160, 60), Egui::Color32.rgb(40, 100, 220),
           Egui::Color32.rgb(240, 170, 20)].each do |color|
            row.add(Egui::Button.new("")
              .icon(Egui::Icon.from_file(:lucide, :star, tint: color)))
          end
        end
      end
    end
  end
end

Egui::Backend::Sokol.run(LucideIconsApp.new, title: "egui-cr — lucide icons")
