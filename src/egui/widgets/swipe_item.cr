# Mobile swipe-actions row (Material 3 dismissible list item / iOS Mail
# swipe) — plans/todo/mobile_widgets.md #16, Phase 5.
#
# One list row: the app renders the row CONTENT through a block
# (typically a label pair); a horizontal drag slides the content left
# and reveals 1–2 action buttons underneath (label + fill color +
# optional callback each). A tap still reports `Response#clicked?`
# (`mark_changed`, same contract as Switch) — the widget senses
# click+drag, so the drag machine's slop (6 px mouse / 16 px finger,
# `Event#from_touch`) separates taps from swipes, and nested click-
# sensing widgets (a Button inside the block) register AFTER the row
# and win the tap — the exact hit-ordering trick Tabs uses for its
# close X.
#
# V1 simplifications (honest, documented):
# * actions sit on the RIGHT edge only — swiping left reveals them;
#   a right-swipe is clamped to 0 (no mirrored left actions).
# * no drag-to-dismiss-by-flick-velocity: dismissal is distance-based
#   (released past `dismiss_ratio` of the row width) — no kinetic
#   history read.
# * the settle animation is `Context#animate_value_with_time`, not a
#   velocity-continuous `Spring`: IdTypeMap (the only per-widget
#   storage) holds a closed cell union that cannot store a Spring
#   object, and grabbing a row mid-settle snaps to the settled target
#   before following the finger.
# * the row claims ANY drag over its rect, so a vertical finger drag
#   on the row does not chain into the enclosing ScrollArea's
#   drag-to-scroll (the canvas gesture stands down whenever a
#   drag-sensing widget is under the pointer). The offset only moves
#   horizontally; the vertical component is discarded.
# * the row's height comes from the PREVIOUS frame's measured content
#   (stored per id, `MIN_ROW_H` fallback on first sight) — hit-testing
#   already reads previous-frame geometry, so the one-frame lag is
#   invisible; content is top-aligned within the reserved row.
#
# Styling — the `swipe_item` class: `action_width` (80), the width of
# each action button (the total reveal is actions × action_width);
# `dismiss_ratio` (0.6) — the fraction of the row width past which
# release counts as a dismiss.

