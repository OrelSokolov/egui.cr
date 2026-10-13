# Overlay — a region-anchored floating block (no direct upstream
# counterpart; the closest kin is `Area` + its `anchor` option):
# widgets laid out ON TOP of this Ui's region, pinned to one of nine
# anchors (corners, edge midpoints, center) with a margin from the
# pinned edges — the navigator-map idiom (zoom cluster over a canvas,
# FAB in a corner, spinner dead-center, HUD labels). The CSS analog
# is `position: fixed` scoped to the region: the overlay never
# touches the parent's flow — the cursor does not advance and the
# parent's bounding box does not grow.
#
#   ui.overlay(:top_right, margin: StyleBox.new(top: 12, right: 12),
#              id: "map_zoom") do |o|
#     o.button("+")
#     o.button("−")
#   end
#
# `rect:` re-bases the overlay on an explicit region (the map's
# rect); default is the Ui's own `max_rect`. The content hugs its
# natural size, anchored on LAST frame's measured size (the same
# scheme `#modal`/`#embedded_window` use via `Memory#layer_sizes`) —
# the very first frame opens at an estimate and settles once the
# content is first measured.
#
# `z:` lifts the overlay's content (and its background click target)
# to an explicit layer — higher z paints later and wins hit-tests
# over widgets declared after the overlay in the same Order.
# `pass_through: true` drops the background interaction entirely:
# a HUD overlay draws over the map but never eats its drags/clicks.
#
# Styling goes through the global `StyleSheet` (CSS-like classes):
#   overlay — anchor (one of the nine positions), margin (box),
#             z (0..100)
# The inspector edits all three live (Element tab / "overlay" class
# rule); inside a style scope (`Ui#with_style_scope("map")`) the
# overlay styles under "map.overlay" too.

module Egui
  class Overlay
    include Widget

    # The nine anchor positions (corners, edge midpoints, center) —
    # the enum options of the `anchor` style key.
    ANCHORS = %w[top_left top_center top_right center left_center
                 right_center bottom_left bottom_center bottom_right]

    # First-frame size estimate until the content is measured.
    ESTIMATE = Vec2.new(160.0, 80.0)

    def initialize(@anchor : Symbol? = nil, @margin : StyleBox? = nil,
                   @z : Int32? = nil, @rect : Rect? = nil,
                   @pass_through : Bool = false, id : String? = nil,
                   &block : Ui ->)
      @id_name = id
      @block = block
    end

    def style_class : String?
      "overlay"
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("anchor", :enum, options: ANCHORS,
        fallback: @anchor.try(&.to_s)),
       StyleProp.new("margin", :box),
       StyleProp.new("z", :number, min: 0.0)]
    end

    def inspector_label : String?
      @anchor.try(&.to_s)
    end

    def ui(ui : Ui) : Response
      ctx = ui.ctx
      id = resolve_id(ui)
      vars = style_vars(ui, id)
      # The measured size must survive end-frame pruning like any
      # stateful widget's cell (the background interact below also
      # marks the id used; pass_through overlays have none).
      ctx.memory.use_id(id)

      anchor = vars.str?("anchor") || @anchor.try(&.to_s) || "top_left"
      margin = vars.box?("margin") || @margin || StyleBox.new
      z = (vars.f64?("z") || @z).try(&.round.to_i)
      layer = z ? LayerId.new(ui.layer.order, id, z: z) : ui.layer

      fx, fy = anchor_factors(anchor)
      region = @rect || ui.max_rect
      # Anchor on last frame's measured size (first frame: the
      # estimate) — the content run below stores the true size for
      # the next frame, like #modal does.
      size = ctx.memory.layer_sizes[id]? || ESTIMATE
      x = region.left + (region.width - size.x) * fx
      y = region.top + (region.height - size.y) * fy
      # The margin pushes INWARD from the pinned edges (a centered
      # overlay takes no margin shift).
      x += fx < 0.5 ? margin.left : (fx > 0.5 ? -margin.right : 0.0)
      y += fy < 0.5 ? margin.top : (fy > 0.5 ? -margin.bottom : 0.0)

      # The background click target under the overlay's OWN id: blank
      # overlay space eats the click (like the modal card) and makes
      # the overlay itself pickable in the inspector (the meta keys on
      # this id, the highlight outline on its rect). Declared BEFORE
      # the content so the content's widgets hit-test above it in the
      # same layer.
      bg_rect = Rect.from_min_size(Pos2.new(x, y), size)
      bg_resp = @pass_through ? nil :
        ctx.interact(id, bg_rect, Sense.click, layer, ui.clip)

      child = ui.child_ui(Rect.from_min_size(Pos2.new(x, y),
        Vec2.new({region.right - x, 1.0}.max, 1e6)))
      child.layer = layer
      # The content must paint (and hit-test) in the overlay's layer —
      # the painter is global state, so switch it around the block
      # like #window/#popup do, and restore whatever the parent left.
      painter = ctx.painter
      prev_layer = painter.layer
      prev_clip = painter.clip
      painter.layer = layer.z
      painter.clip = ui.clip
      @block.call(child)
      painter.layer = prev_layer
      painter.clip = prev_clip
      ctx.memory.layer_sizes[id] = child.min_rect.size

      bg_resp || Response.new(ctx, id, bg_rect, Sense.none,
        false, false, 0, false, false, false, false, false, Vec2.zero)
    end

    # Anchor name → axis factors (0 = min edge, 0.5 = center, 1 = max
    # edge). Unknown names read as top_left.
    private def anchor_factors(anchor : String) : {Float64, Float64}
      fx = anchor.includes?("left") ? 0.0 :
           anchor.includes?("right") ? 1.0 : 0.5
      fy = anchor.starts_with?("top") ? 0.0 :
           anchor.starts_with?("bottom") ? 1.0 : 0.5
      {fx, fy}
    end
  end
end
