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

    # The monospace font stack (terminal grids, code) — nil means "same
    # as #fonts". The backend installs a second stack via
    # `Sokol.select_fonts(font, mono:)`; widgets that need mono METRICS
    # read #mono_font, never this nullable property.
    property mono_fonts : Fonts? = nil

    # REAL variant faces of the primary stack — what bold/italic text
    # measures and draws through (`Sokol.select_fonts(bold:/italic:/`
    # `bold_italic:)`). Nil = the variant isn't installed: the text
    # serves through the base #fonts' own glyphs, never an emulated one.
    property bold_fonts : Fonts? = nil
    property italic_fonts : Fonts? = nil
    property bold_italic_fonts : Fonts? = nil

    # The font stack mono text measures/draws through: #mono_fonts when
    # the backend installed one, #fonts otherwise.
    def mono_font : Fonts
      @mono_fonts || @fonts
    end

    # Named font families (upstream `FontDefinitions::families`): a
    # family name → font stack registry, so a GROUP of widgets can swap
    # fonts through the style cascade (`font_family` key). The backend
    # registers stacks via `Sokol.register_font`; two names are
    # reserved for the built-in slots — "system" → the primary #fonts
    # (whatever the backend loaded: the system face, a preselected
    # stack…), "monospace" → #mono_font.
    property font_families : Hash(String, Fonts) = {} of String => Fonts

    def register_font_family(name : String, fonts : Fonts) : Nil
      @font_families[name] = fonts
      @mono_fonts = fonts if name == "monospace"
      @fonts = fonts if name == "system"
    end

    # Font families whose stack is NOT loaded yet: family name → font
    # file paths (the system scan's output). Materialized into
    # #font_families by #fonts_for on FIRST USE through #font_loader —
    # startup pays for names only; the parse happens for the families
    # actually picked. The reserved names are not deferrable (they are
    # the built-in slots).
    property deferred_font_paths : Hash(String, Array(String)) = {} of String => Array(String)

    # The stack builder for #deferred_font_paths — the backend's
    # from_system chain, installed at on_init. Nil headless: a
    # deferred family degrades to the primary stack there.
    property font_loader : Proc(Array(String), Fonts?)?

    def register_deferred_font(name : String, paths : Array(String)) : Nil
      return if name == "system" || name == "monospace"
      @deferred_font_paths[name] = paths
    end

    # The stack a `family`-tagged text measures/draws through: nil or
    # an unknown name → the primary #fonts (a typo degrades to the
    # default, CSS vibes), "system" → the primary, "monospace" →
    # #mono_font. A deferred family materializes HERE — the first
    # resolution parses the files, swaps the placeholder out of
    # #deferred_font_paths and never pays again.
    #
    # `bold`/`italic` shift the PRIMARY resolution to a real variant
    # face when one is installed (#bold_fonts & co — the measure-side
    # twin of the backend's #fonts_for_cmd); a missing variant degrades
    # to the nearest real face (bold+italic → bold → base), headless
    # Contexts included: #fonts serves everything there.
    def fonts_for(family : String?, bold : Bool = false,
                  italic : Bool = false) : Fonts
      base = fonts_for_family(family)
      return base unless base.same?(@fonts)
      if bold && italic
        @bold_italic_fonts || @bold_fonts || @italic_fonts || base
      elsif bold
        @bold_fonts || base
      elsif italic
        @italic_fonts || base
      else
        base
      end
    end

    private def fonts_for_family(family : String?) : Fonts
      return @fonts unless family
      case family
      when "monospace" then mono_font
      when "system"    then @fonts
      else
        if (fonts = @font_families[family]?)
          fonts
        elsif (paths = @deferred_font_paths[family]?)
          real = @font_loader.try &.call(paths)
          @deferred_font_paths.delete(family)
          if real
            @font_families[family] = real
          else
            @fonts # an unloadable family degrades to the primary
          end
        else
          @fonts
        end
      end
    end

    # The catalog of family names a `font_family` style key can be set
    # to: every registered named stack, every deferred (not yet
    # materialized) family, plus the reserved "system" (the primary —
    # always resolvable, whatever the backend loaded) and "monospace"
    # (resolvable even when no mono stack is installed — it degrades
    # to the primary). Sorted; what a font picker offers. "unset the
    # key" is how a picker returns to the theme slot
    # (`Style#font_family`, nil by default → the primary).
    def font_family_catalog : Array(String)
      (@font_families.keys + @deferred_font_paths.keys +
        ["system", "monospace"]).uniq.sort
    end
    property textures : TextureRegistry
    # Framebuffer pixels per UI point (retina: 2.0), set by the
    # backend each frame — 1.0 headless. Raster caches (Svg textures,
    # like the font atlas) bake at this scale so a 2x display gets
    # 2x-texel rasters, not upscaled blur.
    property pixels_per_point : Float64 = 1.0

    getter fps : Float64

    # The cursor the frame asked the integration to show (upstream
    # `PlatformOutput::cursor_icon`): reset to Default each
    # begin_frame, set by widgets via #set_cursor_icon / hover.
    getter cursor_icon : CursorIcon

    # Upstream `PlatformOutput::cursor_image`: when set, the
    # integration should display this RGBA bitmap as the OS cursor
    # instead of #cursor_icon (backends without support fall back to
    # the icon). Reset each begin_frame, set via #set_cursor_image.
    getter cursor_image : CustomCursorImage?

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
    @id_style_overrides : Hash(Id, Hash(String?, StyleVars))
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
    # The debug-only `.ecss` style-diff session (see `egui/ecss.cr`),
    # started by `Sokol.run` when the app opted in via the
    # `enable_ecss` macro — nil (zero cost) in release builds.
    @ecss : Ecss::Session?
    property ecss : Ecss::Session?

    def initialize
      @memory = Memory.new
      @input = InputState.new(Rect.zero, nil, false, false, false,
        Vec2.zero, 0.0, 0.016)
      @painter = Painter.new
      @theme = Theme.dark
      @cursor_icon = CursorIcon::Default
      @cursor_image = nil
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
      @id_style_overrides = {} of Id => Hash(String?, StyleVars)
      @current_widget = nil
      @inspector = nil
      @inspector_enabled = false
      @popup_opened_this_frame = false
      @ecss = nil
    end

    def begin_frame(raw : RawInput) : Nil
      @in_frame = true
      @input = InputState.build(raw, @input, @prev_time)
      @prev_time = raw.time
      @available_rect = raw.screen_rect
      @cursor_icon = CursorIcon::Default
      @cursor_image = nil

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
      # Hot reload: an externally edited .ecss file re-applies here,
      # before this frame's widgets resolve their styles.
      @ecss.try &.poll
    end

    # Instant theme swap (see #theme) — takes effect next frame.
    # Idempotent: assigning the theme already in place (compared by
    # name) is a no-op and does not request a repaint, so an app may
    # re-assign unconditionally every frame.
    def theme=(theme : Theme) : Theme
      unless theme.name == @theme.name
        @theme = theme
        # A new theme brings a fresh StyleSheet — the .ecss class-rule
        # diff must ride over to it (see Ecss::Session#reapply).
        @ecss.try &.reapply
        request_repaint
      end
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
      flush_central_panel_spanned
      # Inspector overlays (pick menu, color popup, selection frame)
      # run AFTER all app content — the deferred central panel included
      # — so a widget's context menu opened there has already claimed
      # the press and the inspector yields to it (its «Inspect …» row
      # is that menu's last item, not a second popup).
      @inspector.try &.after_update if @inspector_enabled
      @in_frame = false
      Egui::Bench.span("Memory#end_frame") { @memory.end_frame }
      Egui::Bench.span("Painter#commands_in_layer_order") do
        @painter.commands_in_layer_order
      end
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

    # egui `Context::set_cursor_image`: display this RGBA bitmap as the
    # OS cursor for the frame, instead of the standard #cursor_icon —
    # the CSS `cursor: url(…)` equivalent. Backends without
    # bitmap-cursor support silently fall back to the icon. Pass nil to
    # clear. Reset each begin_frame.
    def set_cursor_image(image : CustomCursorImage?) : Nil
      @cursor_image = image
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
      # Between frames (a PTY reader fiber, an async dialog completing)
      # the request must also WAKE the backend loop — see
      # Egui::Runtime.wake. Inside a frame the driving loop re-checks
      # needs_repaint? on its own, so the doorbell is skipped.
      unless @in_frame
        Egui::Runtime.wake.try &.call
      end
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
    def id_style_overrides : Hash(Id, Hash(String?, StyleVars))
      @id_style_overrides
    end

    # Set one per-element style key (inspector Element tab), optionally
    # scoped to an interaction state ("hover"/"active"; nil = base —
    # applies to every state unless the same layer defines a state
    # value, CSS inline-style semantics). Applies on the next frame —
    # immediate mode needs no apply step.
    def set_id_style(id : Id, key : String, value : StyleValue,
                     state : String? = nil) : Nil
      states = (@id_style_overrides[id] ||= {} of String? => StyleVars)
      (states[state] ||= StyleVars.new)[key] = value
      request_repaint
    end

    # Remove one key (nil = wipe every key of every state) from a
    # per-element override; the slot goes back to inheriting the
    # cascade. Empty bags are dropped entirely.
    def clear_id_style(id : Id, key : String? = nil,
                       state : String? = nil) : Nil
      states = @id_style_overrides[id]?
      if states && key
        if (bag = states[state]?)
          bag.delete(key)
          states.delete(state) if bag.empty?
        end
        @id_style_overrides.delete(id) if states.empty?
      else
        @id_style_overrides.delete(id)
      end
      request_repaint
    end

    # The per-element override bag for `state`: base keys with the
    # state overlay merged on top (a fresh copy — safe to mutate).
    # Nil when the id has no overrides at all.
    def id_style_state_vars(id : Id, state : String?) : StyleVars?
      return nil unless states = @id_style_overrides[id]?
      merged = StyleVars.new
      merged.merge!(states[nil]) if states[nil]?
      merged.merge!(states[state]) if state && states[state]?
      merged.empty? ? nil : merged
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

    # Run the block with `widget` as the `current_widget` — the manual
    # twin of what `Ui#add` does around `widget.ui`. Paint-in-place
    # sites (menu rows, title-bar tab cards) wrap their direct
    # `#interact` calls in this so the inspector records meta for them;
    # with the inspector off it is a plain `yield` (zero cost).
    def with_inspector_widget(widget : Widget, & : -> _)
      if @inspector_enabled
        parent = @current_widget
        @current_widget = widget
        begin
          yield
        ensure
          @current_widget = parent
        end
      else
        yield
      end
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

      # Content may leave the painter in another layer (a popup opened
      # inside resets it to Background on exit) — re-establish this
      # window's layer before the back-painted shell and title bar.
      @painter.layer = Order::Middle

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
    # `on_scrim_click:` fires on a click on the dimmed area OUTSIDE the
    # card (modal pages use it as their "back" — the scrim IS the back
    # button; the card's own widgets are hit-tested above it).
    def modal(id : String = "modal", width : Float64 = 480.0,
              title : String? = nil, buttons : Array(String) = [] of String,
              on_scrim_click : (-> Nil)? = nil,
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

      # The scrim as a click target ("click outside to dismiss") —
      # declared BEFORE the card content, so the card's widgets are
      # hit-tested above it in the same Foreground layer.
      if on_scrim_click
        scrim = interact(Id.from("modal/#{id}/scrim"), screen,
          Sense::Click, layer, screen)
        if scrim.clicked?
          on_scrim_click.call
          request_repaint
        end
      end

      # Center using last frame's size.
      prev_size = @memory.layer_sizes[modal_id]? ||
        Vec2.new(width, {min_h, footer_h * 4.0}.max)
      pos = Pos2.new(screen.center.x - prev_size.x / 2.0,
        screen.center.y - prev_size.y / 2.0)

      # The card itself as a click claim, ABOVE the scrim (registered
      # later in the same layer): a click on blank card space dies on
      # the card instead of popping through to the scrim's "back".
      if on_scrim_click
        card_rect = Rect.from_min_size(pos, prev_size)
        interact(Id.from("modal/#{id}/card"), card_rect,
          Sense::Click, layer, card_rect)
      end

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

      # Content may leave the painter in another layer (a popup opened
      # inside resets it to Background on exit) — the footer band and
      # buttons below must stay in the modal's Foreground layer.
      @painter.layer = Order::Foreground

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

    # An embedded window — a MODAL window with chrome: what #modal is for
    # content dialogs, this is for an app's dialog WINDOWS (Settings,
    # Theme…): it dims the screen and blocks interaction below the
    # Foreground layer (Memory#mark_modal) while floating as a titled,
    # DRAGGABLE window with a ✕ — the caller keeps the open flag and
    # drops it when this returns true.
    #
    # Centered on the measured size every frame until the user drags the
    # window (the very first frame of a session uses a height estimate,
    # so the card settles once when its content is first measured),
    # auto-fits its content like #window without a resize grip (dialogs
    # are content-sized), stays on screen (#constrain_floating — the top
    # never goes above the screen, so a dialog taller than the screen
    # pins at the top). `title:` nil drops the title bar down to a slim
    # drag handle.
    #
    # Returns true the frame the user asked to close it: the ✕, the
    # scrim (when `close_on_scrim:`, the dimmed area IS the dismiss
    # target) or Escape (`close_on_escape:`).
    def embedded_window(id : String, title : String? = nil,
                        width : Float64 = 460.0,
                        close_on_escape : Bool = true,
                        close_on_scrim : Bool = true,
                        &block : Ui ->) : Bool
      @memory.mark_modal
      win_id = Id.from("embedded/#{id}")
      layer = LayerId.new(Order::Foreground, win_id)
      screen = @input.screen_rect
      v = style.visuals
      pad = style.spacing.window_padding
      title_size = style.font_size * 1.25
      title_h = title ? title_size + pad.y : 8.0

      # Never wider than the screen (upstream `Area` constrain).
      width = {width, screen.width}.min if screen.width > 0.0

      # Keyboard dismiss first, so a focused child widget's own Escape
      # handling still wins by consuming the key earlier in the frame.
      close = close_on_escape && @input.consume_key(KeyCode::Escape)

      # Dim everything below (same scrim as #modal).
      @painter.layer = Order::Foreground
      @painter.clip = screen
      @painter.rect(screen, 0.0, v.modal_dim)

      # The scrim as a click target ("click outside to dismiss"),
      # declared BEFORE the card so the card's widgets hit-test above
      # it in the same Foreground layer.
      if close_on_scrim
        scrim = interact(Id.from("embedded/#{id}/scrim"), screen,
          Sense::Click, layer, screen)
        close = true if scrim.clicked?
      end

      # Size: last frame's measured size. Until the user drags the
      # window it re-centers on that measured size every frame; after a
      # drag the stored Areas position wins.
      size = @memory.layer_sizes[win_id]? || Vec2.new(width, 220.0)
      default_pos = Pos2.new(screen.center.x - size.x / 2.0,
        screen.center.y - size.y / 2.0)
      pos = @memory.areas.user_moved?(win_id) ?
        @memory.areas.pos_for(win_id, default_pos) : default_pos
      # constrain_y: a centered card taller than the screen pins at the
      # top instead of centering its top edge off-screen.
      pos, size = constrain_floating(pos, Vec2.new(size.x, size.y),
        WINDOW_MIN_SIZE.x, constrain_y: true)
      @memory.areas.set_pos(win_id, pos)

      # A click on blank card space dies on the card (registered after
      # the scrim, so it wins over "click outside to dismiss").
      card_rect = Rect.from_min_size(pos, Vec2.new(size.x, 1e6))
      interact(Id.from("embedded/#{id}/card"), card_rect,
        Sense::Click, layer, card_rect)

      # Title bar: drag moves the window (Areas state), like #window.
      if title
        title_rect = Rect.from_min_size(pos, Vec2.new(size.x, title_h))
        title_resp = interact(win_id.child(0_u64), title_rect,
          Sense.click_and_drag, layer)
        if title_resp.dragged?
          @memory.areas.move_by(win_id, title_resp.drag_delta)
          pos = @memory.areas.pos_for(win_id, default_pos)
          pos, size = constrain_floating(pos, Vec2.new(size.x, size.y),
            WINDOW_MIN_SIZE.x)
          @memory.areas.set_pos(win_id, pos)
        end
      end

      # The dialog shell is back-painted at the end (bg_index below);
      # stroke at low alpha like #modal's card. The title band gets its
      # own reserved slot UNDER the title text: the band rect is only
      # known after the content is measured, but simply painting it at
      # the end would stack it OVER the title and the ✕ (within a
      # layer, insertion order == paint order).
      bg_index = @painter.add_noop
      band_index = title ? @painter.add_noop : nil
      clip = Rect.from_min_size(pos, Vec2.new(size.x, 1e6))
      @painter.clip = clip

      if title
        # ✕ in the title bar's right corner.
        close_size = title_h
        close_rect = Rect.from_min_size(
          Pos2.new(pos.x + size.x - close_size, pos.y),
          Vec2.new(close_size, title_h))
        close_resp = interact(Id.from("embedded/#{id}/close"), close_rect,
          Sense::Click, layer, close_rect)
        close = true if close_resp.clicked?

        @painter.text(Pos2.new(pos.x + pad.x, pos.y + title_h / 2.0),
          title, title_size, v.title_color)
        @painter.text(Pos2.new(close_rect.center.x, close_rect.center.y),
          "✕", title_size, v.title_color)
      end

      content_min = pos + Vec2.new(pad.x, title_h + pad.y)
      ui = Ui.new(self, win_id,
        Rect.from_min_size(content_min, Vec2.new(size.x - 2 * pad.x, 1e6)))
      ui.layer = layer
      ui.clip = clip
      yield ui

      # Content may leave the painter in another layer — a popup opened
      # inside the dialog resets it to Background on exit — so this
      # window's layer must be re-established before the trailing paints.
      @painter.layer = Order::Foreground

      outer = Rect.new(
        pos,
        Pos2.new({ui.min_rect.right + pad.x, pos.x + size.x}.max,
          ui.min_rect.bottom + pad.y))
      @memory.layer_sizes[win_id] = outer.size
      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, v.window_rounding, v.window_fill,
          Color32.rgba(v.window_stroke.r, v.window_stroke.g,
            v.window_stroke.b, 90), 1.0))
      @painter.set(band_index,
        RectCmd.new(outer, Rect.from_min_size(pos, Vec2.new(outer.width, title_h)),
          v.window_rounding, v.title_bar_fill, nil, 0.0)) if band_index
      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
      close
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

    # Panel resizing (egui `Panel::resizable`, default there too): a
