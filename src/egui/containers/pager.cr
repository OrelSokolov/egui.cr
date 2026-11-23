# Horizontal swipe pager / carousel — plans/todo/mobile_widgets.md #17,
# Phase 5. The mobile "pages" container: N full-width pages, a
# horizontal drag slides the strip, release settles on the nearest
# page (round of the finger travel). Selection follows the app-owned
# Checkbox/Tabs pattern: the app passes the current page in and reads
# the swipe-changed one back through `Response#changed?` +
# `Pager#page` (or the `Ui#pager` helper's `on_change`). A
# programmatic selection change (the app passes a different page)
# animates there too — the displayed translation is always
# `animate_value_with_time` towards `-page * width`, so one code path
# covers finger release, external jumps and the initial state.
#
# State (the float translation of page 0) lives in Memory's IdTypeMap
# keyed by the pager id — like Tabs' carousel offset. The animated
# value rides the same id (`animate_value_with_time` stores its own
# per-id anim there), so drag→settle is velocity-agnostic: during the
# drag the display follows the finger exactly, the animation only
# owns the settle.
#
# Each page renders into its own `child_ui` translated by
# `i * width + offset`, clipped to the viewport (painter clip — the
# standard save/restore, since the painter is shared). Off-screen
# pages neither paint nor run their block. Page content widgets
# register AFTER the viewport's drag interact, so they win taps while
# the pager keeps the drags — the same ordering as SwipeItem's row.
#
# V1 simplifications (honest, documented):
# * no flick velocity: the page choice at release is pure distance
#   (round of the travel fraction) — a slow half-width drag switches,
#   a quick short flick does not.
# * the viewport height is the `height` constructor parameter (or the
#   `pager.height` style key) — pages are not measured; oversized
#   content is clipped, not grown.
# * pages render at the full viewport width; no peek/preview layout.
#
# Styling — the `pager` class: `height` (the viewport height).

module Egui
  class Pager
    include Widget

    OFFSET_SALT = 0x9A0_u64
    PAGE_SALT   = 0x9B0_u64

    SETTLE_TIME = 0.22

    ROOT_CLASS = "pager"

    def style_class : String?
      ROOT_CLASS
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("height", :number, min: 0.0)]
    end

    getter page : Int32

    def initialize(@pages : Int32, selected : Int32 = 0,
                   @height : Float64 = 200.0, id : String? = nil,
                   &page_block : Ui, Int32 ->)
      @id_name = id
      @page_block = page_block
      @page = {selected, 0}.max
      @page = @page.clamp(0, {@pages - 1, 0}.max)
    end

    def inspector_label : String?
      "page #{@page + 1}/#{@pages}"
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      ctx = ui.ctx
      vars = style_vars(ui, id)
      height = vars.f64("height", @height)
      w = ui.available_width

      viewport = ui.allocate_at_least(Vec2.new(w, height))
      return ui.interact(viewport, id, Sense.none) if @pages <= 1 || w <= 0.0

      response = ui.interact(viewport, id, Sense.drag)
      response.mark_changed if response.clicked?

      # The strip's translation x: 0 shows page 0, -span shows the
      # last page. Stored per id: the raw finger position while
      # dragging, the settled target otherwise.
      state_id = id.child(OFFSET_SALT)
      # No widget is minted under this id — keep its IdTypeMap cell
      # (and the animation keyed here) alive across frames.
      ctx.memory.use_id(state_id)
      span = (@pages - 1) * w
      prev = ctx.memory.data.get_f64(state_id, -@page.to_f64 * w)
      display =
        if response.dragged?
          raw = (prev + response.drag_delta.x).clamp(-span, 0.0)
          ctx.memory.data.set_f64(state_id, raw)
          # Sync the animation manager to the finger (zero duration =
          # snap): the release retarget must ease FROM the drag
          # position, or a not-far-enough swipe matches the stale
          # anim's target 0.0 and resets with no animation.
          ctx.animate_value_with_time(state_id, raw, 0.0)
          ctx.request_repaint
          raw
        else
          if response.drag_stopped?
            idx = (-prev / w).round.to_i.clamp(0, @pages - 1)
            if idx != @page
              @page = idx
              response.mark_changed
              ctx.request_repaint
            end
            ctx.memory.data.set_f64(state_id, -@page.to_f64 * w)
          end
          ctx.animate_value_with_time(state_id, -@page.to_f64 * w, SETTLE_TIME)
        end

      # One child Ui per visible page, translated with the strip and
      # clipped to the viewport (painter clip only — hit-testing keeps
      # the parent's clip, and page content belongs to the viewport's
      # interaction in v1).
      outer_clip = ui.painter.clip
      @pages.times do |i|
        prect = Rect.from_min_size(
          Pos2.new(viewport.min.x + i.to_f64 * w + display, viewport.min.y),
          Vec2.new(w, height))
        next if prect.right <= viewport.left || prect.left >= viewport.right
        child = ui.child_ui(prect, id.child(PAGE_SALT + i.to_u64))
        ui.painter.clip = Rect.new(
          Pos2.new({outer_clip.min.x, viewport.min.x}.max,
            {outer_clip.min.y, viewport.min.y}.max),
          Pos2.new({outer_clip.max.x, viewport.max.x}.min,
            {outer_clip.max.y, viewport.max.y}.min))
        @page_block.call(child, i)
      end
      ui.painter.clip = outer_clip

      response
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.pager(3, page, id: "onboarding", height: 300) { |page_ui, i| … }`
  # — N swipe pages, the block renders page `i` into `page_ui`.
  # `Response#changed?` reports a swipe-driven page change and
  # `on_change` fires with the new index (the app mirrors it into its
  # own state and passes it back as `selected` next frame).
  def pager(pages : Int32, selected : Int32 = 0, id : String? = nil,
            height : Float64 = 200.0, on_change : (Int32 ->)? = nil,
            &page_block : Ui, Int32 ->) : Response
    widget = Pager.new(pages, selected, height, id: id, &page_block)
    response = add(widget)
    if response.changed? && (cb = on_change)
      cb.call(widget.page)
    end
    response
  end
end
