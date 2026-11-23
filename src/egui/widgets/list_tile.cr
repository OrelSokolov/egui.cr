# Mobile List tile (Material 3 `ListItem` / iOS row) — plans/todo/
# mobile_widgets.md #3, Phase 1. The one-row unit of every mobile
# list: an optional leading icon, a bold-ish title, an optional
# subtitle line, and an optional trailing element (icon or a custom
# block — a switch, a chevron, a badge). The whole row is one click
# target; tap is reported through `Response#clicked?`/`changed?`.
#
# Composition: drop tiles into a plain (scrollable) Ui — there is no
# ListView container in v1; virtualized long lists keep riding the
# ScrollArea + virtual-scroll machinery.
#
# Height: the Material floors — 56 with a subtitle (or leading icon),
# 48 text-only — or the taller of content and floor. Width fills the
# available width.
#
# Styling — the `list_tile` class: `height` (floor override),
# `background` (states: true), `title_color`, `subtitle_color`,
# `leading_color`, `trailing_color`, `icon_size` (24), `font_size`,
# `subtitle_font_size` (14), `side_padding` (16), `inner_gap` (16).

module Egui
  class ListTile
    include Widget

    def initialize(@title : String, @subtitle : String? = nil,
                   @leading_icon : Symbol? = nil, id : String? = nil,
                   &trailing : Ui ->)
      @id_name = id
      @trailing = trailing
    end

    # Convenience: no trailing block.
    def initialize(@title : String, @subtitle : String? = nil,
                   @leading_icon : Symbol? = nil, id : String? = nil)
      @id_name = id
      @trailing = nil
    end

    def style_class : String?
      "list_tile"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("height", :number, min: 0.0),
        StyleProp.new("background", :color, states: true),
        StyleProp.new("title_color", :color),
        StyleProp.new("subtitle_color", :color),
        StyleProp.new("leading_color", :color),
        StyleProp.new("trailing_color", :color),
        StyleProp.new("icon_size", :number, min: 0.0),
        StyleProp.new("font_size", :number, min: 0.0),
        StyleProp.new("subtitle_font_size", :number, min: 0.0),
        StyleProp.new("side_padding", :number, min: 0.0),
        StyleProp.new("inner_gap", :number, min: 0.0),
      ]
    end

    def inspector_label : String?
      @title
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      visuals = style.visuals
      vars = style_vars(ui, id)

      font_size = vars.f64("font_size", style.font_size)
      sub_size = vars.f64("subtitle_font_size", font_size - 2.0)
      icon = vars.f64("icon_size", 24.0)
      pad = vars.f64("side_padding", 16.0)
      gap = vars.f64("inner_gap", 16.0)
      fonts, family, bold = ui.ctx.fonts_for_weight(
        style.font_family, style.font_weight, false)
      title_size = fonts.measure(@title, font_size)
      sub = @subtitle
      sub_h = sub ? fonts.measure(sub.not_nil!, sub_size).y : 0.0

      # Material floors: 56 with leading/subtitle/trailing content,
      # 48 for the bare title row.
      floor = vars.f64("height",
        (@leading_icon || sub) ? 56.0 : 48.0)
      content_h = {title_size.y, sub_h, @leading_icon ? icon : 0.0}.max
      h = {floor, content_h + 12.0}.max
      rect = ui.allocate_at_least(Vec2.new(ui.available_width, h))
      rect = Rect.from_min_size(rect.min,
        Vec2.new(ui.available_width, rect.height))
      response = ui.interact(rect, id, Sense.click)

      # Pressed feedback: a faint fill while the finger is down (the
      # ripple's poor cousin — a real ripple is out of v1 scope).
      bg = vars.color?("background")
      if bg
        ui.painter.rect(rect, 0.0, bg)
      elsif response.active?
        ui.painter.rect(rect, 0.0, visuals.button_fill(true, false))
      end

      # Vertical band the text stack centers in.
      text_h = title_size.y + (sub ? 2.0 + sub_h : 0.0)
      text_top = rect.center.y - text_h / 2.0
      x = rect.left + pad
      if (lead = @leading_icon)
        lc = vars.color("leading_color", visuals.text_color)
        Icons.draw(ui.painter, lead,
          Rect.from_min_size(Pos2.new(x, rect.center.y - icon / 2.0),
            Vec2.new(icon, icon)), lc)
        x += icon + gap
      end
      tc = vars.color("title_color", visuals.text_color)
      ui.painter.text(Pos2.new(x, text_top + title_size.y / 2.0), @title,
        font_size, tc, family: family, bold: true)
      if sub
        sc = vars.color("subtitle_color", visuals.text_color)
        ui.painter.text(
          Pos2.new(x, text_top + title_size.y + 2.0 + sub_h / 2.0), sub,
          sub_size, sc, family: family)
      end

      if (trail = @trailing)
        # The trailing block runs flush right, vertically centered.
        # Its width is unknown before the block runs (the cursor flow
        # has no measure primitive), so the strip is a one-item flex
        # row — Flex measures the child, then places it at the right
        # slot (`justify :end`); `align :center` centers it in the row
        # height — the explicit `height:` makes the cross axis
        # definite (an unset height is a content-driven 1e6 region,
        # which would leave the item top-aligned). The strip paints
        # over the row and its widgets keep their own ids/hit targets
        # — a switch inside a row stays individually tappable.
        strip = ui.child_ui(Rect.from_min_size(
          Pos2.new(rect.left, rect.top),
          Vec2.new(rect.width - pad, rect.height)))
        strip.flex(justify: :end, align: :center, height: rect.height) do |f|
          f.child { |c| trail.call(c) }
        end
      end

      response.mark_changed if response.clicked?
      response
    end
  end
end

class Egui::Ui
  # `ui.list_tile(title, subtitle:, leading_icon:, id:) { |row| … }` —
  # the block (if given) draws the trailing element in a right-aligned
  # strip of the row (switch/chevron/badge — its widgets keep their
  # own ids/hit targets). A tap on the row reports `changed?`.
  def list_tile(title : String, subtitle : String? = nil,
                leading_icon : Symbol? = nil, id : String? = nil) : Response
    add(ListTile.new(title, subtitle, leading_icon, id: id))
  end

  def list_tile(title : String, subtitle : String? = nil,
                leading_icon : Symbol? = nil, id : String? = nil,
                &trailing : Ui ->) : Response
    add(ListTile.new(title, subtitle, leading_icon, id: id) { |row|
      trailing.call(row) })
  end
end