# drag grip on the panel's inner edge grows/shrinks it, persisted per
# panel id in Memory. `height:`/`width:` become the INITIAL size.
    PANEL_GRIP     = 6.0    # draggable strip thickness around the edge
    PANEL_MIN_SIZE = 20.0   # the floor a drag grip cannot shrink past;
                            # also the minimum default panel extent
    PANEL_GRIP_SALT  = 0x9E51A1_u64 # grip interact id (away from content counters)
    PANEL_SIZE_SALT  = 0x51AB2E5_u64 # stored size key in IdTypeMap

    # Default height for a top/bottom strip with no *height*: one text
    # line plus the panel's vertical padding. #panel_ui shrinks a panel
    # by window_padding on EVERY side, so the flat PANEL_MIN_SIZE floor
    # (20px) leaves a zero-height interior — the strip's content then
    # spilled past the window edge (half-clipped status bars, the
    # 4bbf49b regression this restores the 7ff099d default for).
    private def default_strip_height : Float64
      {style.font_size * Fonts::LINE_H_FACTOR +
        2 * style.spacing.window_padding.y, PANEL_MIN_SIZE}.max
    end

    # *height* pins the strip height (nil → #default_strip_height); the
    # client-side window frame uses it for its caption.
    # *resizable* (default) adds the drag grip on the inner edge — the
    # size persists across frames and restarts-of-frame-loop; pass
    # false for fixed chrome strips (the window frame does).
    def top_panel(id : String = "top_panel", height : Float64? = nil,
                  resizable : Bool = true, &block : Ui ->) : Rect
      h = panel_size(id, height || default_strip_height, resizable)
      rect = Rect.from_min_size(@available_rect.min,
        Vec2.new(@available_rect.width, h))
      @available_rect = Rect.new(
        Pos2.new(rect.left, rect.bottom),
        @available_rect.max)
      panel_ui(id, rect, Layout.left_to_right,
        resizable: resizable, edge: :bottom, size: h) { |ui| yield ui }
      rect
    end

    def bottom_panel(id : String = "bottom_panel", height : Float64? = nil,
                     resizable : Bool = true, layer : LayerId? = nil,
                     fill : Color32? = nil, &block : Ui ->) : Rect
      h = panel_size(id, height || default_strip_height, resizable)
      rect = Rect.from_min_size(
        Pos2.new(@available_rect.min.x, @available_rect.max.y - h),
        Vec2.new(@available_rect.width, h))
      @available_rect = Rect.new(@available_rect.min,
        Pos2.new(rect.right, rect.top))
      panel_ui(id, rect, Layout.left_to_right,
        resizable: resizable, edge: :top, size: h,
        layer: layer, fill: fill) { |ui| yield ui }
      rect
    end

    def side_panel(side : Symbol, id : String = "side_panel",
                   width : Float64 = PANEL_MIN_SIZE, resizable : Bool = true,
                   layer : LayerId? = nil, fill : Color32? = nil,
                   &block : Ui ->) : Rect
      # The available-width bound is floored at PANEL_MIN_SIZE: a
      # window narrower than the panel shrinks the panel only down to
      # the floor (overflowing the screen edge and getting clipped),
      # never collapsing it to zero width.
      avail_w = {@available_rect.width, PANEL_MIN_SIZE}.max
      w = {panel_size(id, width, resizable), avail_w}.min
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
      panel_ui(id, rect, Layout.top_down,
        resizable: resizable,
        edge: side == :right ? :left : :right,
        size: w, layer: layer, fill: fill) { |ui| yield ui }
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

    # Render the deferred central panel NOW, into the current
    # #available_rect. Called from #end_frame — and from #page, so a
    # page's ctx-level panels (menu bar, status bar, central panel)
    # complete INSIDE the page, before the page bites the remainder
    # (otherwise the deferred central block would render after the
    # bite, into an empty rect — the routed-notepad lesson).
    private def flush_central_panel : Nil
      if (central = @central_block)
        @central_block = nil
        panel_ui(central[0], @available_rect, Layout.top_down,
          central[2]) { |ui| central[1].call(ui) }
      end
    end

    # Bench seam: the central panel is DEFERRED to end_frame (see
    # #end_frame), so a benchmark's "update" phase runs only the
    # panels declared before it — make the deferred render visible as
    # its own span instead of hiding it inside end_frame's total.
    private def flush_central_panel_spanned : Nil
      Egui::Bench.span("Context#central_panel(deferred)") { flush_central_panel }
    end

    private def panel_ui(id : String, rect : Rect, layout : Layout,
                         fill : Color32? = nil, resizable : Bool = false,
                         edge : Symbol? = nil, size : Float64 = 0.0,
                         layer : LayerId? = nil, &block : Ui ->) : Nil
      pad = style.spacing.window_padding

      # Normally panels ride the Background layer under everything;
      # `layer` hoists a panel above it (the inspector panel rides a
      # dedicated z=98 layer above app windows — see inspector.cr) —
      # paint AND interaction both follow the layer's z.
      @painter.layer = layer ? layer.z : Order::Background
      bg_index = @painter.add_noop
      @painter.clip = rect
      @painter.set(bg_index,
        RectCmd.new(rect, rect, 0.0, fill || style.visuals.panel_fill,
          style.visuals.window_stroke, 1.0))

      ui = Ui.new(self, Id.from("panel/#{id}"),
        rect.shrink(pad.x), layout)
      ui.clip = rect
      ui.layer = layer if layer
      # CSS `overflow-y: auto` by default for top-down panels (egui.cr
      # fix, no upstream counterpart): side/central panel content that
      # fits renders exactly as before — the overlay scrollbar only
      # appears on overflow — while taller content scrolls (wheel +
      # bar) instead of collapsing at the clipped bottom edge.
      # Horizontal top/bottom strips lay out a single row and keep
      # their old behavior (a panel that must scroll its body wraps
      # its own content in `ui.scroll_area` — see the Inspector).
      if layout.horizontal?
        yield ui
      else
        ScrollArea.new.show(ui) { |inner| yield inner }
      end
      panel_resize_grip(Id.from("panel/#{id}"), rect, edge, size, layer) if resizable && edge

      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    # The stored panel size (the panel's `height:`/`width:` default
    # until the user drags the grip). Marked used every frame so
    # end-frame pruning keeps the cell. Explicit sizes are respected
    # as given (window-frame chrome strips pass their own exact
    # extents); only the drag grip enforces the PANEL_MIN_SIZE floor.
    private def panel_size(id : String, default : Float64,
                           resizable : Bool) : Float64
      key = Id.from("panel/#{id}").child(PANEL_SIZE_SALT)
      @memory.use_id(key)
      @memory.data.get_f64(key, default)
    end

    # The drag grip on a panel's inner edge (egui `Panel::resizable`):
    # a PANEL_GRIP-tall strip straddling the edge, interacting with
    # Sense::drag this frame (the position is stable, so prev-frame
    # hit-testing finds it). Dragging maps the pointer delta onto the
    # grow axis (edge-dependent sign), clamps to [PANEL_MIN_SIZE,
    # 90% of the screen along the axis] and persists the new size —
    # the panel re-lays out on the next frame. Painted as a hairline
    # on the exact edge; hover/drag highlights it with the accent.
    private def panel_resize_grip(pid : Id, rect : Rect, edge : Symbol,
                                  size : Float64, layer : LayerId? = nil) : Nil
      half = PANEL_GRIP / 2.0
      grip = case edge
             when :top    then Rect.new(Pos2.new(rect.left, rect.top - half), Pos2.new(rect.right, rect.top + half))
             when :bottom then Rect.new(Pos2.new(rect.left, rect.bottom - half), Pos2.new(rect.right, rect.bottom + half))
             when :left   then Rect.new(Pos2.new(rect.left - half, rect.top), Pos2.new(rect.left + half, rect.bottom))
             when :right  then Rect.new(Pos2.new(rect.right - half, rect.top), Pos2.new(rect.right + half, rect.bottom))
             else              return
             end
      response = interact(pid.child(PANEL_GRIP_SALT), grip, Sense.drag,
        layer || LayerId.background, @input.screen_rect)

      vertical = edge == :top || edge == :bottom
      if response.hovered? || response.dragged?
        set_cursor_icon(vertical ? CursorIcon::NsResize : CursorIcon::EwResize)
      end

      v = style.visuals
      color = response.dragged? ? v.selection_fill :
              response.hovered? ? v.fade_color(v.selection_fill, 0.6) :
              v.separator_color
      if vertical
        y = edge == :top ? rect.top : rect.bottom
        @painter.line(Pos2.new(rect.left, y), Pos2.new(rect.right, y), 1.0, color)
      else
        x = edge == :left ? rect.left : rect.right
        @painter.line(Pos2.new(x, rect.top), Pos2.new(x, rect.bottom), 1.0, color)
      end

      return unless response.dragged?
      delta = response.drag_delta
      grow = vertical ? (edge == :top ? -delta.y : delta.y)
                      : (edge == :left ? -delta.x : delta.x)
      extent = vertical ? @input.screen_rect.height : @input.screen_rect.width
      new_size = (size + grow).clamp(PANEL_MIN_SIZE, extent * 0.9)
      @memory.data.set_f64(pid.child(PANEL_SIZE_SALT), new_size)
      request_repaint
    end
  end
end
