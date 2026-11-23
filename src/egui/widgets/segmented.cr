# SegmentedControl — a one-of-many selector drawn as a joined row of
# selectable labels (the "tab-like radio" egui itself has no in-tree
# widget for; egui_demo_lib hand-rolls one from `SelectableLabel`).
#
# The chosen index rides `Response#widget_value` (like Slider does), so
# the block helper `Ui#segmented(selected, labels) { |i| … }` hands it
# straight back to app state.
#
# Two paint modes, picked by the `segmented` class rule: default is one
# container capsule with an inset selection (the macOS look); a rule
# that sets `stroke` switches to the LINKED-BUTTON look — every cell is
# its own bordered button (`background`/`background2` gradient, rounded
# only at the strip's ends), the platform idiom where a segmented is a
# row of toggle buttons (Windows XP, GNOME, KDE).

module Egui
  class SegmentedControl
    include Widget

    def initialize(@selected : Int32, @labels : Array(String))
    end

    # Styled through the `segmented` class: `padding`, `rounding`,
    # `background` (container), `selection_fill` (selected segment).
    # The linked-button mode adds `stroke` (the per-cell border — its
    # presence switches modes), `background2` (cell gradient) and the
    # `selection_*` twins for the checked cell.
    def style_class : String?
      "segmented"
    end

    def style_properties : Array(StyleProp)
      StyleProps.sizable + [
        StyleProp.new("padding", :box),
        StyleProp.new("rounding", :number, fallback: 6.0, min: 0.0),
        StyleProp.new("background", :color, states: true),
        StyleProp.new("background2", :color, states: true),
        StyleProp.new("stroke", :color, states: true),
        # Container border width (0 = borderless, the iOS look).
        StyleProp.new("stroke_width", :number, min: 0.0, fallback: 1.0),
        StyleProp.new("selection_fill", :color),
        StyleProp.new("selection_background2", :color),
        StyleProp.new("selection_text", :color),
        StyleProp.new("shadow.color", :color, states: true),
        StyleProp.new("shadow.blur", :number, min: 0.0),
        StyleProp.new("shadow.y", :number),
      ]
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      visuals = style.visuals
      font_size = style.font_size
      id = ui.next_widget_id
      class_vars = style_vars(ui, id)

      sizes = @labels.map { |l| ui.ctx.fonts_for(style.font_family).measure(l, font_size) }
      bp = style.spacing.button_padding
      pad = class_vars.box?("padding") ||
            StyleBox.new(bp.y, bp.x, bp.y, bp.x)
      height = {sizes.map(&.y).max + pad.vertical,
        style.spacing.interact_size.y}.max

      # The joined look: one cell per label, no gap between them, every
      # cell as wide as the widest label so segments are even.
      cell_w = sizes.map(&.x).max + pad.horizontal
      natural_w = cell_w * @labels.size
      # `width`/`height` overrides stretch the strip; the extra width
      # distributes EVENLY over the cells (the iOS full-width segmented
      # — cells stay equal, not packed left).
      rect = ui.allocate_at_least(
        styled_size(Vec2.new(natural_w, height), class_vars, ui, id))
      cell_w = rect.width / @labels.size if rect.width > natural_w
      rounding = class_vars.rounding_px("rounding", rect, 6.0)

      # Linked-button mode: a `stroke` key means the class rule styles
      # each CELL as a button (borders, gradient) instead of one bezel
      # capsule — see the class comment.
      cell_stroke = class_vars.color?("stroke")

      unless cell_stroke
        # Container capsule behind the cells (macOS paints one bezel; a
        # plain panel-colored host leaves the unselected half invisible).
        # The stroke width is stylable — `stroke_width: 0` gives the
        # borderless iOS "strong" segmented.
        ui.painter.rect(rect, rounding,
          class_vars.color("background",
            visuals.button_fill(false, false)),
          visuals.button_stroke,
          class_vars.f64("stroke_width", 1.0),
          corners: class_vars.rounding_corners?("rounding", rect))
      end

      result : Response? = nil
      @labels.each_with_index do |label, i|
        cell = Rect.from_min_size(
          Pos2.new(rect.left + i * cell_w, rect.top),
          Vec2.new(cell_w, height))
        cell_id = id.child(i.to_u64 + 1)
        response = ui.interact(cell, cell_id, Sense.click)

        selected = i == @selected
        first = i == 0
        last = i == @labels.size - 1
        # Linked buttons round only the strip's outer ends.
        corners = CornerRadii.new(
          first ? rounding : 0.0, last ? rounding : 0.0,
          last ? rounding : 0.0, first ? rounding : 0.0)

        if cell_stroke
          if selected
            ui.painter.rect(cell,
              fill: class_vars.color("selection_fill",
                visuals.selection_fill),
              fill2: class_vars.color?("selection_background2"),
              stroke_color: cell_stroke, stroke_width: 1.0,
              corners: corners)
          else
            fill = class_vars.color("background",
              visuals.button_fill(false, false))
            ui.painter.rect(cell, fill: fill,
              fill2: class_vars.color?("background2"),
              stroke_color: cell_stroke, stroke_width: 1.0,
              corners: corners)
            if response.hovered?
              hover_vars = style_vars(ui, cell_id, "hover")
              if (hot = hover_vars.color?("background")) &&
                 hot != class_vars.color?("background")
                # An explicit `segmented:hover` rule — repaint the whole
                # cell in its hot colors (e.g. the XP orange glow).
                ui.painter.rect(cell, fill: hot,
                  fill2: hover_vars.color?("background2"),
                  stroke_color: hover_vars.color("stroke", cell_stroke),
                  stroke_width: 1.0, corners: corners)
              else
                ui.painter.rect(cell, rounding,
                  visuals.fade_color(fill, 0.4))
              end
            end
          end
        elsif selected
          # Selected segment: accent-filled, inset a hair inside the
          # container so the capsule's outer rounding stays visible.
          # `shadow.*` styles the pill (the iOS white-selected look is
          # a raised white pill over the gray bezel).
          inset = 2.0
          seg_rounding = {rounding - inset, 0.0}.max
          seg = Rect.from_min_size(
            Pos2.new(cell.left + (i == 0 ? inset : 0.0), cell.top + inset),
            Vec2.new(cell.width - (i == 0 ? inset : 0.0) -
                     (i == @labels.size - 1 ? inset : 0.0),
                     height - 2.0 * inset))
          if (s = class_vars.shadow?)
            ui.painter.box_shadow(seg, s.color, s.blur, seg_rounding,
              s.spread, s.offset)
          end
          ui.painter.rect(seg, seg_rounding,
            class_vars.color("selection_fill", visuals.selection_fill))
        elsif response.hovered?
          ui.painter.rect(cell, rounding,
            visuals.fade_color(visuals.button_fill(false, false), 0.4))
        end
        text_size = sizes[i]
        text_color = if selected
                       class_vars.color?("selection_text") ||
                         (class_vars.color?("selection_fill") ?
                            Color32.rgb(255, 255, 255) : visuals.text_color)
                     else
                       visuals.text_color
                     end
        ui.painter.text(
          Pos2.new(cell.left + (cell_w - text_size.x) / 2.0, cell.center.y),
          label, font_size, text_color,
          family: style.font_family)

        if response.clicked?
          response.widget_value = i.to_f64
          response.mark_changed
          result = response
        end
        result ||= response
      end

      # Something went very wrong (empty labels?) — mint a dead response.
      result = ui.interact(rect, id, Sense.click) if result.nil?
      result.not_nil!
    end
  end
end
