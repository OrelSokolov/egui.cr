# Safe area container — plans/todo/mobile_widgets.md #24, the app-side
# wrapper half.
#
# The SYSTEM half already exists: `Egui::SafeArea` (the insets struct
# in context.cr) is the port — backends fill `RawInput#safe_area` from
# the OS (UIKit / WindowInsets shims) and `Context#begin_frame` carves
# those insets out of the root region every panel lays out against
# (`env()` style lengths resolve to the same numbers). This container
# is NOT that: it is the app-side wrapper that pads a sub-region by
# explicit insets, for layouts the global root carve-out can't express
# — a bottom nav that must additionally clear its own home-indicator
# band (`ui.safe_area(bottom: ctx.safe_area.bottom) { … }`), a FAB
# inset from the gesture bar, an extra margin under a fake status bar
# in a demo. Defaults are 0: without device insets (and without the
# app passing `ctx.safe_area.*` in) it is a pass-through.
#
# Naming: the class is `SafeAreaContainer` because `Egui::SafeArea`
# (the struct) already exists; the sugar helper is still `ui.safe_area`
# — apps say the short name, the type system keeps the two apart.
#
# Geometry: the block runs in a child Ui whose region is the parent's
# remaining rect shrunk by the insets; afterwards the parent's bounding
# box covers content + insets and the flow continues below content +
# bottom inset (mirrored for `:up`-flowing regions). Vertical flow in
# v1 — inside a horizontal row use `ui.horizontal { … }` around it.
#
# Styling — the `safe_area` class: `inset_top`, `inset_bottom`,
# `inset_left`, `inset_right` (a class rule beats the constructor
# value, same cascade as Overlay's anchor/margin). Nothing is painted.

module Egui
  class SafeAreaContainer
    include Widget

    def initialize(*, @top : Float64 = 0.0, @bottom : Float64 = 0.0,
                   @left : Float64 = 0.0, @right : Float64 = 0.0,
                   id : String? = nil, &block : Ui ->)
      @id_name = id
      @block = block
    end

    def style_class : String?
      "safe_area"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("inset_top", :number, min: 0.0),
        StyleProp.new("inset_bottom", :number, min: 0.0),
        StyleProp.new("inset_left", :number, min: 0.0),
        StyleProp.new("inset_right", :number, min: 0.0),
      ]
    end

    def inspector_label : String?
      "t#{@top} b#{@bottom} l#{@left} r#{@right}"
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      vars = style_vars(ui, id)
      top = vars.f64("inset_top", @top)
      bottom = vars.f64("inset_bottom", @bottom)
      left = vars.f64("inset_left", @left)
      right = vars.f64("inset_right", @right)

      # The remaining rect (Ui#remaining_rect is private) — where a
      # #scope block would lay out, mirrored for up-flowing regions.
      remaining = if ui.layout.bottom_up?
        Rect.new(Pos2.new(ui.cursor.x, ui.max_rect.min.y),
          Pos2.new(ui.max_rect.right, ui.cursor.y))
      else
        Rect.new(ui.cursor, Pos2.new(ui.max_rect.right, ui.max_rect.bottom))
      end
      inner = Rect.new(
        Pos2.new(remaining.min.x + left, remaining.min.y + top),
        Pos2.new(remaining.max.x - right, remaining.max.y - bottom))

      child = ui.child_ui(inner)
      @block.call(child)

      # Grow the parent's bounding box over content + insets (Ui#scope's
      # expand-to-include idiom, one band further out on every side) and
      # continue the flow below content + bottom inset. Even an EMPTY
      # block reserves its insets — a padded spacer is a legitimate use.
      outer = Rect.new(child.min_rect.min - Vec2.new(left, top),
        child.min_rect.max + Vec2.new(right, bottom))
      ui.min_rect = ui.min_rect.union(outer)
      spacing = ui.style.spacing.item_spacing.y
      ui.cursor = if ui.layout.bottom_up?
        Pos2.new(ui.max_rect.min.x, outer.top - spacing)
      else
        Pos2.new(ui.max_rect.min.x, outer.bottom + spacing)
      end

      Response.container(ui.ctx, id, outer)
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.safe_area(top:, bottom:, left:, right:) { |ui| … }` — pads the
  # block's region by the given insets (defaults 0; pass `ctx.safe_area`
  # values for the real device bands). Returns the padded outer rect as
  # a passive container Response.
  def safe_area(*, top : Float64 = 0.0, bottom : Float64 = 0.0,
                left : Float64 = 0.0, right : Float64 = 0.0,
                id : String? = nil, &block : Ui ->) : Response
    add(SafeAreaContainer.new(top: top, bottom: bottom, left: left,
      right: right, id: id, &block))
  end
end
