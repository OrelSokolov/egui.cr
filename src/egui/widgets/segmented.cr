# SegmentedControl — a one-of-many selector drawn as a joined row of
# selectable labels (the "tab-like radio" egui itself has no in-tree
# widget for; egui_demo_lib hand-rolls one from `SelectableLabel`).
#
# The chosen index rides `Response#widget_value` (like Slider does), so
# the block helper `Ui#segmented(selected, labels) { |i| … }` hands it
# straight back to app state.

module Egui
  class SegmentedControl
    include Widget

    def initialize(@selected : Int32, @labels : Array(String))
    end

    # Styled through the `segmented` class: `padding`, `rounding`,
    # `background` (container), `selection_fill` (selected segment).
    def style_class : String?
      "segmented"
    end

    def style_properties : Array(StyleProp)
      StyleProps.sizable + [
        StyleProp.new("padding", :box),
        StyleProp.new("rounding", :number, fallback: 6.0, min: 0.0),
        StyleProp.new("background", :color),
        StyleProp.new("selection_fill", :color),
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
      rect = ui.allocate_at_least(
        Vec2.new(cell_w * @labels.size, height))
      rounding = class_vars.rounding_px("rounding", rect, 6.0)

      # Container capsule behind the cells (macOS paints one bezel; a
      # plain panel-colored host leaves the unselected half invisible).
      ui.painter.rect(rect, rounding,
        class_vars.color("background",
          visuals.button_fill(false, false)),
        visuals.button_stroke, 1.0,
        corners: class_vars.rounding_corners?("rounding", rect))

      result : Response? = nil
      @labels.each_with_index do |label, i|
        cell = Rect.from_min_size(
          Pos2.new(rect.left + i * cell_w, rect.top),
          Vec2.new(cell_w, height))
        cell_id = id.child(i.to_u64 + 1)
        response = ui.interact(cell, cell_id, Sense.click)

        selected = i == @selected
        if selected
          # Selected segment: accent-filled, inset a hair inside the
          # container so the capsule's outer rounding stays visible.
          inset = 2.0
          seg = Rect.from_min_size(
            Pos2.new(cell.left + (i == 0 ? inset : 0.0), cell.top + inset),
            Vec2.new(cell.width - (i == 0 ? inset : 0.0) -
                     (i == @labels.size - 1 ? inset : 0.0),
                     height - 2.0 * inset))
          ui.painter.rect(seg, {rounding - inset, 0.0}.max,
            class_vars.color("selection_fill", visuals.selection_fill))
        elsif response.hovered?
          ui.painter.rect(cell, rounding,
            visuals.fade_color(visuals.button_fill(false, false), 0.4))
        end
        text_size = sizes[i]
        ui.painter.text(
          Pos2.new(cell.left + (cell_w - text_size.x) / 2.0, cell.center.y),
          label, font_size,
          selected && class_vars.color?("selection_fill") ?
            Color32.rgb(255, 255, 255) : visuals.text_color,
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
