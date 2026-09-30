# Port of egui_upstream/crates/egui/src/containers/combo_box.rs.
#
# A closed set of String options: a button showing the current
# selection that opens the shared popup system (Foreground layer,
# closes on outside click) with one item per option. Rendering
# flavors: `variant(:button|:plain|:field)`, `overlay` (the list opens
# on top of the button, GTK3-style) and `label("Select option")` — a
# placeholder for the empty selection that also leads the list as the
# zero option (picking it clears back to "").

module Egui
  class ComboBox
    # Rendering flavors for the closed combo:
    #   :button — solid button, the chevron in a separated sub-button
    #             strip (native dropdown look)
    #   :plain  — one rigid solid button, chevron inline at the right
    #             edge — no separation
    #   :field  — text-input look with a raised select button pinned to
    #             the right edge (editable-combo look)
    # `label` pins a placeholder shown while NOTHING is selected
    # (`selected == ""`, GTK3-style "Select option"); once an option is
    # picked it takes the button. The placeholder also leads the popup
    # list as the zero option — picking it clears the selection.
    # `overlay: true` opens the list right ON TOP of the button
    # (GTK3-style) instead of below it.
    # `width` overrides the natural size; `nil` (the default) fits the
    # button to the widest entry plus the arrow zone.
    def initialize(@id : String, @selected : String,
                   @options : Array(String), @width : Float64? = nil,
                   @variant : Symbol = :button, @label : String? = nil,
                   @overlay : Bool = false)
    end

    def variant(v : Symbol) : self
      @variant = v
      self
    end

    def label(text : String) : self
      @label = text
      self
    end

    def overlay(flag : Bool = true) : self
      @overlay = flag
      self
    end

    # `on_select` fires with the picked option; returns whether a new
    # option got picked this frame.
    def show(ui : Ui, &on_select : String ->) : Bool
      style = ui.style
      font_size = style.font_size
      # Placeholder while nothing is picked; the selection takes over
      # as soon as one exists.
      display = @selected.empty? ? @label : @selected
      display ||= ""
      fonts = ui.ctx.fonts_for(style.font_family)
      text_size = fonts.measure(display, font_size)
      glyph_h = text_size.y > 0.0 ? text_size.y : font_size * Fonts::LINE_H_FACTOR

      # Native dropdown geometry: the button is as wide as its widest
      # entry (any option or the displayed text) plus padding and the
      # arrow zone, and as tall as a regular button.
      arrow_h = font_size * 0.6
      arrow_zone = arrow_h + 2 * style.spacing.button_padding.x
      if (w = @width)
        width = w
      else
        widest = text_size.x
        @options.each do |option|
          widest = {widest, fonts.measure(option, font_size).x}.max
        end
        width = widest + 2 * style.spacing.button_padding.x + arrow_zone
      end
      height = {glyph_h + 2 * style.spacing.button_padding.y,
        style.spacing.interact_size.y}.max
      rect = ui.allocate_at_least(Vec2.new(width, height))
      id = ui.next_widget_id
      response = ui.interact(rect, id, Sense.click)

      visuals = style.visuals
      pad_x = style.spacing.button_padding.x
      # The placeholder reads as a hint — faded like TextEdit's.
      text_color = @selected.empty? && @label ? visuals.fade_color(visuals.text_color, 0.55) : visuals.text_color

      case @variant
      when :field
        # Idle text-field frame (TextEdit's look)…
        ui.painter.rect(rect, 4.0, visuals.button_weak,
          visuals.button_stroke, 1.0)
        # …with a raised select button pinned inside the right edge.
        btn = Rect.from_min_size(
          Pos2.new(rect.right - 1.0 - arrow_zone, rect.top + 1.0),
          Vec2.new(arrow_zone, rect.height - 2.0))
        ui.painter.rect(btn, 3.0,
          visuals.button_fill(response.hovered?, response.active?),
          visuals.button_stroke, 1.0)
        arrow_box = Rect.from_min_size(
          Pos2.new(btn.center.x - arrow_h / 2.0,
            rect.center.y - arrow_h / 2.0),
          Vec2.new(arrow_h, arrow_h))
      when :plain
        # One rigid piece: no strip, the chevron sits at the right edge.
        ui.painter.rect(rect, 3.0,
          visuals.button_fill(response.hovered?, response.active?),
          visuals.button_stroke, 1.0)
        arrow_box = Rect.from_min_size(
          Pos2.new(rect.right - pad_x - arrow_h,
            rect.center.y - arrow_h / 2.0),
          Vec2.new(arrow_h, arrow_h))
      else # :button
        ui.painter.rect(rect, 3.0,
          visuals.button_fill(response.hovered?, response.active?),
          visuals.button_stroke, 1.0)

        # The arrow strip: a sub-button of its own pinned inside the
        # right edge (like the system dropdowns) — one fill step
        # stronger than the field and divided from it by a separator
        # stroke. Inset by the 1px outer stroke so it sits inside the
        # frame.
        separator_x = rect.right - 1.0 - arrow_zone
        strip = Rect.from_min_size(Pos2.new(separator_x, rect.top + 1.0),
          Vec2.new(arrow_zone, rect.height - 2.0))
        ui.painter.rect(strip, 3.0,
          visuals.button_fill(true, response.active?))
        ui.painter.line(Pos2.new(separator_x, rect.top + 1.0),
          Pos2.new(separator_x, rect.bottom - 1.0), 1.0, visuals.button_stroke)
        arrow_box = Rect.from_min_size(
          Pos2.new(strip.center.x - arrow_h / 2.0,
            rect.center.y - arrow_h / 2.0),
          Vec2.new(arrow_h, arrow_h))
      end

      # Text flush left, the chevron in its box.
      ui.painter.text(Pos2.new(rect.left + pad_x, rect.center.y),
        display, font_size, text_color, family: style.font_family)
      Icons.draw(ui.painter, :down, arrow_box, visuals.text_color, 2.0)

      # Toggle: a click while open closes (like MenuButton); without
      # this the re-open would also shield the popup from the
      # click-elsewhere close in Memory#end_frame.
      if response.clicked?
        if ui.ctx.popup_open?(@id)
          ui.ctx.close_popup(@id)
        else
          ui.ctx.open_popup(@id)
        end
      end

      picked = false
      # GTK3-style `overlay` opens the list right on top of the button;
      # otherwise it hangs below (flipping above near the screen edge).
      anchor = @overlay ? rect.min : ui.ctx.dropdown_anchor(@id, rect)
      ui.ctx.popup(@id, anchor, width: rect.width, min_width: rect.width) do |pop|
        # The placeholder leads the list as the zero option — picking
        # it reports "" (nothing selected) back through `on_select`.
        items = @label ? [{@label.not_nil!, ""}] : [] of Tuple(String, String)
        @options.each { |option| items << {option, option} }
        items.each do |shown, value|
          text_size = fonts.measure(shown, font_size)
          height = {text_size.y + 2 * style.spacing.button_padding.y,
            pop.style.spacing.interact_size.y}.max
          natural_w = 2 * style.spacing.button_padding.x + text_size.x
          # Rows track the popup's ACTUAL width (pop.max_rect), not the
          # button that opened it: the frame can be wider than the
          # button (a stale layer_sizes measurement from a previous
          # open, the min_width floor), and button-based bands would
          # come out narrower than the frame behind them.
          row_w = {pop.max_rect.width, natural_w}.max

          # Full-bleed row like a menu item: the popup Ui is inset by
          # window_padding, so the row pokes back out on both sides and
          # the highlight covers the frame edge-to-edge. The floored
          # row width feeds min_rect so the frame stays at least as
          # wide as the button that opened it.
          item_id = pop.next_widget_id
          item_rect = Rect.from_min_size(
            Pos2.new(pop.cursor.x - pop.style.spacing.window_padding.x,
                     pop.cursor.y),
            Vec2.new(row_w + 2 * pop.style.spacing.window_padding.x, height))
          pop.min_rect = pop.min_rect.union(
            Rect.from_min_size(pop.cursor, Vec2.new(row_w, height)))
          # Stack flush — the spacing is padding INSIDE each row, not a
          # margin gap between rows, so the hover / selection bands are
          # contiguous like a native dropdown.
          pop.cursor = pop.layout.advance(pop.cursor,
            Vec2.new(row_w, height), Vec2.zero)
          item_resp = pop.interact(item_rect, item_id, Sense.click)
          # Menu-item look (see Menu): rows are bare at rest — the
          # popup frame IS their background — so the list reads as one
          # solid block; only the hovered row and the real selection
          # get a full-width band. The placeholder zero row never
          # counts as "selected": an empty selection highlights
          # nothing.
          if !value.empty? && value == @selected
            pop.painter.rect(item_rect, 3.0, visuals.button_hovered)
          elsif item_resp.hovered?
            pop.painter.rect(item_rect, 3.0, visuals.button_hovered)
          end
          row_color = value.empty? ? visuals.fade_color(visuals.text_color, 0.55) : visuals.text_color
          pop.painter.text(item_rect.left_center +
            Vec2.new(style.spacing.button_padding.x, 0.0),
            shown, font_size, row_color, family: style.font_family)
          if item_resp.clicked?
            on_select.call(value)
            ui.ctx.close_popup(@id)
            picked = true
          end
        end
      end
      picked
    end
  end
end