module Egui
  class SwipeItem
    include Widget

    # Element salt for the per-action button ids (`row_id.child(ACTION_SALT + i)`)
    # — specs and app code address the revealed buttons through these.
    ACTION_SALT  = 0x531_u64
    OFFSET_SALT  = 0x5F0_u64
    HEIGHT_SALT  = 0x548_u64
    CONTENT_SALT = 0x5C0_u64

    SETTLE_TIME = 0.22
    MIN_ROW_H   = 44.0

    ROOT_CLASS = "swipe_item"

    def style_class : String?
      ROOT_CLASS
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("action_width", :number, min: 0.0),
       StyleProp.new("dismiss_ratio", :number, min: 0.0, fallback: 0.6)]
    end

    # One action button under the row: `Action.new("Delete",
    # Color32.rgb(220, 50, 50)) { ... }` — the block (optional) fires
    # when the revealed button is tapped.
    class Action
      getter label : String
      getter color : Color32
      getter on_tap : (-> Nil)?

      def initialize(@label : String, @color : Color32,
                     @on_tap : (-> Nil)? = nil)
      end

      def initialize(@label : String, @color : Color32, &block : -> Nil)
        @on_tap = block
      end
    end

    # The index of the action tapped THIS frame (nil = none); the Ui
    # helper fires the action's callback. Reset per frame.
    getter action_tapped : Int32?
    # Set when a release landed past the dismiss threshold — the app
    # removes the row from its own state.
    getter? dismissed : Bool
    # True while the row's settled position reveals the actions.
    getter? open : Bool

    def initialize(@actions : Array(Action) = [] of Action,
                   id : String? = nil, @on_dismiss : (-> Nil)? = nil,
                   &content : Ui ->)
      @id_name = id
      @content = content
      @action_tapped = nil
      @dismissed = false
      @open = false
    end

    def inspector_label : String?
      @open ? "open" : "closed"
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      ctx = ui.ctx
      vars = style_vars(ui, id)
      action_w = vars.f64("action_width", 80.0)
      dismiss_ratio = vars.f64("dismiss_ratio", 0.6)
      reveal_w = @actions.size * action_w
      @action_tapped = nil
      @dismissed = false

      offset_id = id.child(OFFSET_SALT)
      height_id = id.child(HEIGHT_SALT)
      # The state ids carry no widget, so end_frame would prune their
      # IdTypeMap cells — keep them alive like Tabs keeps its carousel
      # offset alive (`use_id`).
      ctx.memory.use_id(offset_id)
      ctx.memory.use_id(height_id)
      # The row's height is last frame's measured content height — see
      # the class doc. The reveal drag is horizontal only.
      row_h = ctx.memory.data.get_f64(height_id, MIN_ROW_H)
      size = styled_size(Vec2.new(ui.available_width, row_h), vars, ui, id)
      row = ui.allocate_at_least(size)
      # Click+drag: taps report clicked?, swipes report dragged? after
      # the input slop; the drag machine cancels the click once the
      # finger passes the slop, so a swipe never also fires a tap.
      response = ui.interact(row, id, Sense.click | Sense.drag)
      response.mark_changed if response.clicked?

      # Raw horizontal offset: the settled target while idle, the
      # finger position while dragging (one Float64 per id — the same
      # IdTypeMap slot Tabs uses for its carousel offset).
      prev = ctx.memory.data.get_f64(offset_id, 0.0)
      # Drag travel is clamped to the reveal — or, when dismissal is
      # armed, to the dismiss distance if that is FARTHER (otherwise a
      # narrow reveal row could never reach its own dismiss threshold).
      max_drag = @on_dismiss ? {reveal_w, row.width * dismiss_ratio}.max
                             : reveal_w
      display =
        if response.dragged?
          # drag_delta backfills press→current on the engagement frame
          # (Memory#interact), so `prev + delta` stays continuous there.
          raw = (prev + response.drag_delta.x).clamp(-max_drag, 0.0)
          ctx.memory.data.set_f64(offset_id, raw)
          # Keep the settle easing honest: a zero-duration call syncs
          # the animation manager to the finger, so the release retarget
          # eases FROM the drag position. Without it the manager's stale
          # anim still targets 0.0 — matching the snap-back target — and
          # an un-completed swipe resets with no animation at all.
          ctx.animate_value_with_time(offset_id, raw, 0.0)
          ctx.request_repaint
          raw
        else
          if response.drag_stopped?
            if @on_dismiss && -prev >= row.width * dismiss_ratio
              @dismissed = true
            end
            # Past half the reveal the finger "means" open, else closed.
            target = -prev > reveal_w / 2.0 ? -reveal_w : 0.0
            ctx.memory.data.set_f64(offset_id, target)
            prev = target
          end
          ctx.animate_value_with_time(offset_id, prev, SETTLE_TIME)
        end
      @open = display < -0.5

      # Action buttons: painted + hit-tested BEFORE the content runs —
      # the painter order puts them UNDER the sliding content, and the
      # hit-test order (last registration wins) gives the content
      # priority while the row is closed. Gated on the reveal having
      # started: a tap on the closed row's right strip must not fall
      # through to a hidden action if the content paints transparently.
      @actions.each_with_index do |action, i|
        next unless @open
        rect = Rect.from_min_size(
          Pos2.new(row.right - (i + 1) * action_w, row.min.y),
          Vec2.new(action_w, row.height))
        ar = ui.interact(rect, id.child(ACTION_SALT + i.to_u64), Sense.click)
        next unless ar.clicked?
        @action_tapped = i
        # Tap an action → the row settles back closed.
        ctx.memory.data.set_f64(offset_id, 0.0)
        ctx.request_repaint
      end
      reveal_progress = reveal_w > 0.0 ? (-display / reveal_w).clamp(0.0, 1.0) : 0.0
      if reveal_progress > 0.0
        visuals = ui.style.visuals
        @actions.each_with_index do |action, i|
          rect = Rect.from_min_size(
            Pos2.new(row.right - (i + 1) * action_w, row.min.y),
            Vec2.new(action_w, row.height))
          ui.painter.rect(rect, 0.0, action.color)
          font_size = ui.style.font_size
          text_size = ctx.fonts.measure(action.label, font_size)
          ui.painter.text(
            Pos2.new(rect.center.x - text_size.x / 2.0, rect.center.y),
            action.label, font_size, Color32.rgb(255, 255, 255))
        end
      end

      # The content block, slid left by the current offset and clipped
      # to the row (the painter clip is saved/restored — it is shared).
      content_rect = Rect.from_min_size(
        Pos2.new(row.min.x + display, row.min.y),
        Vec2.new(row.width, row.height))
      child = ui.child_ui(content_rect, id.child(CONTENT_SALT))
      outer_clip = ui.painter.clip
      ui.painter.clip = Rect.new(
        Pos2.new({outer_clip.min.x, row.min.x}.max,
          {outer_clip.min.y, row.min.y}.max),
        Pos2.new({outer_clip.max.x, row.max.x}.min,
          {outer_clip.max.y, row.max.y}.min))
      @content.call(child)
      ui.painter.clip = outer_clip

      # Publish the measured content height for the next frame's row.
      measured = child.min_rect.height
      ctx.memory.data.set_f64(height_id, measured) if measured > 0.0

      response
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.swipe_item(id: "row1", actions: [...]) { |row| … }` — one
  # swipeable list row; the block renders the row content. Tapping a
  # revealed action fires its callback; a release past
  # `dismiss_ratio` of the row width fires `on_dismiss` (the app
  # removes the row). `Response#changed?` reports a plain row tap.
  def swipe_item(id : String? = nil,
                 actions : Array(SwipeItem::Action) = [] of SwipeItem::Action,
                 on_dismiss : (-> Nil)? = nil,
                 &content : Ui ->) : Response
    widget = SwipeItem.new(actions, id: id, on_dismiss: on_dismiss, &content)
    response = add(widget)
    if (i = widget.action_tapped) && (action = actions[i]?) &&
       (cb = action.on_tap)
      cb.call
    end
    if widget.dismissed? && (cb = on_dismiss)
      cb.call
    end
    response
  end
end
