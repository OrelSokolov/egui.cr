# Mobile Card (Material 3 `Card` / iOS grouped inset, phase 3 of
# plans/todo/mobile_widgets.md): a padded rounded-rect surface that
# hosts a block of children.
#
# A thin painter wrapper, not a layout engine: the card is a BLOCK
# container — it always takes the parent's remaining width and grows
# downward to fit its content (the div-in-flow model). The children run
# in a child Ui inset by the `padding` box, and the flow is advanced by
# hand afterwards (the Expander pattern — the Ui protocol has no
# "allocate after measuring" primitive, so containers that host blocks
# mutate `cursor`/`min_rect` directly; see containers/expander.cr).
#
# Paint order needs the Frame back-patch trick (Painter#add_noop +
# #set): the shadow/background stroke must go UNDER the children, but
# the card's rect is only known after the block measured them — so the
# chrome commands are reserved as noops before the block runs and
# patched in afterwards. Painter commands paint in record order, so
# this is the only way chrome lands beneath content.
#
# Styling — the `card` class (all keys introspectable, ECSS-editable):
#   padding       (box, default 12 top/bottom, 16 left/right)
#   rounding      (number, default 12)
#   background    (color, default visuals.window_fill)
#   stroke        (color, unset = no border)
#   stroke_width  (number, default 1.0 when `stroke` is set)
#   shadow.*      (the shared CSS box-shadow keys — color/blur/spread/
#                  x/y/inset, read through `StyleVars#shadow?`; unset =
#                  flat card. An inset shadow paints OVER the children
#                  per CSS, an outset one under the fill.)

module Egui
  class Card
    include Widget

    CONTENT_SEED = 0xC4D5_u64

    def initialize(id : String? = nil, &content : Ui ->)
      @id_name = id
      @content = content
    end

    def style_class : String?
      "card"
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("padding", :box),
       StyleProp.new("rounding", :number, fallback: 12.0, min: 0.0),
       StyleProp.new("background", :color),
       StyleProp.new("stroke", :color),
       StyleProp.new("stroke_width", :number, min: 0.0),
       StyleProp.new("shadow.color", :color, states: true),
       StyleProp.new("shadow.blur", :number, min: 0.0),
       StyleProp.new("shadow.x", :number),
       StyleProp.new("shadow.y", :number)]
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      vars = style_vars(ui, id)
      visuals = ui.style.visuals
      pad = vars.box?("padding") || StyleBox.new(12.0, 16.0, 12.0, 16.0)

      left = ui.cursor.x
      top = ui.cursor.y
      # Block container: full remaining width; the height comes from
      # the content run below.
      width = ui.available_width
      inner_w = {width - pad.horizontal, 0.0}.max

      # Chrome slots reserved BEFORE the children run (see the header).
      shadow_spec = vars.shadow?
      sh_index = shadow_spec.try { |s| ui.painter.add_noop unless s.inset? }
      bg_index = ui.painter.add_noop

      child = ui.child_ui(Rect.from_min_size(
        Pos2.new(left + pad.left, top + pad.top),
        Vec2.new(inner_w, 1e6)), id: id.child(CONTENT_SEED))
      @content.call(child)
      content_bottom = {child.min_rect.bottom, top + pad.top}.max

      outer = Rect.new(Pos2.new(left, top),
        Pos2.new({left + width, left}.max, content_bottom + pad.bottom))

      # Patch the reserved chrome in, now that `outer` exists. Outset
      # shadow under the fill, inset over the children (CSS order).
      rounding = vars.rounding_px("rounding", outer, 12.0)
      corners = vars.rounding_corners?("rounding", outer)
      if (s = shadow_spec) && !s.inset?
        ui.painter.set(sh_index.not_nil!, ShadowCmd.new(
          ui.painter.shadow_bake_clip, outer, rounding, s.blur, s.spread,
          s.offset, s.color, false))
      end
      stroke_w = vars.f64("stroke_width", vars.color?("stroke") ? 1.0 : 0.0)
      stroke_c = vars.color?("stroke") ||
                 (stroke_w > 0.0 ? visuals.separator_color : nil)
      ui.painter.set(bg_index, RectCmd.new(ui.painter.clip, outer, rounding,
        vars.color?("background") || visuals.window_fill, stroke_c,
        stroke_w, corners: corners))
      if (s = shadow_spec) && s.inset?
        ui.painter.box_shadow(outer, s.color, s.blur, rounding, s.spread,
          s.offset, inset: true)
      end

      # Advance the flow by the card's full extent (the Expander
      # pattern). Block containers only — in a horizontal row this
      # drops following widgets to the next line, which is the honest
      # v1 semantics (see the header).
      ui.min_rect = ui.min_rect.union(outer)
      ui.cursor = Pos2.new(ui.max_rect.min.x,
        outer.bottom + ui.style.spacing.item_spacing.y)

      Response.container(ui.ctx, id, outer)
    end
  end
end

# Ui sugar for the mobile widget set (see widgets/switch.cr — the
# class is reopened per phase file, `ui.cr` stays untouched).
class Egui::Ui
  # `ui.card { |c| c.label("…") }` — a padded rounded surface hosting
  # the block; returns the card's outer rect. Always full-width (block
  # container).
  def card(id : String? = nil, &content : Ui ->) : Rect
    r = add(Card.new(id, &content))
    r.rect
  end
end
