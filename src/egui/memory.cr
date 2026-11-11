# Port of egui_upstream/crates/egui/src/memory/ — the cross-frame system
# state. This is "what egui keeps" beyond app state:
#
#   data (IdTypeMap)   — persistent per-widget values (collapsing state,
#                        scroll offsets, …), pruned against used ids
#   areas (Areas)      — window positions + z-order
#   focus (Focus)      — keyboard focus with dead-man's switch
#   animations         — Id-keyed value animations
#   open_popups        — which popups are open + close-on-outside-click
#   interaction        — press candidates (click/drag), double-click
#                        classification, drag state machine
#   widget geometry    — this/previous frame rects+senses+layers (the
#                        previous frame is what hit-tests resolve against)
#
# hover/active/clicked are NOT stored — they are derived every frame
# from pointer + previous-frame geometry (the flicker lesson).

module Egui
  # Which system (soft) keyboard to show for a focused text widget —
  # mirrored by com.egui_cr.ime.EguiCrActivity on Android (kind/action
  # ints travel through egui_cr_android_ime_set_state).
  enum TextInputKind
    Plain     = 0
    Password  = 1
    Multiline = 2
    Number    = 3
  end

  enum TextInputAction
    None   = 0
    Done   = 1
    Go     = 2
    Search = 3
    Send   = 4
    Next   = 5
  end

  struct InteractionVerdict
    getter? hovered : Bool
    getter? clicked : Bool
    getter click_count : Int32
    getter? pressed : Bool
    getter? dragged : Bool
    getter? drag_started : Bool
    getter? drag_stopped : Bool
    getter drag_delta : Vec2
    getter? active : Bool

    def initialize(@hovered : Bool, @clicked : Bool, @click_count : Int32,
                   @pressed : Bool, @dragged : Bool, @drag_started : Bool,
                   @drag_stopped : Bool, @drag_delta : Vec2, @active : Bool)
    end
  end

  class Memory
    # egui InputOptions click classification defaults.
    DOUBLE_CLICK_TIME = 0.3
    CLICK_MAX_DIST    = 6.0
    # A FINGER can't hold still the way a mouse does: the touch twin of
    # CLICK_MAX_DIST for the click-vs-drag disambiguation (≈ Android
    # ViewConfiguration touch slop with headroom). Without it every tap
    # wobbles past 6px, engages drags instead of clicks, and cancels
    # the long-press.
    TOUCH_MAX_DIST    = 16.0

    getter data : IdTypeMap
    getter areas : Areas
    getter focus : Focus
    getter animations : AnimationManager
    # Cascade-driven transitions (`transition` style keys) — see
    # StyleAnimations (plans/animations.md Ур.1).
    getter style_animations : StyleAnimations
    # Appear-transition runs (`appear:`/`appear-delay:` style keys) —
    # see AppearAnims (plans/NATIVE_HTML_DEMO.md §3.2).
    getter appear_anims : AppearAnims
    # @keyframes playback state — see KeyframeAnims
    # (plans/NativeHTML.md §7).
    getter keyframe_anims : KeyframeAnims
    getter open_popups : Set(Id)
    getter duplicate_ids : Array(Id)
    # Tooltip hover-start times, kept outside IdTypeMap on purpose: the
    # map is pruned against widget ids, and a widget that stops being
    # hovered shouldn't forget when it started (egui tooltip delay).
    getter tooltip_starts : Hash(Id, Float64)
    # Which root menu is open (""/nil = none) — outside IdTypeMap for
    # the same pruning reason (MenuState in upstream Memory).
    property menu_open : String?
    # Container content sizes (modal dialog size for centering) — same
    # pruning exemption.
    getter layer_sizes : Hash(Id, Vec2)
    # Virtual-scroll row extents (ScrollArea `virtual:`, Ui#virtual_row):
    # per scroll-area id — {row-key hash → {height, id span}} plus the
    # viewport width the heights were measured at (a width change
    # invalidates them wholesale). Same pruning exemption: a SKIPPED
    # row mints no widget ids, so nothing else keeps these cells alive.
    getter virtual_rows : Hash(Id, Hash(UInt64, Tuple(Float64, UInt64)))
    getter virtual_row_widths : Hash(Id, Float64)
    # Natural widths of column boxes placed inline in horizontal rows
    # (Ui#box under a horizontal parent): a box cannot know its natural
    # width before its content runs, so the line-wrap decision uses the
    # width measured LAST frame — an unconstrained run records the real
    # width, a box that filled its region records the remainder plus a
    # hair ("at least this — break the line first"). Same pruning
    # exemption as layer_sizes: the key child-Ui id is minted before
    # any widget runs, so nothing else keeps these cells alive.
    getter inline_box_widths : Hash(Id, Float64)
    # Windows the user has grip-resized at least once: from then on the
    # size is fixed and content is clipped to the window rect (upstream
    # `Resize` inside `Window`) instead of auto-fitting the contents.
    # Same pruning exemption as layer_sizes.
    getter fixed_size_layers : Set(Id)
    # Screen rects of open popups, refreshed by Context#popup every frame
    # they render — the containment test of close-on-outside-click.
    getter popup_rects : Hash(Id, Rect)
    # Widget-generated texture cache (color picker gradients): named
    # ids so regenerated-once textures aren't re-uploaded every frame.
    getter texture_cache : Hash(String, UInt64)
    # Color picker hue cache (upstream `FixedCache<Rgba, Hsva>` keyed by
    # Id::NULL): maps an emitted color back to the Hsva it was produced
    # from. Hsva.from_color of a gray/white color loses the hue (chroma
    # 0 → hue 0 = red), so the picker consults this cache first to keep
    # the hue slider stable while dragging into the white corner.
    # Outside IdTypeMap on purpose: keyed by color, not by widget id,
    # so end-frame pruning must not touch it.
    getter color_cache : Hash(Color32, Hsva)

    # Scroll-sink viewports (id → sink) for scroll arbitration: scroll
    # areas, textareas and (draggable) plots register here; the top-most
    # sink containing the pointer (previous frame's geometry, like
    # widget hit-testing) owns this frame's scroll delta. `can_v`/`can_h`
    # carry SCROLL CHAINING (the browser rule): a sink that cannot
    # scroll the wheel's axis (content fits, or the axis is off) is
    # skipped and the sink UNDER it gets the delta instead.
    record ScrollSink, rect : Rect, layer : LayerId,
                      can_v : Bool = true, can_h : Bool = true

    getter scroll_rects : Hash(Id, ScrollSink)
    @prev_scroll_rects : Hash(Id, ScrollSink)
    @active_scroll : Id?

    # Canvas drag-to-scroll (upstream egui touch semantics, works with
    # the mouse too): a press on empty space — no drag-sensing widget
    # under the pointer — drags the top-most scroll viewport under the
    # press instead. The owner is that viewport's scroll id (latched at
    # press, cleared at release); the delta is this frame's pointer
    # delta while the gesture lives. Drag-sensing widgets (sliders,
    # text selection, paint canvases) claim the gesture through the
    # normal widget drag machine; click-only widgets let the finger
    # swipe scroll — the standard mobile-list behavior.
    @canvas_drag_owner : Id?
    @canvas_drag_delta : Vec2 = Vec2.zero

    # Long-press (Android semantics): a primary press held stationary
    # for LONG_PRESS_TIME synthesizes a secondary press at the pointer —
    # the gesture every context menu opens on (Response#context_menu).
    # The original press's pending click/drag are cancelled (an Android
    # long-press never also clicks); the widget under the pointer keeps
    # seeing plain down/hover.
    LONG_PRESS_TIME = 0.5
    @long_press_done : Bool = false
    @long_press_fired : Bool = false
    @long_press_pos : Pos2? = nil

    # --- widget geometry: id slots (FPS_OPTIMIZATION.md §3, этап 1) ---
    # Per-widget frame data lives in parallel SoA arrays indexed by a
    # stable per-id SLOT, not in per-frame Hashes: #interact costs one
    # `id → slot` hash lookup instead of eight hash operations, and
    # frame rotation is an array swap — no rehashing, no per-frame
    # allocation. Validity is an absolute-generation stamp ("written
    # this frame" ⇔ stamp == @geo_gen), so rotation clears nothing.
    # @slot_order keeps REGISTRATION order (the iteration order the
    # old Hash model had): hit-test tie-breaks ("last registered wins
    # on equal z") and readers of #widget_rects.values depend on it.
    @slot_ids : Array(Id)           # slot → id (stale entries for freed slots)
    @slot_of : Hash(Id, Int32)      # id → slot (live ids only)
    @slot_free : Array(Int32)       # recycled slots (freed at end_frame)
    @geo_gen : Int32                # frame generation for stamps

    @cur_stamp : Array(Int32)       # interacted this frame ⇔ == @geo_gen
    @cur_used : Array(Int32)        # interacted OR #use_id this frame
    @cur_rects : Array(Rect)
    @cur_senses : Array(Sense)
    @cur_layers : Array(LayerId)
    @cur_clips : Array(Rect)
    @cur_order : Array(Int32)       # slots in this frame's registration order

    @prv_stamp : Array(Int32)       # valid prev geometry ⇔ == @geo_gen - 1
    @prv_rects : Array(Rect)
    @prv_senses : Array(Sense)
    @prv_layers : Array(LayerId)
    @prv_clips : Array(Rect)
    @prv_order : Array(Int32)       # last frame's registration order

    @used_ids : Set(Id)             # rebuilt in #end_frame from @cur_used

    # Lazy Hash views over the SoA arrays — the old public getters.
    # Rebuilt on first read after any write (@geo_version); the frame
    # itself never pays for Hash maintenance.
    @geo_version : Int32
    @rects_view : Hash(Id, Rect)
    @rects_view_at : Int32
    @prev_rects_view : Hash(Id, Rect)
    @prev_rects_view_at : Int32
    @prev_senses_view : Hash(Id, Sense)
    @prev_senses_view_at : Int32
    @prev_layers_view : Hash(Id, LayerId)
    @prev_layers_view_at : Int32

    # Interaction state machine (egui InteractionState + PointerState).
    @press_pos : Pos2?
    @press_time : Float64
    # Whether the current press came from a finger (InputState#
    # touch_pointer?, latched at press): picks the slop and the touch
    # gesture semantics for the whole press, even if pointer events of
    # the other kind arrive mid-gesture.
    @press_touch : Bool = false
    @potential_click_id : Id?
    @potential_drag_id : Id?
    @dragging_id : Id?
    @drag_started_id : Id?
    @drag_stopped_id : Id?
    @moved_too_much_for_click : Bool
    @clicked_id : Id?
    @clicked_count : Int32
    # Where a completed click gesture landed, even when no widget was
    # hit (empty space/label) — popup close-on-outside needs it.
    @any_click_pos : Pos2?
    @last_click_pos : Pos2?
    @last_click_time : Float64
    @last_click_count : Int32

    @pointer_pos : Pos2?
    @pointer_down : Bool
    @pointer_delta : Vec2

    # Hover occlusion (upstream `Context::interact`'s
    # `is_covered_by_another_layer`): the z of the topmost interactive
    # layer under the pointer, resolved against the previous frame's
    # geometry in #begin_frame. A widget is hovered only when its own
    # layer's z equals it — the button a dropdown menu covers must not
    # highlight through the menu.
    @hover_top_z : Int32?

    # Modal state (egui `InteractionSnapshot` blocking): while a modal
    # is open, widgets on layers below Foreground get no interaction.
    # The flag is latched one frame (set during rendering, effective
    # from the next begin_frame) so ordering within a frame doesn't
    # matter — same trick as Focus.
    @modal_open : Bool
    @modal_next : Bool

    def initialize
      @data = IdTypeMap.new
      @areas = Areas.new
      @focus = Focus.new
      @animations = AnimationManager.new
      @style_animations = StyleAnimations.new
      @appear_anims = AppearAnims.new
      @keyframe_anims = KeyframeAnims.new
      @open_popups = Set(Id).new
    @popups_opened_this_frame = Set(Id).new
    @tooltip_starts = {} of Id => Float64
    @menu_open = nil
    @layer_sizes = {} of Id => Vec2
    @virtual_rows = {} of Id => Hash(UInt64, Tuple(Float64, UInt64))
    @virtual_row_widths = {} of Id => Float64
    @inline_box_widths = {} of Id => Float64
    @fixed_size_layers = Set(Id).new
    @popup_rects = {} of Id => Rect
    @texture_cache = {} of String => UInt64
    @color_cache = {} of Color32 => Hsva
    @scroll_rects = {} of Id => ScrollSink
    @prev_scroll_rects = {} of Id => ScrollSink
    @active_scroll = nil
    @canvas_drag_owner = nil
    @canvas_drag_delta = Vec2.zero
    # Offset histories feeding kinetic scrolling (see history.cr) —
    # keyed by the scroll area id, pruned with the rest.
    @scroll_histories = {} of Id => History
      @duplicate_ids = [] of Id

      @slot_ids = [] of Id
      @slot_of = {} of Id => Int32
      @slot_free = [] of Int32
      @geo_gen = 1
      @cur_stamp = [] of Int32
      @cur_used = [] of Int32
      @cur_rects = [] of Rect
      @cur_senses = [] of Sense
      @cur_layers = [] of LayerId
      @cur_clips = [] of Rect
      @cur_order = [] of Int32
      @prv_stamp = [] of Int32
      @prv_rects = [] of Rect
      @prv_senses = [] of Sense
      @prv_layers = [] of LayerId
      @prv_clips = [] of Rect
      @prv_order = [] of Int32
      @used_ids = Set(Id).new
      @geo_version = 1
      @rects_view = {} of Id => Rect
      @rects_view_at = 0
      @prev_rects_view = {} of Id => Rect
      @prev_rects_view_at = 0
      @prev_senses_view = {} of Id => Sense
      @prev_senses_view_at = 0
      @prev_layers_view = {} of Id => LayerId
      @prev_layers_view_at = 0
      # Text-input widgets created this frame (id → soft-keyboard profile
      # + editor mirror). Registered every frame by the widget (like
      # senses); the backend reads the FOCUSED entry after the frame to
      # show/hide the Android IME and feed it editor state (see
      # Context#wants_text_input? / Sokol#sync_android_ime).
      @text_inputs = {} of Id => NamedTuple(kind: TextInputKind, action: TextInputAction,
                                            text: String, cursor: Int32, anchor: Int32)

      @press_pos = nil
      @press_time = 0.0
      @potential_click_id = nil
      @potential_drag_id = nil
      @dragging_id = nil
      @drag_started_id = nil
      @drag_stopped_id = nil
      @moved_too_much_for_click = false
      @long_press_done = false
      @long_press_fired = false
      @long_press_pos = nil
      @clicked_id = nil
      @clicked_count = 0
      @any_click_pos = nil
      @last_click_pos = nil
      @last_click_time = -1.0
      @last_click_count = 0

      @pointer_pos = nil
      @pointer_down = false
      @pointer_delta = Vec2.zero
      @focus_press_pos = nil
      @hover_top_z = nil
      @modal_open = false
      @modal_next = false
    end

    def begin_frame(input : InputState) : Nil
      @modal_open = @modal_next
      @modal_next = false
      @popups_opened_this_frame.clear

      # Rotate scroll viewports and decide who owns this frame's scroll
      # delta: the top-most viewport containing the pointer (highest
      # layer z; on a tie the last registered wins, like paint order).
      # Scroll chaining: sinks that cannot serve the wheel's axis this
      # frame (plain vertical wheel vs an hbar-only strip, content that
      # fits) are skipped — the sink under them gets the delta.
      @prev_scroll_rects = @scroll_rects
      @scroll_rects = {} of Id => ScrollSink
      @active_scroll = nil
      if pos = input.pointer_pos
        shift = input.modifiers.shift
        wheel_v = input.scroll.y != 0.0 && !shift
        wheel_h = input.scroll.x != 0.0 || (input.scroll.y != 0.0 && shift)
        @active_scroll = topmost_scroll_at(pos,
          require_v: wheel_v, require_h: wheel_h)
      end
      # Rotate last frame's geometry/sense/layer into the prev_* slots so
      # pointer events hit-test against stable, complete information.
      # SoA rotation: swap the array pairs and bump the generation —
      # no copying, no clearing (validity is `stamp == @geo_gen`,
      # absolute generations, so stale entries invalidate themselves).
      @prv_stamp, @cur_stamp = @cur_stamp, @prv_stamp
      @prv_rects, @cur_rects = @cur_rects, @prv_rects
      @prv_senses, @cur_senses = @cur_senses, @prv_senses
      @prv_layers, @cur_layers = @cur_layers, @prv_layers
      @prv_clips, @cur_clips = @cur_clips, @prv_clips
      @prv_order, @cur_order = @cur_order, @prv_order
      @cur_order.clear
      @geo_gen += 1
      @geo_version += 1
      @text_inputs.clear
      @duplicate_ids.clear

      # Resolve this frame's hover occlusion: union the previous
      # frame's interactive widgets per layer, then take the highest-z
      # layer whose union covers the pointer. Layers with only
      # non-interactive widgets (labels, tooltips are paint-only) never
      # block what's under them.
      @hover_top_z = nil
      if pos = input.pointer_pos
        layer_rects = {} of LayerId => Rect
        @prv_order.each do |i|
          sense = @prv_senses[i]
          next if sense.none?
          layer = @prv_layers[i]
          next if @modal_open && !layer.order.foreground?
          rect = @prv_rects[i]
          if (hit = layer_rects[layer]?)
            layer_rects[layer] = hit.union(rect)
          else
            layer_rects[layer] = rect
          end
        end
        layer_rects.each do |layer, rect|
          next unless rect.contains?(pos)
          @hover_top_z = layer.z if @hover_top_z.nil? || layer.z > @hover_top_z.not_nil!
        end
      end

      @focus.begin_frame
      @clicked_id = nil
      @clicked_count = 0
      @any_click_pos = nil
      @drag_started_id = nil
      @drag_stopped_id = nil
      @long_press_fired = false

      # --- press: record both candidates, like egui InteractionState ---
      if input.pointer_pressed?
        @press_pos = input.pointer_pos
        @press_time = input.time
        @press_touch = input.touch_pointer?
        @moved_too_much_for_click = false
        @long_press_done = false
        @long_press_pos = nil
        @potential_click_id = topmost_at(input.pointer_pos) { |s| s.click? }
        @potential_drag_id = topmost_at(input.pointer_pos) { |s| s.drag? }
        @dragging_id = nil
        # A widget that senses drag but not click has nothing to
        # disambiguate, so the drag starts on press — no movement
        # threshold (upstream interaction.rs: "just sensitive to drags,
        # so we can mark it as dragged right away"). This is what makes
        # clicking anywhere on a slider rail set the value immediately.
        if (candidate = @potential_drag_id) &&
           !(ci = @slot_of[candidate]?).try { |i| @prv_stamp[i] == @geo_gen - 1 && @prv_senses[i].click? }
          @dragging_id = candidate
          @drag_started_id = candidate
        end
      end

      # --- motion while pressed: decide click vs drag ---
      if (origin = @press_pos) && input.pointer_down? && (pos = input.pointer_pos)
        # Touch presses get the finger-sized slop (TOUCH_MAX_DIST): a
        # wobbling tap stays a tap, and the long-press timeout below
        # survives finger jitter.
        if (pos - origin).length >
           (@press_touch ? TOUCH_MAX_DIST : CLICK_MAX_DIST)
          @moved_too_much_for_click = true
          if @dragging_id.nil? && (candidate = @potential_drag_id)
            @dragging_id = candidate
            @drag_started_id = candidate
          end
        end
      end

      # --- release: click classification (single/double/triple) ---
      if input.pointer_released?
        # A completed click gesture anywhere on screen — even when no
        # widget was hit (empty space), which is exactly the case
        # close-on-outside-click must catch. A release that ends a
        # LONG-PRESS is not a click: it must not act anywhere (not
        # close the menu it just opened, not press a button).
        @any_click_pos = input.pointer_pos unless @moved_too_much_for_click || @long_press_done
        click_id = @potential_click_id
        if click_id && !@moved_too_much_for_click && !@long_press_done &&
           rect_contains?(click_id, input.pointer_pos)
          count = 1
          if (last_pos = @last_click_pos) && @last_click_time >= 0.0 &&
             input.pointer_pos && (input.pointer_pos.not_nil! - last_pos).length <= CLICK_MAX_DIST &&
             input.time - @last_click_time <= DOUBLE_CLICK_TIME
            count = @last_click_count >= 3 ? 1 : @last_click_count + 1
          end
          @clicked_id = click_id
          @clicked_count = count
          @last_click_pos = input.pointer_pos
          @last_click_time = input.time
          @last_click_count = count
        end
        @drag_stopped_id = @dragging_id if @dragging_id
        @dragging_id = nil
        @press_pos = nil
        @potential_click_id = nil
        @potential_drag_id = nil
      end

      # --- long-press → synthetic secondary press (context menus) ---
      # Fires once per press, only while the pointer stayed put (the
      # click-vs-drag threshold doubles as the wiggle room) and no
      # widget drag engaged. It must NOT disturb the press state:
      # hold-repeat widgets (NumberInput spin buttons) read `pressed?`
      # while held, and the drag candidate lets a long-press-then-drag
      # extend a text selection. The release CLICK is suppressed in
      # the release block below via `@long_press_done` instead (an
      # Android long-press never also clicks).
      if (origin = @press_pos) && input.pointer_down? &&
         !@long_press_done && !@moved_too_much_for_click &&
         @dragging_id.nil? &&
         input.time - @press_time >= LONG_PRESS_TIME
        @long_press_done = true
        @long_press_fired = true
        @long_press_pos = input.pointer_pos
      end

      @pointer_down = input.pointer_down?
      @pointer_pos = input.pointer_pos
      @pointer_delta = input.pointer_delta

      # Canvas drag-to-scroll gesture bookkeeping (see the field comment
      # above): latch the owner scroll viewport at press — only when NO
      # drag-sensing widget was under the pointer (that widget would own
      # the gesture) and the press is inside a scroll viewport (previous
      # frame's registration, like every hit-test here); accumulate the
      # per-frame pointer delta while the pointer stays down.
      @canvas_drag_delta = Vec2.zero
      if input.pointer_pressed? && @potential_drag_id.nil? &&
         (pos = input.pointer_pos)
        @canvas_drag_owner = topmost_scroll_at(pos)
      elsif !input.pointer_down?
        @canvas_drag_owner = nil
      elsif @canvas_drag_owner
        @canvas_drag_delta = @pointer_delta
      end
      # A press this frame: checked at end_frame against the focused
      # widget's rect (see #end_frame — the click-outside-clears-focus
      # rule, upstream egui behavior).
      @focus_press_pos = input.pointer_pos if input.pointer_pressed?

      navigate_focus(input)
    end

    def end_frame : Nil
      # Rebuild the used-id set from the slot stamps (registration
      # order), free the slots of widgets absent this frame, compact
      # when recycling has left too many holes. The freed slots' prev
      # data may still be pending in the arrays — that is exactly the
      # hash model's semantics (a widget's geometry stays hit-testable
      # for one frame after it disappears), and the stamps keep it
      # readable until the next rotation makes it stale.
      @used_ids.clear
      @slot_ids.each_with_index do |id, i|
        if @cur_used[i] == @geo_gen
          @used_ids.add(id)
        else
          @slot_of.delete(id)
          @slot_free << i
        end
      end
      compact_slots if @slot_free.size > @slot_ids.size // 2
      # Prune per-widget state of widgets that no longer exist (egui
      # `Memory::end_pass(used_ids)`).
      @data.keep_only(@used_ids)
      @scroll_histories.select! { |id, _| @used_ids.includes?(id) }
      @appear_anims.select_used!(@used_ids)
      close_popups_if_clicked_elsewhere
      # egui: a pointer press that didn't land on the focused widget
      # drops keyboard focus — click/tap outside a text field and the
      # focus (and with it the mobile soft keyboard) goes away. A press
      # on ANOTHER focusable already re-requested focus during update
      # and its rect contains the press, so it survives.
      if (pos = @focus_press_pos) && (fid = @focus.id)
        rect = nil
        if (i = @slot_of[fid]?) && @cur_stamp[i] == @geo_gen
          rect = @cur_rects[i]
        end
        @focus.clear if rect.nil? || !rect.contains?(pos)
      end
      @focus_press_pos = nil
    end

    def modal_open? : Bool
      @modal_open
    end

    # The state string ("hover"/"active"/nil) a widget's cascade will
    # resolve to THIS frame — a mirror of the verdict #interact is
    # about to produce, derived from the same sources (previous
    # frame's geometry, pointer, press state). Deterministic BEFORE
    # registration: the paint cache keys on it so a hover switch
    # changes the key (rebuild) while steady hover replays. Keep in
    # sync with #interact's hovered/pressed logic.
    def interaction_state(id : Id) : String?
      return nil if @disabled_depth > 0
      if (p = @pointer_pos) && @pointer_down &&
         @potential_click_id == id && !@moved_too_much_for_click
        return "active"
      end
      return nil unless (p = @pointer_pos)
      if (i = @slot_of[id]?) && @prv_stamp[i] == @geo_gen - 1
        layer = @prv_layers[i]
        return nil if @modal_open && !layer.order.foreground?
        if (@hover_top_z.nil? || layer.z >= @hover_top_z.not_nil!) &&
           !@prv_senses[i].none? &&
           @prv_rects[i].contains?(p) && @prv_clips[i].contains?(p)
          return "hover"
        end
      end
      nil
    end

    # Called by ScrollArea while rendering: registers this frame's
    # viewport for next frame's arbitration. The viewport/content ids
    # also count as "used" so their IdTypeMap cells (offset, content
    # size) survive end-frame pruning — they have no #interact call of
    # their own (the scrollbar's id does, via ui.interact).
    # Mark an id as used this frame so its IdTypeMap cell survives
    # end-frame pruning (for state keys that have no #interact call of
    # their own — e.g. Grid's persisted column widths).
    def use_id(id : Id) : Nil
      # Marks the slot used without registering geometry (use_id ids
      # must not appear in #widget_rects).
      i = ensure_slot(id)
      @cur_used[i] = @geo_gen
    end

    # Register a scroll sink. `can_v`/`can_h` say which axes the sink
    # can actually scroll this frame (scroll chaining skips the rest —
    # see ScrollSink). Defaults keep every legacy sink always eligible.
    def register_scroll_area(id : Id, rect : Rect, layer : LayerId,
                             can_v : Bool = true,
                             can_h : Bool = true) : Nil
      @scroll_rects[id] = ScrollSink.new(rect, layer, can_v, can_h)
      # Via #use_id (slot stamp) — #end_frame rebuilds the used-id set
      # from the slots, so a direct set insert here would be wiped.
      use_id(id)
      use_id(id.child(0))
    end

    # The scroll area that owns this frame's scroll delta (nil = none).
    def active_scroll_area? : Id?
      @active_scroll
    end

    # Persistent offset history of a scrollable (kinetic scrolling).
    def scroll_history(id : Id) : History
      @scroll_histories[id] ||= History.new(2..128, 0.1)
    end

    # Called by Context#modal while rendering the modal this frame;
    # blocking takes effect from the next begin_frame.
    def mark_modal : Nil
      @modal_next = true
    end

    # --- ui.enabled(false) regions ---------------------------------------
    # Depth counter: while > 0 every #interact verdict is dead (widgets
    # still register, so their persistent state survives the gray-out).
    @disabled_depth = 0

    def push_disabled : Nil
      @disabled_depth += 1
    end

    def pop_disabled : Nil
      @disabled_depth = {0, @disabled_depth - 1}.max
    end

    def disabled? : Bool
      @disabled_depth > 0
    end

    # The interaction query every widget makes (egui `Context::interact`).
    # `clip` is the owning container's clip rect (panel/window/scroll
    # viewport): parts of a widget outside it are painted over by the
    # container below, so they must not be hit-tested either (upstream
    # `Context::interact` intersects with the layer's clip rect).
    def interact(id : Id, rect : Rect, sense : Sense,
                 layer : LayerId = LayerId.background,
                 clip : Rect = Rect.infinite) : InteractionVerdict
      # Duplicate ids are the classic immediate-mode bug: two widgets
      # minted the same id and fight over state. Record, don't crash.
      # One hash op (id → slot) instead of the eight the Hash model
      # paid (seen/used sets + four inserts + the duplicate probe).
      i = ensure_slot(id)
      if @cur_stamp[i] == @geo_gen
        @duplicate_ids << id unless @duplicate_ids.includes?(id)
      else
        @cur_stamp[i] = @geo_gen
        @cur_order << i
      end
      @cur_used[i] = @geo_gen
      @cur_rects[i] = rect
      @cur_senses[i] = sense
      @cur_layers[i] = layer
      @cur_clips[i] = clip
      @geo_version += 1

      # A modal blocks interaction with everything below its layer.
      if @modal_open && !layer.order.foreground?
        return InteractionVerdict.new(false, false, 0, false, false,
          false, false, Vec2.zero, false)
      end

      # `ui.enabled(false)`: dead verdicts, but the widget's state (and
      # registration above) survives the gray-out.
      return InteractionVerdict.new(false, false, 0, false, false,
        false, false, Vec2.zero, false) if @disabled_depth > 0

      # Focus keep-alive (upstream: focusables register interest every
      # frame): the focused focusable re-requests focus so the
      # dead-man's switch only fires when the widget disappears.
      @focus.keep_alive(id) if sense.focusable? && @focus.id == id

      pos = @pointer_pos
      # Hover needs no strictly-higher layer under the pointer
      # (@hover_top_z): rect containment alone would mark the button
      # under a popup as hovered too. When nothing interactive was under
      # the pointer last frame (fresh widget, empty frame), keep the
      # plain containment behavior (see #begin_frame).
      hovered = false
      if (p = pos) && (@hover_top_z.nil? || layer.z >= @hover_top_z.not_nil!) &&
         !sense.none?
        hovered = rect.contains?(p) && clip.contains?(p)
      end

      clicked = sense.click? && @clicked_id == id
      click_count = clicked ? @clicked_count : 0
      pressed = sense.click? && @pointer_down && @potential_click_id == id &&
                !@moved_too_much_for_click
      dragged = sense.drag? && @dragging_id == id
      drag_started = dragged && @drag_started_id == id
      drag_stopped = sense.drag? && @drag_stopped_id == id
      # Drag engages only after the CLICK_MAX_DIST click-vs-drag
      # threshold; @pointer_delta on that engagement frame covers just
      # the last frame's motion, silently dropping the sub-threshold
      # distance. On a mouse that's imperceptible; on touch it reads as
      # "the window doesn't grab / lags" — a dead zone on every grab.
      # Backfill on the engagement frame: delta = press → current.
      drag_delta = if dragged
                     if drag_started && (origin = @press_pos) &&
                        (p = @pointer_pos)
                       p - origin
                     else
                       @pointer_delta
                     end
                   else
                     Vec2.zero
                   end
      active = pressed || dragged

      InteractionVerdict.new(hovered, clicked, click_count, pressed,
        dragged, drag_started, drag_stopped, drag_delta, active)
    end

    # --- popups (egui popups: open set + click-elsewhere closes) -------

    def open_popup(id : Id) : Nil
      @open_popups.add(id)
      @popups_opened_this_frame.add(id)
    end

    def close_popup(id : Id) : Nil
      @open_popups.delete(id)
      @popups_opened_this_frame.delete(id)
      @popup_rects.delete(id)
    end

    def close_all_popups : Nil
      @open_popups.clear
      @popup_rects.clear
    end

    private def close_popups_if_clicked_elsewhere : Nil
      return if @open_popups.empty?
      pos = @any_click_pos
      return unless pos
      @open_popups.dup.each do |pop_id|
        # A popup opened by this very click survives it (the open happens
        # during rendering, after the click was classified).
        next if @popups_opened_this_frame.includes?(pop_id)
        # A click inside the popup — including its non-interactive parts
        # (frame padding, the calendar header) — is not "elsewhere".
        next if @popup_rects[pop_id]?.try(&.contains?(pos))
        @open_popups.delete(pop_id)
        @popup_rects.delete(pop_id)
      end
      # Drop a stale menu state if its popup just closed (the menu bar's
      # hover-to-switch reads it).
      if (menu = @menu_open) && !@open_popups.includes?(Id.from("popup/#{menu}"))
        @menu_open = nil
      end
    end

    # --- internals ------------------------------------------------------

    # Slot bookkeeping (see the field comment at the SoA block). A
    # recycled slot needs no stamp poisoning: stamps are absolute
    # generations, and a generation is never re-issued, so stale data
    # fails every `stamp == @geo_gen` comparison on its own.
    private def ensure_slot(id : Id) : Int32
      if (i = @slot_of[id]?)
        return i
      end
      if (i = @slot_free.pop?)
        @slot_ids[i] = id
      else
        i = @slot_ids.size
        @slot_ids.push(id)
        @cur_stamp.push(0)
        @prv_stamp.push(0)
        @cur_used.push(0)
        @cur_rects.push(Rect.zero)
        @prv_rects.push(Rect.zero)
        @cur_senses.push(Sense.none)
        @prv_senses.push(Sense.none)
        @cur_layers.push(LayerId.background)
        @prv_layers.push(LayerId.background)
        @cur_clips.push(Rect.infinite)
        @prv_clips.push(Rect.infinite)
      end
      @slot_of[id] = i
      i
    end

    # Drop freed slots wholesale and reindex (end_frame only, when
    # more than half the slots are holes): keeps the SoA arrays tight
    # for id-churning UIs (virtual lists). @prv_order is NOT remapped
    # on purpose — it is about to be cleared by the next rotation,
    # while @cur_order becomes the next frame's prev order and must
    # stay valid.
    private def compact_slots : Nil
      remap = Array(Int32).new(@slot_ids.size, -1)
      j = 0
      @slot_ids.each_with_index do |id, i|
        next unless @slot_of[id]? == i # freed slots were unmapped
        remap[i] = j
        if j != i
          @slot_ids[j] = id
          @slot_of[id] = j
          @cur_stamp[j] = @cur_stamp[i]
          @prv_stamp[j] = @prv_stamp[i]
          @cur_used[j] = @cur_used[i]
          @cur_rects[j] = @cur_rects[i]
          @prv_rects[j] = @prv_rects[i]
          @cur_senses[j] = @cur_senses[i]
          @prv_senses[j] = @prv_senses[i]
          @cur_layers[j] = @cur_layers[i]
          @prv_layers[j] = @prv_layers[i]
          @cur_clips[j] = @cur_clips[i]
          @prv_clips[j] = @prv_clips[i]
        end
        j += 1
      end
      return if j == @slot_ids.size
      drop = @slot_ids.size - j
      @slot_ids.pop(drop)
      @cur_stamp.pop(drop)
      @prv_stamp.pop(drop)
      @cur_used.pop(drop)
      @cur_rects.pop(drop)
      @prv_rects.pop(drop)
      @cur_senses.pop(drop)
      @prv_senses.pop(drop)
      @cur_layers.pop(drop)
      @prv_layers.pop(drop)
      @cur_clips.pop(drop)
      @prv_clips.pop(drop)
      @slot_free.clear
      @cur_order.map! { |i| remap[i] }
      @geo_version += 1
    end

    # --- lazy Hash views (the old public getters) -----------------------
    # Rebuilt on first read after any geometry write or rotation
    # (@geo_version); the frame path itself never pays for them.
    # Order follows registration order, like the Hash model's
    # insertion order (specs read #widget_rects.values positionally).

    def widget_rects : Hash(Id, Rect)
      if @rects_view_at != @geo_version
        @rects_view.clear
        @cur_order.each do |i|
          @rects_view[@slot_ids[i]] = @cur_rects[i] if @cur_stamp[i] == @geo_gen
        end
        @rects_view_at = @geo_version
      end
      @rects_view
    end

    def prev_widget_rects : Hash(Id, Rect)
      if @prev_rects_view_at != @geo_version
        @prev_rects_view.clear
        @prv_order.each do |i|
          @prev_rects_view[@slot_ids[i]] = @prv_rects[i] if @prv_stamp[i] == @geo_gen - 1
        end
        @prev_rects_view_at = @geo_version
      end
      @prev_rects_view
    end

    def prev_widget_senses : Hash(Id, Sense)
      if @prev_senses_view_at != @geo_version
        @prev_senses_view.clear
        @prv_order.each do |i|
          @prev_senses_view[@slot_ids[i]] = @prv_senses[i] if @prv_stamp[i] == @geo_gen - 1
        end
        @prev_senses_view_at = @geo_version
      end
      @prev_senses_view
    end

    def prev_widget_layers : Hash(Id, LayerId)
      if @prev_layers_view_at != @geo_version
        @prev_layers_view.clear
        @prv_order.each do |i|
          @prev_layers_view[@slot_ids[i]] = @prv_layers[i] if @prv_stamp[i] == @geo_gen - 1
        end
        @prev_layers_view_at = @geo_version
      end
      @prev_layers_view
    end

    # Keyboard focus navigation (upstream `Focus` + memory/mod.rs):
    # Tab / Shift+Tab cycles focusables in creation order; arrows move
    # geometrically to the nearest focusable in that direction, unless
    # the focused widget locked them (slider/drag value). Runs against
    # the previous frame's geometry, before any widget renders.
    # --- soft keyboard (Android IME) -------------------------------------
    # Widgets call #register_text_input while drawing (every frame, like
    # sense registration); the backend asks #focused_text_input after the
    # frame — non-nil means the system keyboard should be up. The editor
    # mirror (text/cursor/anchor) feeds the IME's editor queries and
    # selection updates — native-editor behavior Gboard's hold-to-delete
    # and autocorrect rely on.

    def register_text_input(id : Id, kind : TextInputKind,
                            action : TextInputAction, text : String,
                            cursor : Int32, anchor : Int32) : Nil
      @text_inputs[id] = {kind: kind, action: action, text: text,
                          cursor: cursor, anchor: anchor}
    end

    def focused_text_input : NamedTuple(kind: TextInputKind, action: TextInputAction,
                                        text: String, cursor: Int32, anchor: Int32)?
      @focus.id.try { |fid| @text_inputs[fid]? }
    end

    private def navigate_focus(input : InputState) : Nil
      # The focused widget claimed the whole keyboard (a terminal
      # passing Tab/arrows to its child): no focus navigation at all.
      return if @focus.lock_keyboard?

      focusables = [] of Id
      @prv_order.each do |i|
        focusables << @slot_ids[i] if @prv_senses[i].focusable?
      end
      return if focusables.empty?

      if input.key_pressed?(KeyCode::Tab) && !input.modifiers.alt &&
         !input.modifiers.ctrl
        input.consume_key(KeyCode::Tab)
        index = focusables.index(@focus.id) || -1
        step = input.modifiers.shift ? -1 : 1
        @focus.request(focusables[(index + step) % focusables.size])
        return
      end

      focused = @focus.id
      return unless focused && (fi = @slot_of[focused]?) &&
                    @prv_stamp[fi] == @geo_gen - 1 &&
                    (from_rect = @prv_rects[fi])

      key : KeyCode? = nil
      dir = Vec2.zero
      if !@focus.lock_h? && input.key_pressed?(KeyCode::Left)
        key, dir = KeyCode::Left, Vec2.new(-1.0, 0.0)
      elsif !@focus.lock_h? && input.key_pressed?(KeyCode::Right)
        key, dir = KeyCode::Right, Vec2.new(1.0, 0.0)
      elsif !@focus.lock_v? && input.key_pressed?(KeyCode::Up)
        key, dir = KeyCode::Up, Vec2.new(0.0, -1.0)
      elsif !@focus.lock_v? && input.key_pressed?(KeyCode::Down)
        key, dir = KeyCode::Down, Vec2.new(0.0, 1.0)
      end
      return unless key

      from = from_rect.center
      horizontal = dir.x != 0.0
      best : Id? = nil
      best_distance = Float64::INFINITY
      focusables.each do |id|
        next if id == focused
        delta = @prv_rects[@slot_of[id].not_nil!].center - from
        in_dir = delta.x * dir.x + delta.y * dir.y
        next unless in_dir > 0.0
        if horizontal
          next unless delta.x.abs >= delta.y.abs
        else
          next unless delta.y.abs >= delta.x.abs
        end
        if in_dir < best_distance
          best_distance = in_dir
          best = id
        end
      end

      if best_id = best
        input.consume_key(key.not_nil!)
        @focus.request(best_id)
      end
    end


    # Topmost widget containing `pos` whose sense satisfies the filter.
    # Layer z wins first (see `layer.cr`: paint order and hit-test
    # priority follow z — a popup on layer 99 always beats the panel
    # under it, even though the popup registers earlier in the frame);
    # within the same z the last registration (paint order) is on top.
    # Hit-tests resolve against the previous frame's geometry.
    # The topmost registered widget (any sense) at `pos`, against the
    # previous frame's geometry.
    def widget_at(pos : Pos2?) : Id?
      topmost_at(pos) { |_sense| true }
    end

    # EVERY registered widget (any sense) containing `pos`, against the
    # previous frame's geometry — outermost first (rect area descending).
    # The inspector's pick menu offers all of them so a composite widget
    # (Markdown and the RichLabels it is built from) is inspectable down
    # to its parts; `#widget_at` alone would always answer the root,
    # which interacts last and covers the whole body.
    def widgets_at(pos : Pos2?) : Array(Id)
      return [] of Id unless pos
      hits = [] of {Id, Float64}
      @prv_order.each do |i|
        rect = @prv_rects[i]
        next unless rect.contains?(pos)
        clip = @prv_clips[i]
        next if clip && !clip.contains?(pos)
        layer = @prv_layers[i]
        next if @modal_open && !layer.order.foreground?
        hits << {@slot_ids[i], rect.width * rect.height}
      end
      hits.sort_by! { |_, area| -area }
      hits.map(&.[0])
    end

    # --- long-press (see the field comment above) ----------------------

    # True on the frame the long-press timeout fired (one-frame flag —
    # the synthetic secondary press for context menus).
    def long_press_fired? : Bool
      @long_press_fired
    end

    # Where the long-press fired (the held pointer position).
    def long_press_pos : Pos2?
      @long_press_pos
    end

    # The current press came from a finger (see @press_touch): touch
    # slop and touch gesture semantics apply to this gesture.
    def press_touch? : Bool
      @press_touch
    end

    # The current gesture IS a completed long-press with the pointer
    # still held (press state lives until release): text fields let
    # movement now EXTEND the selection instead of scrolling.
    def long_press_active? : Bool
      !@press_pos.nil? && @long_press_done
    end

    # A press is still within the long-press window (pending): the
    # frame loop keeps frames coming so the timeout can fire without
    # any further input (touch holds generate no events).
    def long_press_armed? : Bool
      !@press_pos.nil? && !@long_press_done
    end

    # --- canvas drag-to-scroll (see the field comment above) ----------
    # True while the drag-to-scroll gesture is owned by scroll area
    # `id` (finger/mouse down on its empty canvas).
    def canvas_drag_active?(id : Id) : Bool
      @canvas_drag_owner == id
    end

    # This frame's pointer delta of the canvas drag owned by scroll
    # area `id` (zero for everyone else / while still).
    def canvas_drag_delta(id : Id) : Vec2
      @canvas_drag_owner == id ? @canvas_drag_delta : Vec2.zero
    end

    # The top-most scroll viewport (previous frame's registration)
    # containing `pos` — same arbitration as the wheel delta owner
    # (highest layer z wins; on a tie the last registered, i.e. the
    # inner-most viewport painted last).
    # The top-most sink containing `pos`. `require_v`/`require_h`:
    # skip sinks that cannot scroll the axis the wheel intends this
    # frame (both false — plain hit-test, e.g. the canvas-drag latch).
    private def topmost_scroll_at(pos : Pos2, require_v : Bool = false,
                                  require_h : Bool = false) : Id?
      hit : Id? = nil
      hit_z = 0
      @prev_scroll_rects.each do |id, sink|
        next unless sink.rect.contains?(pos)
        if @modal_open
          next unless sink.layer.order.foreground?
        end
        next if require_v && !sink.can_v
        next if require_h && !sink.can_h
        if hit.nil? || sink.layer.z >= hit_z
          hit = id
          hit_z = sink.layer.z
        end
      end
      hit
    end

    private def topmost_at(pos : Pos2?, &sense_filter : Sense -> Bool) : Id?
      return nil unless pos
      hit = nil
      hit_z = 0
      @prv_order.each do |i|
        rect = @prv_rects[i]
        next unless rect.contains?(pos)
        next unless sense_filter.call(@prv_senses[i])
        clip = @prv_clips[i]
        next if clip && !clip.contains?(pos)
        layer = @prv_layers[i]
        if @modal_open
          next unless layer.order.foreground?
        end
        if hit.nil? || layer.z >= hit_z
          hit = @slot_ids[i]
          hit_z = layer.z
        end
      end
      hit
    end

    private def rect_contains?(id : Id, pos : Pos2?) : Bool
      return false unless pos
      if (i = @slot_of[id]?)
        # Previous frame's geometry wins (like the hash model's
        # `prev || current`); stamps decide which is valid.
        if @prv_stamp[i] == @geo_gen - 1
          rect = @prv_rects[i]
          clip = @prv_clips[i]
        elsif @cur_stamp[i] == @geo_gen
          rect = @cur_rects[i]
          clip = @cur_clips[i]
        else
          return false
        end
        return false unless rect.contains?(pos)
        return !clip || clip.contains?(pos)
      end
      false
    end
  end
end
