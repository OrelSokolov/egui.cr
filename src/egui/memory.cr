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

    getter data : IdTypeMap
    getter areas : Areas
    getter focus : Focus
    getter animations : AnimationManager
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

    # Scroll-area viewports (id → rect + layer) for scroll arbitration:
    # the top-most viewport containing the pointer (previous frame's
    # geometry, like widget hit-testing) owns this frame's scroll delta.
    getter scroll_rects : Hash(Id, Tuple(Rect, LayerId))
    @prev_scroll_rects : Hash(Id, Tuple(Rect, LayerId))
    @active_scroll : Id?

    # Geometry/sense/layer of the previous frame (hit-test input)…
    getter prev_widget_rects : Hash(Id, Rect)
    getter prev_widget_senses : Hash(Id, Sense)
    getter prev_widget_layers : Hash(Id, LayerId)
    # …and registrations so far this frame.
    getter widget_rects : Hash(Id, Rect)

    @widget_senses : Hash(Id, Sense)
    @widget_layers : Hash(Id, LayerId)
    @widget_clips : Hash(Id, Rect)
    @used_ids : Set(Id)
    @seen_ids : Set(Id)

    # Interaction state machine (egui InteractionState + PointerState).
    @press_pos : Pos2?
    @press_time : Float64
    @potential_click_id : Id?
    @potential_drag_id : Id?
    @dragging_id : Id?
    @drag_started_id : Id?
    @drag_stopped_id : Id?
    @moved_too_much_for_click : Bool
    @clicked_id : Id?
    @clicked_count : Int32
    @last_click_pos : Pos2?
    @last_click_time : Float64
    @last_click_count : Int32

    @pointer_pos : Pos2?
    @pointer_down : Bool
    @pointer_delta : Vec2

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
      @open_popups = Set(Id).new
    @popups_opened_this_frame = Set(Id).new
    @tooltip_starts = {} of Id => Float64
    @menu_open = nil
    @layer_sizes = {} of Id => Vec2
    @texture_cache = {} of String => UInt64
    @color_cache = {} of Color32 => Hsva
    @scroll_rects = {} of Id => Tuple(Rect, LayerId)
    @prev_scroll_rects = {} of Id => Tuple(Rect, LayerId)
    @active_scroll = nil
      @duplicate_ids = [] of Id

      @prev_widget_rects = {} of Id => Rect
      @prev_widget_senses = {} of Id => Sense
      @prev_widget_layers = {} of Id => LayerId
      @prev_widget_clips = {} of Id => Rect
      @widget_rects = {} of Id => Rect
      @widget_senses = {} of Id => Sense
      @widget_layers = {} of Id => LayerId
      @widget_clips = {} of Id => Rect
      @used_ids = Set(Id).new
      @seen_ids = Set(Id).new

      @press_pos = nil
      @press_time = 0.0
      @potential_click_id = nil
      @potential_drag_id = nil
      @dragging_id = nil
      @drag_started_id = nil
      @drag_stopped_id = nil
      @moved_too_much_for_click = false
      @clicked_id = nil
      @clicked_count = 0
      @last_click_pos = nil
      @last_click_time = -1.0
      @last_click_count = 0

      @pointer_pos = nil
      @pointer_down = false
      @pointer_delta = Vec2.zero
      @modal_open = false
      @modal_next = false
    end

    def begin_frame(input : InputState) : Nil
      @modal_open = @modal_next
      @modal_next = false
      @popups_opened_this_frame.clear

      # Rotate scroll viewports and decide who owns this frame's scroll
      # delta: top-most (last registered) viewport containing the pointer.
      @prev_scroll_rects = @scroll_rects
      @scroll_rects = {} of Id => Tuple(Rect, LayerId)
      @active_scroll = nil
      if pos = input.pointer_pos
        @prev_scroll_rects.each do |id, (rect, layer)|
          if @modal_open && !layer.order.foreground?
            next
          end
          @active_scroll = id if rect.contains?(pos)
        end
      end
      # Rotate last frame's geometry/sense/layer into the prev_* slots so
      # pointer events hit-test against stable, complete information.
      @prev_widget_rects = @widget_rects
      @prev_widget_senses = @widget_senses
      @prev_widget_layers = @widget_layers
      @prev_widget_clips = @widget_clips
      @widget_rects = {} of Id => Rect
      @widget_senses = {} of Id => Sense
      @widget_layers = {} of Id => LayerId
      @widget_clips = {} of Id => Rect
      @used_ids.clear
      @seen_ids.clear
      @duplicate_ids.clear

      @focus.begin_frame
      @clicked_id = nil
      @clicked_count = 0
      @drag_started_id = nil
      @drag_stopped_id = nil

      # --- press: record both candidates, like egui InteractionState ---
      if input.pointer_pressed?
        @press_pos = input.pointer_pos
        @press_time = input.time
        @moved_too_much_for_click = false
        @potential_click_id = topmost_at(input.pointer_pos) { |s| s.click? }
        @potential_drag_id = topmost_at(input.pointer_pos) { |s| s.drag? }
        @dragging_id = nil
        # A widget that senses drag but not click has nothing to
        # disambiguate, so the drag starts on press — no movement
        # threshold (upstream interaction.rs: "just sensitive to drags,
        # so we can mark it as dragged right away"). This is what makes
        # clicking anywhere on a slider rail set the value immediately.
        if (candidate = @potential_drag_id) &&
           !@prev_widget_senses[candidate]?.try(&.click?)
          @dragging_id = candidate
          @drag_started_id = candidate
        end
      end

      # --- motion while pressed: decide click vs drag ---
      if (origin = @press_pos) && input.pointer_down? && (pos = input.pointer_pos)
        if (pos - origin).length > CLICK_MAX_DIST
          @moved_too_much_for_click = true
          if @dragging_id.nil? && (candidate = @potential_drag_id)
            @dragging_id = candidate
            @drag_started_id = candidate
          end
        end
      end

      # --- release: click classification (single/double/triple) ---
      if input.pointer_released?
        click_id = @potential_click_id
        if click_id && !@moved_too_much_for_click &&
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

      @pointer_pos = input.pointer_pos
      @pointer_down = input.pointer_down?
      @pointer_delta = input.pointer_delta

      navigate_focus(input)
    end

    def end_frame : Nil
      # Prune per-widget state of widgets that no longer exist (egui
      # `Memory::end_pass(used_ids)`).
      @data.keep_only(@used_ids)
      close_popups_if_clicked_elsewhere
    end

    def modal_open? : Bool
      @modal_open
    end

    # Called by ScrollArea while rendering: registers this frame's
    # viewport for next frame's arbitration. The viewport/content ids
    # also count as "used" so their IdTypeMap cells (offset, content
    # size) survive end-frame pruning — they have no #interact call of
    # their own (the scrollbar's id does, via ui.interact).
    def register_scroll_area(id : Id, rect : Rect, layer : LayerId) : Nil
      @scroll_rects[id] = {rect, layer}
      @used_ids.add(id)
      @used_ids.add(id.child(0))
    end

    # The scroll area that owns this frame's scroll delta (nil = none).
    def active_scroll_area? : Id?
      @active_scroll
    end

    # Called by Context#modal while rendering the modal this frame;
    # blocking takes effect from the next begin_frame.
    def mark_modal : Nil
      @modal_next = true
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
      if @seen_ids.includes?(id)
        @duplicate_ids << id unless @duplicate_ids.includes?(id)
      end
      @seen_ids.add(id)
      @used_ids.add(id)
      @widget_rects[id] = rect
      @widget_senses[id] = sense
      @widget_layers[id] = layer
      @widget_clips[id] = clip

      # A modal blocks interaction with everything below its layer.
      if @modal_open && !layer.order.foreground?
        return InteractionVerdict.new(false, false, 0, false, false,
          false, false, Vec2.zero, false)
      end

      # Focus keep-alive (upstream: focusables register interest every
      # frame): the focused focusable re-requests focus so the
      # dead-man's switch only fires when the widget disappears.
      @focus.keep_alive(id) if sense.focusable? && @focus.id == id

      pos = @pointer_pos
      hovered = !sense.none? && pos ? rect.contains?(pos.not_nil!) &&
                                     clip.contains?(pos.not_nil!) : false

      clicked = sense.click? && @clicked_id == id
      click_count = clicked ? @clicked_count : 0
      pressed = sense.click? && @pointer_down && @potential_click_id == id &&
                !@moved_too_much_for_click
      dragged = sense.drag? && @dragging_id == id
      drag_started = dragged && @drag_started_id == id
      drag_stopped = sense.drag? && @drag_stopped_id == id
      drag_delta = dragged ? @pointer_delta : Vec2.zero
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
    end

    def close_all_popups : Nil
      @open_popups.clear
    end

    private def close_popups_if_clicked_elsewhere : Nil
      return if @open_popups.empty?
      clicked = @clicked_id
      return unless clicked
      layer = @widget_layers[clicked]? || @prev_widget_layers[clicked]?
      # A popup opened by this very click survives it (the open happens
      # during rendering, after the click was classified).
      candidates = @open_popups - @popups_opened_this_frame
      return if candidates.empty?
      close_all_popups unless layer && layer.order.foreground?
    end

    # --- internals ------------------------------------------------------

    # Keyboard focus navigation (upstream `Focus` + memory/mod.rs):
    # Tab / Shift+Tab cycles focusables in creation order; arrows move
    # geometrically to the nearest focusable in that direction, unless
    # the focused widget locked them (slider/drag value). Runs against
    # the previous frame's geometry, before any widget renders.
    private def navigate_focus(input : InputState) : Nil
      focusables = [] of Id
      @prev_widget_senses.each do |id, sense|
        focusables << id if sense.focusable? && @prev_widget_rects[id]?
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
      return unless focused && (from_rect = @prev_widget_rects[focused]?)

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
        delta = @prev_widget_rects[id].not_nil!.center - from
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
    # Layer Order wins first (see `layer.cr`: paint order and hit-test
    # priority follow Order — a Foreground popup always beats the panel
    # under it, even though the popup registers earlier in the frame);
    # within the same Order the last registration (paint order) is on
    # top. Hit-tests resolve against the previous frame's geometry.
    private def topmost_at(pos : Pos2?, &sense_filter : Sense -> Bool) : Id?
      return nil unless pos
      hit = nil
      hit_order = Order::Background.value
      @prev_widget_rects.each do |id, rect|
        if rect.contains?(pos)
          sense = @prev_widget_senses[id]?
          next if sense.nil? || !sense_filter.call(sense)
          clip = @prev_widget_clips[id]?
          next if clip && !clip.contains?(pos)
          order = (@prev_widget_layers[id]? || LayerId.background).order
          if @modal_open
            next unless order.foreground?
          end
          if hit.nil? || order.value >= hit_order
            hit = id
            hit_order = order.value
          end
        end
      end
      hit
    end

    private def rect_contains?(id : Id, pos : Pos2?) : Bool
      return false unless pos
      rect = @prev_widget_rects[id]? || @widget_rects[id]?
      return false unless rect && rect.contains?(pos)
      clip = @prev_widget_clips[id]? || @widget_clips[id]?
      !clip || clip.contains?(pos)
    end
  end
end
