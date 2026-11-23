# Mobile SearchBar (Material 3 search bar / iOS UISearchField, phase
# 3 of plans/todo/mobile_widgets.md): a capsule-shaped search field
# wrapping a frame-less TextEdit, plus a trailing clear X when the
# text is non-empty.
#
# Deliberately a THIN composition: the field owns nothing on its own —
# a capsule of `padding` insets around a `frame: false` TextEdit (the
# TextEdit keeps ALL editing behavior: caret, selection, clipboard,
# IME, focus loss on outside clicks — a second edit engine would be a
# bug factory). The capsule background is painted through the Frame
# back-patch trick (noop slot reserved before the TextEdit runs,
# patched once the field's rect is measured — the Card/box pattern),
# because painter commands draw in record order and the bg must sit
# UNDER the text.
#
# The clear X is a nested interact registered AFTER the TextEdit's
# (hit-testing picks the latest widget under the pointer — the Tabs
# close-X trick), painted only when the text is non-empty; it eats
# clicks over the field's right padding zone. A clear reports like an
# edit: `Response#changed?` + `widget_text == ""`.
#
# Reports edits through the TextEdit channel: `Response#changed?` and
# `Response#widget_text` (the `ui.search_bar(text) { |new| … }` block
# reads both). The app owns the buffer, TextEdit-style.
#
# Styling — the `search_bar` class:
#   padding     (box, default 14 left/right — capsule insets; the
#               right side doubles as the clear-X zone)
#   rounding    (number; default = capsule, half the field height)
#   background  (color, default visuals.button_weak — the pill fill)
#   stroke      (color, unset = no outline)
#   font_size   / text_color ride the TextEdit cascade as usual.

module Egui
  class SearchBar
    include Widget

    CONTENT_SEED = 0x5EA1_u64
    CLEAR_SEED   = 0xC1EA_u64

    def initialize(@text : String, @hint : String = "Search",
                   id : String? = nil)
      @id_name = id
    end

    def style_class : String?
      "search_bar"
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("padding", :box),
       StyleProp.new("rounding", :number, min: 0.0),
       StyleProp.new("background", :color),
       StyleProp.new("stroke", :color),
       StyleProp.new("close_color", :color)]
    end

    def inspector_label : String?
      @text.empty? ? @hint : @text
    end

    # The StyledPart behind the clear X (see widgets/styled_part.cr):
    # inspector meta + the per-part keys, addressed as
    # "search_bar.close" (+ :hover overlay) — without it the X is a
    # bare interact and the inspector cannot pick it.
    class ClosePart < StyledPart
      def initialize
        super("SearchBarClose", "search_bar.close", [
          StyleProp.new("close_color", :color, states: true),
        ], "clear X")
      end
    end

    # The clear X's rect from the last ui() run — nil while the text
    # is empty (no X, no hit target).
    getter clear_rect : Rect?

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      vars = style_vars(ui, id)
      style = effective_style(ui, id, vars)
      visuals = style.visuals

      pad = vars.box?("padding") || StyleBox.new(0.0, 14.0, 0.0, 14.0)
      left = ui.cursor.x
      top = ui.cursor.y
      width = ui.available_width
      inner_w = {width - pad.horizontal, 0.0}.max

      # Capsule bg slot reserved before the TextEdit runs (see the
      # class comment).
      bg_index = ui.painter.add_noop

      child = ui.child_ui(Rect.from_min_size(
        Pos2.new(left + pad.left, top + pad.top),
        Vec2.new(inner_w, 1e6)), id: id.child(CONTENT_SEED))
      te = TextEdit.new(@text, @hint, frame: false)
      te = te.width(inner_w)
      te_resp = child.add(te)
      text = te_resp.widget_text || @text
      new_text = text != @text
      bottom = {child.min_rect.bottom, top + pad.top}.max
      rect = Rect.new(Pos2.new(left, top),
        Pos2.new({left + width, left}.max, bottom + pad.bottom))

      # Patch the capsule in (fill + optional stroke, rounded to half
      # the height by default — the pill).
      rounding = vars.rounding_px("rounding", rect, rect.height / 2.0)
      stroke = vars.color?("stroke")
      ui.painter.set(bg_index, RectCmd.new(ui.painter.clip, rect, rounding,
        vars.color?("background") || visuals.button_weak, stroke, 1.0))

      # Block container flow advance (the Card/Expander pattern).
      ui.min_rect = ui.min_rect.union(rect)
      ui.cursor = Pos2.new(ui.max_rect.min.x,
        rect.bottom + ui.style.spacing.item_spacing.y)

      response = ui.interact(rect, id, Sense.none)
      # Edits bubble up on the TextEdit channel (see the class
      # comment) — the field-level response carries the verdict.
      if new_text
        response.widget_text = text
        response.mark_changed
      end

      # Clear X: only when there is something to clear; registered
      # AFTER the TextEdit so a click on it never reaches the field
      # (see the class comment).
      @clear_rect = nil
      unless text.empty?
        icon = style.font_size * 0.9
        x_rect = Rect.from_min_size(
          Pos2.new(rect.right - pad.right + 2.0,
            rect.center.y - icon / 2.0),
          Vec2.new(icon, icon))
        @clear_rect = x_rect
        x_id = id.child(CLEAR_SEED)
        part = ClosePart.new
        x_resp = ui.ctx.with_inspector_widget(part) {
          ui.interact(x_rect, x_id, Sense.click) }
        Icons.draw(ui.painter, :close, x_rect,
          part.vars(ui, x_id, x_resp.hovered? ? "hover" : nil)
            .color("close_color", vars.color("close_color",
              visuals.fade_color(visuals.text_color))))
        if x_resp.clicked?
          @clear_rect = nil
          response.widget_text = ""
          response.mark_changed
          ui.ctx.request_repaint
        end
      end

      response
    end
  end
end

# Ui sugar for the mobile widget set (see widgets/switch.cr — the
# class is reopened per phase file, `ui.cr` stays untouched).
class Egui::Ui
  # `ui.search_bar(text, hint: "Search") { |new_text| … }` — the block
  # fires when the text changed this frame (an edit or a clear);
  # `Response#changed?` + `#widget_text` report the same.
  def search_bar(text : String, hint : String = "Search",
                 id : String? = nil, &on_change : String ->) : Response
    response = add(SearchBar.new(text, hint, id: id))
    if response.changed? && (t = response.widget_text)
      on_change.call(t)
    end
    response
  end

  def search_bar(text : String, hint : String = "Search",
                 id : String? = nil) : Response
    add(SearchBar.new(text, hint, id: id))
  end
end
