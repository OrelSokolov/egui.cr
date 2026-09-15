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

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      visuals = style.visuals
      font_size = style.font_size
      pad = style.spacing.button_padding

      sizes = @labels.map { |l| ui.ctx.fonts.measure(l, font_size) }
      height = {sizes.map(&.y).max + 2 * pad.y,
        style.spacing.interact_size.y}.max

      # The joined look: one cell per label, no gap between them, every
      # cell as wide as the widest label so segments are even.
      cell_w = sizes.map(&.x).max + 2 * pad.x
      rect = ui.allocate_at_least(
        Vec2.new(cell_w * @labels.size, height))
      id = ui.next_widget_id

      result : Response? = nil
      @labels.each_with_index do |label, i|
        cell = Rect.from_min_size(
          Pos2.new(rect.left + i * cell_w, rect.top),
          Vec2.new(cell_w, height))
        cell_id = id.child(i.to_u64 + 1)
        response = ui.interact(cell, cell_id, Sense.click)

        selected = i == @selected
        if selected
          ui.painter.rect(cell, 4.0, visuals.selection_fill)
        elsif response.hovered?
          ui.painter.rect(cell, 4.0,
            visuals.fade_color(visuals.selection_fill, 0.4))
        end
        text_size = sizes[i]
        ui.painter.text(
          Pos2.new(cell.left + (cell_w - text_size.x) / 2.0, cell.center.y),
          label, font_size, visuals.text_color)

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
