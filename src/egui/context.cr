# Port of egui_upstream/crates/egui/src/context.rs.
#
# The Context owns the system state (Memory: data/areas/focus/
# animations/popups), the frame's input and painter, and drives the
# immediate-mode loop:
#
#   ctx.begin_frame(raw)   # derive InputState, rotate Memory geometry
#   app.update(ctx)        # widgets run top-to-bottom, push commands
#   ctx.end_frame          # → paint list for the backend (layer order)
#
# Containers: #window is the Area+Frame+Collapsed composite from
# upstream — movable via its title bar (drag through Areas state),
# stacked in the Middle layer; #popup rides the Foreground layer and
# closes on outside click; #bottom_panel pins to the screen bottom.

module Egui
  # A widget was created with an explicit id (`Button.new("OK", id:
  # "save")`) that another widget already claimed this frame — explicit
  # ids are the developer's addressing tool and must be unique.
  class DuplicateWidgetIdError < Exception
  end

  class Context
    getter memory : Memory
    getter input : InputState
    getter painter : Painter
    # The app-global hotkey → action bindings (see `hotkeys.cr`).
    # Actions fired this frame (key press or `#fire_action`) live for
    # exactly one frame and are claimed with `#consume_action`.
    getter hotkeys : HotkeyMap
    # The active global theme. Widgets read its #style every frame, so
    # assigning a new theme (`ctx.theme = Theme.light`) restyles the
    # entire UI on the very next frame — an instant swap.
    getter theme : Theme
    property fonts : Fonts
    property textures : TextureRegistry

    getter fps : Float64

    # The cursor the frame asked the integration to show (upstream
    # `PlatformOutput::cursor_icon`): reset to Default each
    # begin_frame, set by widgets via #set_cursor_icon / hover.
    getter cursor_icon : CursorIcon

    # egui `Context::available_rect`: screen area not yet claimed by
    # panels. Reset each begin_frame; every panel takes a bite; the
    # central panel takes what's left (panels must be added first —
    # the upstream ordering rule).
    getter available_rect : Rect

    @prev_time : Float64?
    @repaint_outstanding : Int32
    @frame_cache : Hash(String, IdTypeMap::Cell)
    @fired_actions : Array(HotkeyAction)
    @hotkey_capture : Bool
    # True between begin_frame and end_frame — reactive `Signal` writes
    # skip `request_repaint` inside a frame (the driving event already
    # bought the settle repaints).
    @in_frame : Bool
    # Explicit widget ids claimed this frame (duplicate → raise); see
    # `Widget#with_id` / `#claim_widget_id`.
    @claimed_ids : Set(Id)
    # Per-element style overrides set by the inspector (the top layer
    # of the style cascade — see `Widget#effective_style`). Runtime
    # debug state: never persisted, cleared from the inspector.
    @id_style_overrides : Hash(Id, StyleVars)
    # The widget currently being run through `Ui#add` — recorded by
    # `Inspector#record_meta` in #interact when the inspector is on.
    @current_widget : Widget?
    # The inspector (nil-ish until first enabled — lazily built).
    @inspector : Inspector?
    @inspector_enabled : Bool
    # Any popup opened this frame (app's own context menu etc.) — the
    # inspector yields to app menus when picking (see
    # `Inspector#after_update`).
    @popup_opened_this_frame : Bool

    def initialize
      @memory = Memory.new
      @input = InputState.new(Rect.zero, nil, false, false, false,
        Vec2.zero, 0.0, 0.016)
      @painter = Painter.new
      @theme = Theme.dark
      @cursor_icon = CursorIcon::Default
      @fonts = MonospaceFonts.new
      @textures = DummyTextureRegistry.new
      @prev_time = nil
      @fps = 0.0
      @repaint_outstanding = 0
      @frame_cache = {} of String => IdTypeMap::Cell
      @available_rect = Rect.zero
      @texture_cache = {} of String => UInt64
      @hotkeys = HotkeyMap.new
      @fired_actions = [] of HotkeyAction
      @hotkey_capture = false
      @in_frame = false
      @claimed_ids = Set(Id).new
      @id_style_overrides = {} of Id => StyleVars
      @current_widget = nil
      @inspector = nil
      @inspector_enabled = false
      @popup_opened_this_frame = false
    end

    def begin_frame(raw : RawInput) : Nil
      @in_frame = true
      @input = InputState.build(raw, @input, @prev_time)
      @prev_time = raw.time
      @available_rect = raw.screen_rect
      @cursor_icon = CursorIcon::Default

      # Any event this frame means the UI may react to it — make sure
      # the backend runs a full update/paint pass (on-demand mode).
      request_repaint unless raw.events.empty?

      # Smoothed FPS (EMA) — read by apps to show in a bottom panel.
      if @input.dt > 0.0
        instantaneous = 1.0 / @input.dt
        @fps = @fps < 1.0 ? instantaneous : @fps * 0.9 + instantaneous * 0.1
      end

      @repaint_outstanding -= 1 if @repaint_outstanding > 0
      @frame_cache.clear

      # Global hotkey dispatch: run before Memory's focus navigation
      # so a hotkey's key press is claimed (`consume_key`) and no
      # widget reacts to it as well. Skipped while a HotkeyEdit is
      # capturing (the flag is set during the previous update —
      # #hotkey_capture_active!), so the combo being recorded cannot
      # fire an action. The fresh list replaces the old one: an
      # unconsumed action expires after one frame.
      if @hotkey_capture
        @fired_actions = [] of HotkeyAction
        @hotkey_capture = false
      else
        @fired_actions = @hotkeys.dispatch(@input)
      end

      @memory.begin_frame(@input)
      @painter.clear
      @claimed_ids.clear
      @popup_opened_this_frame = false
      @inspector.try &.begin_frame
    end

    # Instant theme swap (see #theme) — takes effect next frame.
    def theme=(theme : Theme) : Theme
      @theme = theme
      request_repaint
      theme
    end

    # The active theme's style — what every un-overridden widget reads.
    def style : Style
      @theme.style
    end

    # The active theme's CSS-like class styles (see `StyleSheet`).
    def stylesheet : StyleSheet
      @theme.sheet
    end

    def end_frame : Array(PaintCmd)
      # The central panel is DEFERRED: it renders here, after update
      # has declared every other panel, so it always gets the true
      # remainder of #available_rect — a bottom panel declared after
      # it (status bar idiom) can no longer paint over its content.
      # Rendered before Memory#end_frame so its widget ids survive
      # pruning, and while @in_frame is still set (reactive setters
      # inside it keep their in-frame semantics).
      if (central = @central_block)
        @central_block = nil
        rect = @available_rect
        panel_ui(central[0], rect, Layout.top_down, central[2]) { |ui| central[1].call(ui) }
      end
      @in_frame = false
      @memory.end_frame
      @painter.commands_in_layer_order
    end

    # --- hotkey actions (see hotkeys.cr) -----------------------------------

    # Actions fired this frame (hotkey presses + `#fire_action`),
    # oldest first. Read-only view of the frame's action events.
    def fired_actions : Array(HotkeyAction)
      @fired_actions.dup
    end

    # Was `action` fired this frame (hotkey or menu click)? Does not
    # claim it — use `#consume_action` for exactly-once handling.
    def action_fired?(action : HotkeyAction) : Bool
      @fired_actions.includes?(action)
    end

    # egui `consume_key` semantics for actions: the first caller claims
    # the fired action; later callers this frame see false. Actions
    # live for one frame — an unconsumed firing expires.
    def consume_action(action : HotkeyAction) : Bool
      @fired_actions.includes?(action) && !!@fired_actions.delete(action)
    end

    # Fire `action` programmatically this frame (what a menu-item click
    # does): the app's `#consume_action` handler sees it, wherever the
    # app polls actions from.
    def fire_action(action : HotkeyAction) : Nil
      @fired_actions << action
      request_repaint
    end

    # A HotkeyEdit is capturing the next key press: pause global
    # hotkey dispatch for the next frame so the combo being recorded
    # cannot trigger an action. Called every frame while capturing.
    def hotkey_capture_active! : Nil
      @hotkey_capture = true
    end

    # egui `Context::set_cursor_icon`: a widget requests the cursor
    # while hovered/dragged; the backend reads #cursor_icon after
    # end_frame.
    def set_cursor_icon(icon : CursorIcon) : Nil
      @cursor_icon = icon
    end

    def interact(id : Id, rect : Rect, sense : Sense,
                 layer : LayerId = LayerId.background,
                 clip : Rect = Rect.infinite) : Response
      if (insp = @inspector) && @inspector_enabled
        insp.record_meta(id, @current_widget)
      end
      v = @memory.interact(id, rect, sense, layer, clip)
      response = Response.new(self, id, rect, sense, v.hovered?, v.clicked?,
        v.click_count, v.pressed?, v.active?, v.dragged?, v.drag_started?,
        v.drag_stopped?, v.drag_delta)
      # CSS `cursor: pointer` style (upstream `Visuals::interact_cursor`,
      # applied per-widget there — one hook here covers every clickable).
      if response.hovered? && sense.click? &&
         (icon = @theme.style.visuals.interact_cursor)
        @cursor_icon = icon
      end
      response
    end

    # --- animation / cache / repaint seams --------------------------------

    # egui `Context::animate_value_with_time`: smoothly move `value`
    # towards its new target; state keyed by widget id.
    def animate_value_with_time(id : Id, value : Float64,
                                duration : Float64 = 0.15) : Float64
      result = @memory.animations.animate(id, value, duration, @input.time)
      # Keep repainting while the easing still has ground to cover.
      request_repaint if @memory.animations.running?(id, @input.time)
      result
    end

    # egui CacheStorage-lite: memoize an expensive computation for the
    # current frame only (cleared in begin_frame).
    def frame_cache(key : String, &block : -> IdTypeMap::Cell) : IdTypeMap::Cell
      if (hit = @frame_cache[key]?)
        hit
      else
        value = block.call
        @frame_cache[key] = value
        value
      end
    end

    # egui `Context::load_texture`: decode an image file and cache it
    # per path; 0 means "couldn't load".
    def load_image(path : String) : UInt64
      @texture_cache[path] ||= @textures.load(path)
    end

    # egui repaint scheduling: an immediate request buys two repaints so
    # frame-delayed responses settle. The backend honors this — on an
    # idle frame (no events, no request, nothing animating) it skips
    # app.update/tessellation and re-emits the last paint commands.
    def request_repaint : Nil
      @repaint_outstanding = 2
    end

    def needs_repaint? : Bool
      @repaint_outstanding > 0
    end

    # True while the frame is being built (begin_frame…end_frame). The
    # reactive layer uses it to skip pointless repaint requests for
    # signal writes made during update.
    def in_frame? : Bool
      @in_frame
    end

    # --- inspector / explicit widget ids -----------------------------------

    # Claim `id` for a widget created with the explicit name `name`
    # (kind is the widget class, for the error message). Ids are
    # claimed once per frame; a second claim of the same id raises —
    # explicit ids are the developer's addressing tool and must be
    # unique. Auto ids skip this (their collisions stay on the silent
    # `Memory` duplicate accounting).
    def claim_widget_id(id : Id, name : String, kind : String) : Nil
      if @claimed_ids.includes?(id)
        raise DuplicateWidgetIdError.new(
          "Duplicate widget id \"#{name}\" (#{kind}) — explicit ids must be unique")
      end
      @claimed_ids.add(id)
    end

    # Runtime per-element style overrides (the inspector's Element
    # tab). The top layer of the cascade — see `Widget#effective_style`.
    def id_style_overrides : Hash(Id, StyleVars)
      @id_style_overrides
    end

    # Set one per-element style key (inspector Element tab). Applies on
    # the next frame — immediate mode needs no apply step.
    def set_id_style(id : Id, key : String, value : StyleValue) : Nil
      (@id_style_overrides[id] ||= StyleVars.new)[key] = value
      request_repaint
    end

    # Remove one key (nil = wipe every key) from a per-element
    # override; the slot goes back to inheriting the cascade. An empty
    # bag is dropped entirely.
    def clear_id_style(id : Id, key : String? = nil) : Nil
      if key
        bag = @id_style_overrides[id]?
        if bag
          bag.delete(key)
          @id_style_overrides.delete(id) if bag.empty?
        end
      else
        @id_style_overrides.delete(id)
      end
      request_repaint
    end

    # The inspector state (built on first enable — zero cost while
    # off). The backend drives its frame hooks; see `inspector.cr`.
    def inspector : Inspector
      @inspector ||= Inspector.new(self)
    end

    def inspector? : Inspector?
      @inspector
    end

    def inspector_enabled? : Bool
      @inspector_enabled
    end

    # Enable/disable the inspector at runtime (`Sokol.run(…,
    # inspector: :on)` flips this on before the first frame).
    def inspector_enabled=(flag : Bool) : Bool
      inspector # build the state object
      @inspector_enabled = flag
      request_repaint
      flag
    end

    # The widget currently running through `Ui#add` (set there, read
    # by #interact for inspector meta recording). Internal.
    def current_widget : Widget?
      @current_widget
    end

    def current_widget=(widget : Widget?) : Widget?
      @current_widget = widget
    end

    # Did the app open a popup this frame (its own context menu)? The
    # inspector pick menu yields to app menus. Internal.
    def popup_opened_this_frame? : Bool
      @popup_opened_this_frame
    end

    # --- containers --------------------------------------------------------

    # A titled, movable, resizable window. egui order preserved:
    # reserve the background slot, interact with the title bar (drag →
    # Areas state moves the window; click/hover → bring to top), build
    # contents, back-fill the frame, title.
    WINDOW_MIN_SIZE = Vec2.new(120.0, 80.0)

    # Upstream `Area` defaults to `constrain: true`: floating regions
    # never exceed the screen and are shifted back inside it
    # (`Context::constrain_window_rect_to_area`, area.rs). The width is
    # capped at the screen width, floored at `min_width` (the parent
    # widget for anchored popups — the floor wins, so a popup at the
    # right edge shifts left instead of shrinking below its parent),
    # then the position is clamped so the rect stays inside. Frames
    # without a screen (headless specs with a zero `screen_rect`) skip
    # the constraint.
    private def constrain_floating(pos : Pos2, size : Vec2,
                                   min_width : Float64? = nil,
                                   constrain_y : Bool = false) : {Pos2, Vec2}
      screen = @input.screen_rect
      return {pos, size} if screen.width <= 0.0
      w = {size.x, screen.width}.min
      w = {w, min_width.not_nil!}.max if min_width
      x = pos.x.clamp(screen.left, {screen.right - w, screen.left}.max)
      y = constrain_y ?
        pos.y.clamp(screen.top, {screen.bottom - size.y, screen.top}.max) : pos.y
      {Pos2.new(x, y), Vec2.new(w, size.y)}
    end

    def window(title : String, default_pos : Pos2 = Pos2.new(24.0, 24.0),
               width : Float64 = 380.0, &block : Ui ->) : Nil
      win_id = Id.from("window/#{title}")
      layer = LayerId.new(Order::Middle, win_id)
      pad = style.spacing.window_padding
      title_size = style.font_size * 1.25
      title_h = title_size + pad.y

      pos = @memory.areas.pos_for(win_id, default_pos)
      size = @memory.layer_sizes[win_id]? || Vec2.new(width, 160.0)
      # Upstream `Window` + `Resize`: while never resized the window
      # auto-fits its contents (unbounded height); once the user drags
      # the grip the size is fixed and overflowing content is clipped
      # to the window rect.
      fixed = @memory.fixed_size_layers.includes?(win_id)

      # Title bar: drag moves the window, interaction brings it to top.
      title_rect = Rect.from_min_size(pos, Vec2.new(size.x, title_h))
      title_id = win_id.child(0_u64)
      title_resp = interact(title_id, title_rect, Sense.click_and_drag, layer)
      if title_resp.dragged?
        @memory.areas.move_by(win_id, title_resp.drag_delta)
        pos = @memory.areas.pos_for(win_id, default_pos)
      end
      if title_resp.hovered? || title_resp.pressed? || title_resp.dragged?
        @memory.areas.bring_to_top(layer)
      end

      # Constrain to the screen: the width never exceeds it, the
      # position shifts so the rect stays inside — a window can't be
      # dragged or sized off-screen.
      pos, size = constrain_floating(pos, size, WINDOW_MIN_SIZE.x, fixed)
      @memory.areas.set_pos(win_id, pos)
      clip = fixed ? Rect.from_min_size(pos, size) :
                     Rect.from_min_size(pos, Vec2.new(size.x, 1e6))
      content_size = Vec2.new(size.x - 2 * pad.x,
        fixed ? {size.y - title_h - 2 * pad.y, 1.0}.max : 1e6)

      @painter.layer = Order::Middle
      bg_index = @painter.add_noop
      @painter.clip = clip
      content_min = pos + Vec2.new(pad.x, title_h + pad.y)
      ui = Ui.new(self, win_id,
        Rect.from_min_size(content_min, content_size))
      ui.layer = layer
      # Interaction stays inside the window's horizontal extent while
      # auto-fitting (the height grows with the content, hence the 1e6
      # tall strip); a fixed-size window clips to its rect on both axes.
      ui.clip = clip
      yield ui

      outer = fixed ? Rect.from_min_size(pos, size) : Rect.new(
        pos,
        Pos2.new({ui.min_rect.right + pad.x, pos.x + size.x}.max,
          ui.min_rect.bottom + pad.y))

      # Resize grip: drag the bottom-right corner (upstream `Resize`
      # wired into `Window`); size persists in Memory#layer_sizes, and
      # from the first drag on the window keeps a fixed, clipped size.
      grip_size = 12.0
      grip = Rect.from_min_size(
        Pos2.new(outer.max.x - grip_size, outer.max.y - grip_size),
        Vec2.new(grip_size, grip_size))
      grip_id = Id.from("window/#{title}/resize_grip")
      grip_resp = interact(grip_id, grip, Sense.drag, layer)
      grip_resp.on_hover_and_drag_cursor(CursorIcon::NwseResize)
      if grip_resp.dragged?
        @memory.fixed_size_layers.add(win_id)
        size = size + grip_resp.drag_delta
        size = Vec2.new({size.x, WINDOW_MIN_SIZE.x}.max,
          {size.y, WINDOW_MIN_SIZE.y}.max)
        # Never past the screen edges (upstream `Resize` max_size).
        screen = @input.screen_rect
        if screen.width > 0.0
          size = size.min(Vec2.new(screen.right - pos.x, screen.bottom - pos.y))
        end
        outer = Rect.new(outer.min, outer.min + size)
      end
      @memory.layer_sizes[win_id] = outer.size

      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, style.visuals.window_rounding,
          style.visuals.window_fill,
          style.visuals.window_stroke, 1.0))
      # Title bar: by default the window fill itself (a flat bar); a
      # themed fill (classic navy Win95 bar) paints over it, still
      # under the title text.
      @painter.rect(Rect.from_min_size(pos, Vec2.new(outer.width, title_h)),
        rounding: style.visuals.window_rounding,
        fill: style.visuals.title_bar_fill)
      @painter.text(Pos2.new(pos.x + pad.x, pos.y + title_h / 2.0),
        title, title_size, style.visuals.title_color)
      # Grip: two small diagonal marks.
      (1..2).each do |i|
        o = grip_size - 4.0 * i
        @painter.line(
          Pos2.new(grip.max.x - o, grip.max.y - 4.0),
          Pos2.new(grip.max.x - 4.0, grip.max.y - o),
          2.0, style.visuals.separator_color)
      end
      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    # egui `Area` (containers/area.rs) — an explicit positioned region
    # in its own Middle layer: the building block window/popup are made
    # of, exposed for custom floating content. Position persists in
    # Areas (bring-to-top on interaction, like a window without chrome).
    def area(id : String, default_pos : Pos2 = Pos2.zero,
             width : Float64 = 300.0, &block : Ui ->) : Nil
      area_id = Id.from("area/#{id}")
      layer = LayerId.new(Order::Middle, area_id)
      pos = @memory.areas.pos_for(area_id, default_pos)
      # Constrain to the screen like a window (upstream `Area`
      # constrain: true).
      pos, constrained = constrain_floating(pos, Vec2.new(width, 0.0))
      width = constrained.x
      @memory.areas.set_pos(area_id, pos)

      probe = Rect.from_min_size(pos, Vec2.new(width, 1.0))
      probe_resp = interact(area_id.child(0_u64), probe, Sense.click, layer)
      @memory.areas.bring_to_top(layer) if probe_resp.hovered? || probe_resp.pressed?

      @painter.layer = Order::Middle
      @painter.clip = Rect.from_min_size(pos, Vec2.new(width, 1e6))
      ui = Ui.new(self, area_id,
        Rect.from_min_size(pos, Vec2.new(width, 1e6)))
      ui.layer = layer
      yield ui

      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    # egui popup (containers/popup.rs): rides the Foreground layer,
    # closes when a click lands outside it (Memory#end_frame). `pad`
    # overrides the frame's inner padding (menus pass a zero vertical
    # pad so the frame hugs the first/last item).
    # Dropdown anchor (upstream `popup::above_or_below`): the popup
    # opens below `button`, but flips above it when the button sits too
    # close to the screen's bottom for the popup's last measured height
    # (`Memory#layer_sizes`). The very first frame always opens below —
    # `#popup` measures the content, and from the next frame on the
    # side is re-picked every frame, so a button that moves (scroll,
    # window drag) flips back and forth as space allows.
    def dropdown_anchor(id : String, button : Rect) : Pos2
      height = @memory.layer_sizes[Id.from("popup/#{id}")]?.try(&.y) || 0.0
      screen = @input.screen_rect
      return Pos2.new(button.left, button.bottom) if height <= 0.0 ||
                                                     screen.width <= 0.0
      space_below = screen.bottom - button.bottom
      space_above = button.top - screen.top
      if height > space_below && height <= space_above
        Pos2.new(button.left, button.top - height)
      else
        Pos2.new(button.left, button.bottom)
      end
    end

    def popup(id : String, anchor : Pos2, width : Float64 = 220.0,
              pad : Vec2? = nil, min_width : Float64? = nil,
              &block : Ui ->) : Nil
      pop_id = Id.from("popup/#{id}")
      return unless @memory.open_popups.includes?(pop_id)

      # Snap to last frame's measured size (like #modal): menus size
      # themselves from their items' natural widths (via Ui#min_rect),
      # so frame one opens at `width`, later frames hug the content.
      width = @memory.layer_sizes[pop_id]?.try(&.x) || width

      # Keep inside the screen (upstream `Area` constrain): floor at the
      # parent widget's width (`min_width`, e.g. the ComboBox button) so
      # the popup is never narrower than what opened it, then shift the
      # anchor left — a popup at the right edge opens fully visible.
      anchor, constrained = constrain_floating(anchor, Vec2.new(width, 0.0),
        min_width)
      width = constrained.x

      layer = LayerId.new(Order::Foreground, pop_id)
      pad ||= style.spacing.window_padding

      @painter.layer = Order::Foreground
      bg_index = @painter.add_noop
      @painter.clip = Rect.from_min_size(anchor, Vec2.new(width, 1e6))
      ui = Ui.new(self, pop_id,
        Rect.from_min_size(anchor + Vec2.new(pad.x, pad.y),
          Vec2.new(width - 2 * pad.x, 1e6)))
      ui.layer = layer
      yield ui

      outer = Rect.new(
        anchor,
        Pos2.new(ui.min_rect.right + pad.x, ui.min_rect.bottom + pad.y))
      @memory.layer_sizes[pop_id] = outer.size
      @memory.popup_rects[pop_id] = outer
      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 4.0, style.visuals.window_fill,
          style.visuals.window_stroke, 1.0))
      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    def popup_open?(id : String) : Bool
      @memory.open_popups.includes?(Id.from("popup/#{id}"))
    end

    def open_popup(id : String) : Nil
      @popup_opened_this_frame = true
      @memory.open_popup(Id.from("popup/#{id}"))
      request_repaint
    end

    def close_popup(id : String) : Nil
      @memory.close_popup(Id.from("popup/#{id}"))
      request_repaint
    end

    # egui modal (containers/modal.rs): dims the screen and blocks all
    # interaction below the Foreground layer (Memory#mark_modal).
    #
    # Windows 11 CONTENT-dialog look (no caption bar, no close button —
    # like the Settings/Explorer dialogs), TWO zones: the h1 title and
    # the caller's content as ONE block on the plain window fill, and a
    # raised footer band at most a quarter of the dialog tall carrying
    # the buttons as an equal-width stretched row. Returns the label of
    # the footer button clicked this frame (nil otherwise); `title:`
    # nil skips the h1, an empty `buttons` array skips the footer.
    def modal(id : String = "modal", width : Float64 = 480.0,
              title : String? = nil, buttons : Array(String) = [] of String,
              &block : Ui ->) : String?
      @memory.mark_modal
      modal_id = Id.from("modal/#{id}")
      layer = LayerId.new(Order::Foreground, modal_id)
      screen = @input.screen_rect
      v = style.visuals
      pad = style.spacing.window_padding
      h1_pt = 24.0    # h1 title size
      h1_line = 32.0  # h1 line box
      min_h = 220.0
      btn_h = 40.0    # footer button height
      btn_pad = 12.0  # footer vertical padding
      footer_h = buttons.empty? ? 0.0 : btn_h + 2 * btn_pad

      # The footer band fill: window_fill raised toward the text color
      # — the second zone's background, the visual split of the dialog.
      wf, t = v.window_fill, v.text_color
      f = 0.06
      footer_fill = Color32.rgba(
        (wf.r.to_i + (t.r.to_i - wf.r.to_i) * f).round.to_i,
        (wf.g.to_i + (t.g.to_i - wf.g.to_i) * f).round.to_i,
        (wf.b.to_i + (t.b.to_i - wf.b.to_i) * f).round.to_i, wf.a)

      # Never wider than the screen (upstream `Area` constrain).
      width = {width, screen.width}.min if screen.width > 0.0

      # Dim everything below (theme-driven scrim — `Visuals#modal_dim`).
      @painter.layer = Order::Foreground
      @painter.clip = screen
      @painter.rect(screen, 0.0, v.modal_dim)

      # Center using last frame's size.
      prev_size = @memory.layer_sizes[modal_id]? ||
        Vec2.new(width, {min_h, footer_h * 4.0}.max)
      pos = Pos2.new(screen.center.x - prev_size.x / 2.0,
        screen.center.y - prev_size.y / 2.0)

      # The dialog shell is back-painted at the end (bg_index below);
      # the stroke is window_stroke at low alpha — a full-strength
      # outline reads too harsh against the dialog fill.
      bg_index = @painter.add_noop
      @painter.clip = Rect.from_min_size(pos, Vec2.new(width, 1e6))

      # --- zone 1: h1 + the caller's content, one block ----------------
      @painter.text(Pos2.new(pos.x + pad.x, pos.y + pad.y + h1_line / 2.0),
        title, h1_pt, v.title_color) if title
      content_min = pos + Vec2.new(pad.x,
        pad.y + (title ? h1_line + 12.0 : 0.0))
      ui = Ui.new(self, modal_id,
        Rect.from_min_size(content_min, Vec2.new(width - 2 * pad.x, 1e6)))
      ui.layer = layer
      @painter.clip = Rect.from_min_size(pos, Vec2.new(width, 1e6))
      yield ui

      # --- zone 2: the raised footer band with the buttons ------------
      clicked = nil
      outer_h = {ui.min_rect.bottom + pad.y - pos.y + footer_h,
        min_h, footer_h * 4.0}.max # footer never exceeds 25% of the dialog
      outer = Rect.new(pos,
        Pos2.new({ui.min_rect.right + pad.x, pos.x + width}.max,
          pos.y + outer_h))
      if footer_h > 0.0
        footer_top = outer.bottom - footer_h
        # bottom corners rounded like the shell, top edge squared: the
        # rounded band is drawn 8pt past the seam, a square patch then
        # fills its top rounding back to a straight edge
        @painter.clip = outer
        @painter.rect(Rect.from_min_size(
          Pos2.new(pos.x, footer_top - 8.0),
          Vec2.new(width, footer_h + 8.0)), 8.0, footer_fill, nil, 0.0)
        @painter.rect(Rect.from_min_size(
          Pos2.new(pos.x, footer_top - 1.0), Vec2.new(width, 2.0)),
          0.0, footer_fill, nil, 0.0)

        # buttons as an equal-width stretched row (block, not inline)
        n = buttons.size
        gap = style.spacing.item_spacing.x
        bw = (width - 2 * pad.x - (n - 1) * gap) / n
        row = Ui.new(self, Id.from("modal/#{id}/footer"),
          Rect.from_min_size(
            Pos2.new(pos.x + pad.x, footer_top + btn_pad),
            Vec2.new(width - 2 * pad.x, btn_h)),
          layout: Layout.left_to_right)
        row.layer = layer
        buttons.each do |label|
          resp = row.add(Button.new(label)
            .min_size(Vec2.new(bw, btn_h)))
          clicked = label if resp.clicked?
        end
      end

      @memory.layer_sizes[modal_id] = outer.size
      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 8.0, v.window_fill,
          Color32.rgba(v.window_stroke.r, v.window_stroke.g,
            v.window_stroke.b, 90),
          1.0))
      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
      clicked
    end

    # --- panels (egui containers/panel.rs) --------------------------------
    #
    # egui `TopBottomPanel`/`SidePanel`/`CentralPanel`: each panel takes
    # a bite out of #available_rect in the order it is added; the
    # central panel takes what's left. Upstream requires CentralPanel
    # to be added LAST (a later panel would eat into its rect); here
    # the central panel is DEFERRED to the end of the frame instead,
    # so it always renders into the true remainder regardless of
    # declaration order — panels can never overlap it.

    # The deferred central panel: {id, block, fill}, rendered in
    # #end_frame.
    @central_block : {String, Proc(Ui, Nil), Color32?} | Nil = nil

    # *height* pins the strip height (nil → one text line + window
    # padding); the client-side window frame uses it for its caption.
    def top_panel(id : String = "top_panel", height : Float64? = nil,
                  &block : Ui ->) : Rect
      h = height || begin
        line_h = style.font_size * Fonts::LINE_H_FACTOR
        pad = style.spacing.window_padding
        line_h + 2 * pad.y
      end
      rect = Rect.from_min_size(@available_rect.min,
        Vec2.new(@available_rect.width, h))
      @available_rect = Rect.new(
        Pos2.new(rect.left, rect.bottom),
        @available_rect.max)
      panel_ui(id, rect, Layout.left_to_right) { |ui| yield ui }
      rect
    end

    def bottom_panel(id : String = "bottom_panel",
                     height : Float64? = nil, &block : Ui ->) : Rect
      height ||= begin
        line_h = style.font_size * Fonts::LINE_H_FACTOR
        pad = style.spacing.window_padding
        line_h + 2 * pad.y
      end
      rect = Rect.from_min_size(
        Pos2.new(@available_rect.min.x, @available_rect.max.y - height),
        Vec2.new(@available_rect.width, height))
      @available_rect = Rect.new(@available_rect.min,
        Pos2.new(rect.right, rect.top))
      panel_ui(id, rect, Layout.left_to_right) { |ui| yield ui }
      rect
    end

    def side_panel(side : Symbol, id : String = "side_panel",
                   width : Float64 = 200.0, &block : Ui ->) : Rect
      w = {width, @available_rect.width}.min
      rect = if side == :right
        Rect.from_min_size(
          Pos2.new(@available_rect.max.x - w, @available_rect.min.y),
          Vec2.new(w, @available_rect.height))
      else
        Rect.from_min_size(@available_rect.min,
          Vec2.new(w, @available_rect.height))
      end
      @available_rect = if side == :right
        Rect.new(@available_rect.min,
          Pos2.new(rect.left, @available_rect.max.y))
      else
        Rect.new(Pos2.new(rect.right, @available_rect.min.y),
          @available_rect.max)
      end
      panel_ui(id, rect, Layout.top_down) { |ui| yield ui }
      rect
    end

    # egui `CentralPanel::show` — the remainder. Returns its rect.
    #
    # *fill* overrides the panel background (nil → the style's
    # panel_fill) — `Color32.transparent` makes the central panel paint
    # nothing, so a widget that draws its own (possibly translucent)
    # background shows the desktop through a transparent window.
    #
    # DEFERRED (egui.cr fix, no upstream counterpart): the block does
    # not run here — #end_frame renders it after every other panel
    # has bitten #available_rect, so the central panel ends up with
    # the true remainder whatever order the app declared panels in
    # (a bottom status bar after the central panel used to paint OVER
    # its content). The return value is the remainder at CALL time —
    # exact when the central panel is declared last (the recommended
    # style), approximate if later panels still bite.
    def central_panel(id : String = "central_panel",
                      fill : Color32? = nil, &block : Ui ->) : Rect
      rect = @available_rect
      @central_block = {id, block, fill}
      rect
    end

    private def panel_ui(id : String, rect : Rect, layout : Layout,
                         fill : Color32? = nil, &block : Ui ->) : Nil
      pad = style.spacing.window_padding

      @painter.layer = Order::Background
      bg_index = @painter.add_noop
      @painter.clip = rect
      @painter.set(bg_index,
        RectCmd.new(rect, rect, 0.0, fill || style.visuals.panel_fill,
          style.visuals.window_stroke, 1.0))

      ui = Ui.new(self, Id.from("panel/#{id}"),
        rect.shrink(pad.x), layout)
      ui.clip = rect
      yield ui

      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end
  end
end
