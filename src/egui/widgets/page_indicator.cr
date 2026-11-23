# Mobile page indicator (the dots row under a Pager / onboarding
# carousel) — plans/todo/mobile_widgets.md #17, Phase 5. A passive
# row of dots: the active slot elongates into a capsule (iOS
# UIPageControl look), the rest stay round. Pure display — the app
# passes `count` + `index`; it is NOT a pager (no taps, no state):
# pair it with `Pager` and feed it the same page variable, and the
# two stay in sync through app state (see the `Ui#pager` /
# `Ui#page_indicator` pair).
#
# The elongation animates per dot id via
# `Context#animate_value_with_time` (a 0..1 progress per dot): the
# active slot's width eases from `dot_size` to
# `dot_size * active_ratio`, the color cross-fades from the inactive
# to the active tint — the same anim-key contract Switch uses for its
# thumb (no repaint is pinned after settle; EGUI_NOANIMATIONS=1
# snaps).
#
# Each dot's rect is registered under `base_id.child(DOT_SALT + i)`
# (a `Sense.none` interact — layout only, no input): the inspector
# can address the row per dot, and specs can read the geometry back.
#
# Layout note: the row's total width is the sum of the ANIMATED slot
# widths, so it wobbles by a few px during a transition (the
# elongated slot grows, the row re-centers around its left edge).
# Reserving the maximum width for every slot would keep the size
# constant but leave oversized gaps around the active dot in the
# resting state — the honest v1 picks the tighter resting layout.
#
# Styling — the `page_indicator` class: `dot_size` (8), `gap` (6),
# `active_ratio` (3 — the elongated width as a multiple of
# `dot_size`), `active_color` (selection_fill),
# `inactive_color` (separator).

module Egui
  class PageIndicator
    include Widget

    DOT_SALT = 0xD07_u64

    ANIM_TIME = 0.15

    ROOT_CLASS = "page_indicator"

    @index : Int32

    def style_class : String?
      ROOT_CLASS
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("dot_size", :number, min: 0.0),
       StyleProp.new("gap", :number, min: 0.0),
       StyleProp.new("active_ratio", :number, min: 1.0, fallback: 3.0),
       StyleProp.new("active_color", :color),
       StyleProp.new("inactive_color", :color)]
    end

    def initialize(@count : Int32, index : Int32, id : String? = nil)
      @id_name = id
      @index = index.clamp(0, {@count - 1, 0}.max)
    end

    def inspector_label : String?
      "#{@index + 1}/#{@count}"
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      ctx = ui.ctx
      vars = style_vars(ui, id)
      dot = vars.f64("dot_size", 8.0)
      gap = vars.f64("gap", 6.0)
      ratio = vars.f64("active_ratio", 3.0)
      active = vars.color("active_color", ui.style.visuals.selection_fill)
      inactive = vars.color("inactive_color", ui.style.visuals.separator_color)

      # Per-dot progress first: the widths (and with them the row's
      # natural size) are known before anything is allocated.
      progress = (0...@count).map do |i|
        target = i == @index ? 1.0 : 0.0
        ctx.animate_value_with_time(id.child(DOT_SALT + i.to_u64), target,
          ANIM_TIME)
      end
      widths = progress.map { |t| dot + (dot * ratio - dot) * t }
      total = widths.sum + gap * (@count - 1).clamp(0, nil)
      size = styled_size(Vec2.new(total, dot), vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.none)

      x = rect.min.x
      widths.each_with_index do |w, i|
        drect = Rect.from_min_size(
          Pos2.new(x, rect.center.y - dot / 2.0), Vec2.new(w, dot))
        ui.interact(drect, id.child(DOT_SALT + i.to_u64), Sense.none)
        ui.painter.capsule(drect, inactive.lerp(active, progress[i]))
        x += w + gap
      end

      response
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.page_indicator(3, page, id: "dots")` — the dots row; `index`
  # is the active (elongated) dot, zero-based.
  def page_indicator(count : Int32, index : Int32,
                     id : String? = nil) : Response
    add(PageIndicator.new(count, index, id: id))
  end
end
