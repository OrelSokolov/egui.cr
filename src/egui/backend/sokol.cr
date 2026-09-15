# Sokol backend: sokol_app window + sokol_gfx (via sokol_gl) rendering
# + fontstash text. The eframe-equivalent run loop:
#
#   sapp events → RawInput → begin_frame → app.update → end_frame →
#   paint list → sgl quads + fonsDrawText → sgl_draw → sg_commit

require "../../egui"

@[Link("egui_cr_sokol")]
@[Link("GL")]
@[Link("X11")]
@[Link("Xi")]
@[Link("Xcursor")]
@[Link("dl")]
@[Link("pthread")]
@[Link("m")]
lib LibEguiCr
  alias InitCb = ->
  alias FrameCb = ->
  alias CleanupCb = ->
  alias EventCb = Int32, Float32, Float32, Float32, Float32, UInt32, UInt32, UInt32, UInt32 ->

  # shim
  fun sapp_run = egui_cr_sapp_run(init : InitCb, frame : FrameCb, event : EventCb,
                                  cleanup : CleanupCb, title : UInt8*,
                                  width : Int32, height : Int32)
  fun gfx_init = egui_cr_gfx_init
  fun sfons_create = egui_cr_sfons_create(width : Int32, height : Int32) : Void*
  fun begin_pass = egui_cr_begin_pass(w : Int32, h : Int32)
  fun end_pass = egui_cr_end_pass
  fun set_clear_color = egui_cr_set_clear_color(r : Float32, g : Float32,
                                                b : Float32, a : Float32)

  # sokol_app
  fun sapp_width : Int32
  fun sapp_height : Int32
  fun sapp_dpi_scale : Float32
  fun sapp_quit
  fun sapp_is_fullscreen : Bool
  fun sapp_toggle_fullscreen
  fun sapp_set_window_title = sapp_set_window_title(title : UInt8*)
  fun sapp_set_clipboard_string = sapp_set_clipboard_string(str : UInt8*)
  fun sapp_get_clipboard_string : UInt8*

  # window management (shim: X11 / Win32)
  fun set_window_size = egui_cr_set_window_size(w : Int32, h : Int32)
  fun set_window_position = egui_cr_set_window_position(x : Int32, y : Int32)
  fun window_minimize = egui_cr_window_minimize
  fun window_maximize = egui_cr_window_maximize
  fun window_restore = egui_cr_window_restore
  fun screen_size = egui_cr_screen_size(w : Int32*, h : Int32*)

  # sokol_gl
  fun sgl_viewport(x : Int32, y : Int32, w : Int32, h : Int32, origin_top_left : Bool)
  fun sgl_matrix_mode_projection
  fun sgl_matrix_mode_modelview
  fun sgl_load_identity
  fun sgl_ortho(l : Float32, r : Float32, b : Float32, t : Float32, n : Float32, f : Float32)
  fun sgl_scissor_rectf(x : Float32, y : Float32, w : Float32, h : Float32, origin_top_left : Bool)
  fun sgl_begin_quads
  fun sgl_end
  fun sgl_v2f_c4b(x : Float32, y : Float32, r : UInt8, g : UInt8, b : UInt8, a : UInt8)
  fun sgl_v2f_t2f_c4b(x : Float32, y : Float32, u : Float32, v : Float32,
                      r : UInt8, g : UInt8, b : UInt8, a : UInt8)

  # textures (shim)
  fun make_texture = egui_cr_make_texture(w : Int32, h : Int32, data : UInt8*) : UInt32
  fun sgl_bind_texture = egui_cr_sgl_texture(view_id : UInt32)
  fun sgl_enable_texture = egui_cr_sgl_enable_texture
  fun sgl_disable_texture = egui_cr_sgl_disable_texture
  fun load_image = egui_cr_load_image(path : UInt8*) : UInt32

  # cursor (shim): `name` is a CSS cursor keyword
  fun set_cursor = egui_cr_set_cursor(name : UInt8*)

  # fontstash / sokol_fontstash (fontstash exports camelCase names)
  fun sfons_flush(ctx : Void*)
  fun sfons_rgba(r : UInt8, g : UInt8, b : UInt8, a : UInt8) : UInt32
  fun fons_add_font_mem = fonsAddFontMem(ctx : Void*, name : UInt8*, data : UInt8*, data_size : Int32, free_data : Int32) : Int32
  fun fons_clear_state = fonsClearState(ctx : Void*)
  fun fons_set_size = fonsSetSize(ctx : Void*, size : Float32)
  fun fons_set_font = fonsSetFont(ctx : Void*, font : Int32) : Int32
  fun fons_set_color = fonsSetColor(ctx : Void*, color : UInt32)
  fun fons_draw_text = fonsDrawText(ctx : Void*, x : Float32, y : Float32, str : UInt8*, end_ : UInt8*) : Float32
  fun fons_text_bounds = fonsTextBounds(ctx : Void*, x : Float32, y : Float32, str : UInt8*, end_ : UInt8*, bounds : Float32*) : Float32
  fun fons_vert_metrics = fonsVertMetrics(ctx : Void*, ascender : Float32*, descender : Float32*, line_height : Float32*) : Int32
end

module Egui
  module Backend
    # The sokol_gfx rendering backend (eframe/glow_integration role).
    module Sokol
      class_getter app : Egui::App?

      @@events = [] of Egui::Event
      @@fons : Void*?
      @@font_id = -1
      @@start = Time.instant
      @@cursor = Egui::CursorIcon::Default

      # System port Quit → sokol_app `sapp_quit`: closes the window on
      # every backend platform and leaves the run loop.
      class QuitPort < Egui::SystemPorts::Quit::Implementation
        def quit : Nil
          LibEguiCr.sapp_quit
        end
      end

      # System port Window → sokol_app (title, fullscreen) + shim
      # (resize/move/minimize/maximize: X11 core + _NET_WM_STATE, Win32).
      class WindowPort < Egui::SystemPorts::Window::Implementation
        def set_title(title : String) : Nil
          title.to_unsafe # ensure a contiguous buffer
          LibEguiCr.sapp_set_window_title(title.to_unsafe)
        end

        def set_size(width : Int32, height : Int32) : Nil
          LibEguiCr.set_window_size(width, height)
        end

        def set_position(x : Int32, y : Int32) : Nil
          LibEguiCr.set_window_position(x, y)
        end

        def minimize : Nil
          LibEguiCr.window_minimize
        end

        def maximize : Nil
          LibEguiCr.window_maximize
        end

        def restore : Nil
          LibEguiCr.window_restore
        end

        def toggle_fullscreen : Nil
          LibEguiCr.sapp_toggle_fullscreen
        end

        def fullscreen? : Bool
          LibEguiCr.sapp_is_fullscreen
        end
      end

      # System port Screen → sokol dpi scale + primary monitor size (shim).
      class ScreenPort < Egui::SystemPorts::Screen::Implementation
        def size : Egui::Vec2?
          w = uninitialized Int32
          h = uninitialized Int32
          LibEguiCr.screen_size(pointerof(w), pointerof(h))
          return nil if w <= 0 || h <= 0
          Egui::Vec2.new(w.to_f64, h.to_f64)
        end

        def dpi_scale : Float64
          LibEguiCr.sapp_dpi_scale.to_f64
        end
      end

      # System port Clipboard → sokol_app set/get clipboard string.
      class ClipboardPort < Egui::SystemPorts::Clipboard::Implementation
        def set(text : String) : Nil
          text.to_unsafe # ensure a contiguous buffer
          LibEguiCr.sapp_set_clipboard_string(text.to_unsafe)
        end

        def get : String?
          ptr = LibEguiCr.sapp_get_clipboard_string
          ptr ? String.new(ptr) : nil
        end
      end

      # sapp_event_type values (sokol_app.h)
      KEY_DOWN    = 1
      KEY_UP      = 2
      CHAR        = 3
      MOUSE_DOWN  =  4
      MOUSE_UP    =  5
      MOUSE_SCROLL = 6
      MOUSE_MOVE  =  7

      FONT_PATHS = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
        "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Regular.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
      ]

      # eframe::run_native — blocks until the window closes.
      def self.run(app : Egui::App, title : String = "egui-cr",
                   width : Int32 = 800, height : Int32 = 600) : Nil
        @@app = app
        Egui::SystemPorts::Quit.use(QuitPort.new)
        Egui::SystemPorts::Window.use(WindowPort.new)
        Egui::SystemPorts::Screen.use(ScreenPort.new)
        Egui::SystemPorts::Clipboard.use(ClipboardPort.new)

        init = ->{ on_init }
        frame = ->{ on_frame }
        event = ->(t : Int32, mx : Float32, my : Float32, sx : Float32, sy : Float32,
                    mods : UInt32, btn : UInt32, key : UInt32, chr : UInt32) {
          on_event(t, mx, my, sx, sy, mods, btn, key, chr)
        }
        cleanup = ->{ }

        # Keep proc objects referenced (GC) and enter the sapp loop.
        @@cbs = {init, frame, event, cleanup}
        LibEguiCr.sapp_run(init, frame, event, cleanup, title.to_unsafe, width, height)
      end

      protected def self.on_init : Nil
        LibEguiCr.gfx_init
        @@fons = LibEguiCr.sfons_create(512, 512)
        load_font
        app = @@app.not_nil!
        app.ctx.fonts = FontstashFonts.new(@@fons.not_nil!)
        app.ctx.textures = SokolTextureRegistry.new
      end

      protected def self.on_event(type : Int32, mx : Float32, my : Float32,
                                  sx : Float32, sy : Float32, mods : UInt32,
                                  btn : UInt32, key : UInt32,
                                  chr : UInt32) : Nil
        case type
        when MOUSE_MOVE
          @@events << Egui::Event.pointer_moved(Egui::Pos2.new(mx, my))
        when MOUSE_DOWN
          @@events << Egui::Event.pointer_pressed(Egui::Pos2.new(mx, my))
        when MOUSE_UP
          @@events << Egui::Event.pointer_released(Egui::Pos2.new(mx, my))
        when MOUSE_SCROLL
          # sapp reports scroll_y > 0 for wheel-up; egui.cr's convention
          # is positive = content scrolls down → negate.
          @@events << Egui::Event.scroll(Egui::Vec2.new(sx, -sy))
        when KEY_DOWN, KEY_UP
          # sapp fires KEY_* plus a separate CHAR event for text; we
          # only forward non-modifier keys here (modifier state rides
          # along in Modifiers).
          return if key >= 340 # SAPP_KEYCODE_LEFT_SHIFT .. RIGHT_SUPER
          code = Egui::KeyCode.from_value?(key)
          return unless code
          modifiers = Egui::Modifiers.from_mask(mods)
          if type == KEY_DOWN
            @@events << Egui::Event.key_pressed(code, modifiers)
          else
            @@events << Egui::Event.key_released(code, modifiers)
          end
        when CHAR
          # sapp char_code is a Unicode codepoint; skip surrogates.
          if (chr > 0 && chr < 0xD800) || (chr >= 0xE000 && chr < 0x110000)
            @@events << Egui::Event.text_input(chr.unsafe_chr.to_s)
          end
        end
      end

      protected def self.on_frame : Nil
        app = @@app.not_nil!
        time = (Time.instant - @@start).total_seconds
        raw = Egui::RawInput.new(
          Egui::Rect.from_min_size(Egui::Pos2.zero,
            Egui::Vec2.new(LibEguiCr.sapp_width.to_f64, LibEguiCr.sapp_height.to_f64)),
          @@events, time)
        @@events = [] of Egui::Event

        app.ctx.begin_frame(raw)
        app.update(app.ctx)
        commands = app.ctx.end_frame

        # egui `PlatformOutput::cursor_icon`: apply when it changed —
        # the shim maps the CSS keyword onto the Xcursor theme.
        icon = app.ctx.cursor_icon
        if icon != @@cursor
          @@cursor = icon
          LibEguiCr.set_cursor(icon.to_css.to_unsafe)
        end

        w = LibEguiCr.sapp_width
        h = LibEguiCr.sapp_height
        # Backdrop follows the theme (its base surface color) so edges
        # never flash the stale palette after a theme swap.
        bg = app.ctx.style.visuals.panel_fill
        LibEguiCr.set_clear_color(
          bg.r.to_f32 / 255.0f32, bg.g.to_f32 / 255.0f32,
          bg.b.to_f32 / 255.0f32, bg.a.to_f32 / 255.0f32)
        LibEguiCr.begin_pass(w, h)

        LibEguiCr.sgl_viewport(0, 0, w, h, true)
        LibEguiCr.sgl_matrix_mode_projection
        LibEguiCr.sgl_load_identity
        LibEguiCr.sgl_ortho(0.0f32, w.to_f32, h.to_f32, 0.0f32, -1.0f32, 1.0f32)
        LibEguiCr.sgl_matrix_mode_modelview
        LibEguiCr.sgl_load_identity

        if fons = @@fons
          LibEguiCr.sfons_flush(fons)
        end
        commands.each { |cmd| paint(cmd) }

        LibEguiCr.end_pass
      end

      def self.paint(cmd : Egui::PaintCmd) : Nil
        case cmd
        when Egui::RectCmd
          paint_rect(cmd)
        when Egui::TextCmd
          paint_text(cmd)
        when Egui::CircleCmd
          paint_circle(cmd)
        when Egui::LineCmd
          paint_line(cmd)
        when Egui::ArcCmd
          paint_arc(cmd)
        when Egui::ImageCmd
          paint_image(cmd)
        end
      end

      # sg_apply_scissor_rectf truncates x/y/w/h to ints independently
      # (sokol_gfx.h), so trunc(y) + trunc(h) can land a full pixel above
      # trunc(y + h) for a fractional clip — e.g. a modal centered at
      # screen.center - size/2 — clipping away a stroke sitting on the
      # rect edge (the invisible bottom border). Round outward instead:
      # floor the min corner, ceil the size, so every partially-covered
      # pixel row/column stays inside the scissor.
      def self.apply_scissor(clip : Egui::Rect) : Nil
        x = clip.min.x.floor
        y = clip.min.y.floor
        w = {clip.max.x.ceil - x, 1.0}.max
        h = {clip.max.y.ceil - y, 1.0}.max
        LibEguiCr.sgl_scissor_rectf(
          x.to_f32, y.to_f32, w.to_f32, h.to_f32, true)
      end

      def self.paint_image(cmd : Egui::ImageCmd) : Nil
        return if cmd.texture_id.zero? # failed loads paint nothing
        apply_scissor(cmd.clip)

        r = cmd.rect
        uv = cmd.uv
        t = cmd.tint
        # sgl_texture binds the texture for the following begin/end
        # block — it must be called OUTSIDE begin/end (the sokol_gl
        # assertion `!ctx->in_begin` enforces exactly that). sgl_texture
        # alone does not enable texturing: at draw time sokol_gl uses
        # cur_view/cur_smp only while texturing_enabled is set, so we
        # enable it here and disable after sgl_end — otherwise later
        # untextored geometry would sample this texture instead of the
        # internal white fallback.
        LibEguiCr.sgl_bind_texture(cmd.texture_id.to_u32!)
        LibEguiCr.sgl_enable_texture
        LibEguiCr.sgl_begin_quads
        LibEguiCr.sgl_v2f_t2f_c4b(r.min.x.to_f32, r.min.y.to_f32,
          uv.min.x.to_f32, uv.min.y.to_f32, t.r, t.g, t.b, t.a)
        LibEguiCr.sgl_v2f_t2f_c4b(r.max.x.to_f32, r.min.y.to_f32,
          uv.max.x.to_f32, uv.min.y.to_f32, t.r, t.g, t.b, t.a)
        LibEguiCr.sgl_v2f_t2f_c4b(r.max.x.to_f32, r.max.y.to_f32,
          uv.max.x.to_f32, uv.max.y.to_f32, t.r, t.g, t.b, t.a)
        LibEguiCr.sgl_v2f_t2f_c4b(r.min.x.to_f32, r.max.y.to_f32,
          uv.min.x.to_f32, uv.max.y.to_f32, t.r, t.g, t.b, t.a)
        LibEguiCr.sgl_end
        LibEguiCr.sgl_disable_texture
      end

      def self.paint_rect(cmd : Egui::RectCmd) : Nil
        apply_scissor(cmd.clip)

        r = cmd.rect
        round = cmd.rounding

        if (fill = cmd.fill) && (fill2 = cmd.fill2)
          # Vertical gradient: per-vertex colors, interpolated by the
          # rasterizer (Gouraud) — top verts c1, bottom verts c2.
          if round > 0.5
            rounded_rect_fill(r, round, fill, fill2)
          else
            LibEguiCr.sgl_begin_quads
            LibEguiCr.sgl_v2f_c4b(r.min.x.to_f32, r.min.y.to_f32, fill.r, fill.g, fill.b, fill.a)
            LibEguiCr.sgl_v2f_c4b(r.max.x.to_f32, r.min.y.to_f32, fill.r, fill.g, fill.b, fill.a)
            LibEguiCr.sgl_v2f_c4b(r.max.x.to_f32, r.max.y.to_f32, fill2.r, fill2.g, fill2.b, fill2.a)
            LibEguiCr.sgl_v2f_c4b(r.min.x.to_f32, r.max.y.to_f32, fill2.r, fill2.g, fill2.b, fill2.a)
            LibEguiCr.sgl_end
          end
        elsif fill
          if round > 0.5
            rounded_rect_fill(r, round, fill)
          else
            LibEguiCr.sgl_begin_quads
            quad(r, fill)
            LibEguiCr.sgl_end
          end
        end

        if (stroke = cmd.stroke_color) && cmd.stroke_width > 0
          w = cmd.stroke_width
          if round > 0.5
            paint_rect_stroke_rounded(r, round, w, stroke, cmd.clip)
          else
            LibEguiCr.sgl_begin_quads
            # top / bottom / left / right bars
            bar(Egui::Rect.from_min_size(r.min, Egui::Vec2.new(r.width, w)), stroke)
            bar(Egui::Rect.from_min_size(Egui::Pos2.new(r.min.x, r.max.y - w),
              Egui::Vec2.new(r.width, w)), stroke)
            bar(Egui::Rect.from_min_size(r.min, Egui::Vec2.new(w, r.height)), stroke)
            bar(Egui::Rect.from_min_size(Egui::Pos2.new(r.max.x - w, r.min.y),
              Egui::Vec2.new(w, r.height)), stroke)
            LibEguiCr.sgl_end
          end
        end
      end

      # Rounded-corner stroke: four shortened bars + four quarter-arc
      # rings (the epaint tessellator produces the same shape as a
      # stroked rounded path).
      def self.paint_rect_stroke_rounded(r : Egui::Rect, round : Float64,
                                         w : Float64, stroke : Egui::Color32,
                                         clip : Egui::Rect) : Nil
        half = Math.sqrt(2.0) / 2.0 * round
        LibEguiCr.sgl_begin_quads
        bar(Egui::Rect.from_min_size(Egui::Pos2.new(r.min.x + round, r.min.y),
          Egui::Vec2.new(r.width - 2 * round, w)), stroke)
        bar(Egui::Rect.from_min_size(Egui::Pos2.new(r.min.x + round, r.max.y - w),
          Egui::Vec2.new(r.width - 2 * round, w)), stroke)
        bar(Egui::Rect.from_min_size(Egui::Pos2.new(r.min.x, r.min.y + round),
          Egui::Vec2.new(w, r.height - 2 * round)), stroke)
        bar(Egui::Rect.from_min_size(Egui::Pos2.new(r.max.x - w, r.min.y + round),
          Egui::Vec2.new(w, r.height - 2 * round)), stroke)
        LibEguiCr.sgl_end

        # Quarter rings per corner. Angles are clockwise-from-+x in
        # y-down screen space: 180..270 = top-left, 270..360 = top-right,
        # 0..90 = bottom-right, 90..180 = bottom-left.
        # Quarter rings per corner. Angles are clockwise-from-+x in
        # y-down screen space: π..1.5π = top-left, 1.5π..2π = top-right,
        # 0..0.5π = bottom-right, 0.5π..π = bottom-left.
        rad = Math::PI
        radius = {round - w / 2.0, 0.0}.max
        paint_ring(Egui::Pos2.new(r.min.x + round, r.min.y + round), radius,
          rad, rad * 1.5, w, stroke, clip)
        paint_ring(Egui::Pos2.new(r.max.x - round, r.min.y + round), radius,
          rad * 1.5, rad * 2.0, w, stroke, clip)
        paint_ring(Egui::Pos2.new(r.max.x - round, r.max.y - round), radius,
          0.0, rad * 0.5, w, stroke, clip)
        paint_ring(Egui::Pos2.new(r.min.x + round, r.max.y - round), radius,
          rad * 0.5, rad, w, stroke, clip)
      end

      # Filled rounded rect: perimeter fan (degenerate quads from the
      # center), like a disc but with a rounded-rect rim. When `fill2`
      # is set the fill is a vertical gradient: each vertex color is
      # lerp(fill, fill2, y / height), interpolated across triangles.
      def self.rounded_rect_fill(r : Egui::Rect, round : Float64,
                                 fill : Egui::Color32,
                                 fill2 : Egui::Color32? = nil) : Nil
        round = {round, r.width / 2.0, r.height / 2.0}.min
        pts = [] of Egui::Pos2
        corner = ->(cx : Float64, cy : Float64, a0 : Float64) do
          6.times do |i|
            a = a0 + (Math::PI / 2.0) * i / 5.0
            pts << Egui::Pos2.new(cx + round * Math.cos(a),
              cy + round * Math.sin(a))
          end
        end
        rad = Math::PI
        corner.call(r.min.x + round, r.min.y + round, Math::PI)              # top-left
        corner.call(r.max.x - round, r.min.y + round, Math::PI * 1.5)        # top-right
        corner.call(r.max.x - round, r.max.y - round, 0.0)                   # bottom-right
        corner.call(r.min.x + round, r.max.y - round, Math::PI / 2.0)        # bottom-left

        center = r.center
        LibEguiCr.sgl_begin_quads
        pts.each_with_index do |p, i|
          q = pts[(i + 1) % pts.size]
          if fill2
            quad_pts_grad(center, p, q, fill, fill2, r)
          else
            quad_pts(center, center, p, q, fill)
          end
        end
        LibEguiCr.sgl_end
      end

      # Vertical-gradient color at `y` within `r` (Gouraud per-vertex).
      def self.grad_color(c1 : Egui::Color32, c2 : Egui::Color32,
                          y : Float64, r : Egui::Rect) : Egui::Color32
        t = ((y - r.min.y) / {r.height, 1e-9}.max).clamp(0.0, 1.0)
        Egui::Color32.new(
          (c1.r.to_f + (c2.r.to_f - c1.r.to_f) * t).round.to_u8,
          (c1.g.to_f + (c2.g.to_f - c1.g.to_f) * t).round.to_u8,
          (c1.b.to_f + (c2.b.to_f - c1.b.to_f) * t).round.to_u8,
          (c1.a.to_f + (c2.a.to_f - c1.a.to_f) * t).round.to_u8)
      end

      # Triangle fan slice (center, p, q) with per-vertex gradient colors.
      def self.quad_pts_grad(center : Egui::Pos2, p : Egui::Pos2, q : Egui::Pos2,
                             c1 : Egui::Color32, c2 : Egui::Color32,
                             r : Egui::Rect) : Nil
        cc = grad_color(c1, c2, center.y, r)
        pc = grad_color(c1, c2, p.y, r)
        qc = grad_color(c1, c2, q.y, r)
        LibEguiCr.sgl_v2f_c4b(center.x.to_f32, center.y.to_f32, cc.r, cc.g, cc.b, cc.a)
        LibEguiCr.sgl_v2f_c4b(center.x.to_f32, center.y.to_f32, cc.r, cc.g, cc.b, cc.a)
        LibEguiCr.sgl_v2f_c4b(p.x.to_f32, p.y.to_f32, pc.r, pc.g, pc.b, pc.a)
        LibEguiCr.sgl_v2f_c4b(q.x.to_f32, q.y.to_f32, qc.r, qc.g, qc.b, qc.a)
      end


      def self.paint_text(cmd : Egui::TextCmd) : Nil
        fons = @@fons
        return unless fons

        apply_scissor(cmd.clip)

        LibEguiCr.fons_clear_state(fons)
        LibEguiCr.fons_set_size(fons, cmd.size.to_f32)
        LibEguiCr.fons_set_font(fons, @@font_id)
        color = cmd.color
        LibEguiCr.fons_set_color(fons,
          LibEguiCr.sfons_rgba(color.r, color.g, color.b, color.a))

        # TextCmd.pos anchors the LEFT-CENTER of the text box; convert
        # to a baseline using the font's ascender/descender.
        asc, desc = FontstashFonts.metrics(fons, cmd.size)
        baseline = (cmd.pos.y + (asc + desc) / 2.0).to_f32

        cmd.text.to_unsafe # ensure the string has a contiguous buffer
        LibEguiCr.fons_draw_text(fons, cmd.pos.x.to_f32, baseline,
          cmd.text.to_unsafe, Pointer(UInt8).null)
      end

      def self.quad(r : Egui::Rect, c : Egui::Color32) : Nil
        x0 = r.min.x.to_f32
        y0 = r.min.y.to_f32
        x1 = r.max.x.to_f32
        y1 = r.max.y.to_f32
        LibEguiCr.sgl_v2f_c4b(x0, y0, c.r, c.g, c.b, c.a)
        LibEguiCr.sgl_v2f_c4b(x1, y0, c.r, c.g, c.b, c.a)
        LibEguiCr.sgl_v2f_c4b(x1, y1, c.r, c.g, c.b, c.a)
        LibEguiCr.sgl_v2f_c4b(x0, y1, c.r, c.g, c.b, c.a)
      end

      # A quad from four arbitrary points (what the egui tessellator
      # produces for thick lines, rings and arcs — stroke geometry is
      # just quads in epaint too).
      def self.quad_pts(p1 : Egui::Pos2, p2 : Egui::Pos2, p3 : Egui::Pos2,
                        p4 : Egui::Pos2, c : Egui::Color32) : Nil
        LibEguiCr.sgl_v2f_c4b(p1.x.to_f32, p1.y.to_f32, c.r, c.g, c.b, c.a)
        LibEguiCr.sgl_v2f_c4b(p2.x.to_f32, p2.y.to_f32, c.r, c.g, c.b, c.a)
        LibEguiCr.sgl_v2f_c4b(p3.x.to_f32, p3.y.to_f32, c.r, c.g, c.b, c.a)
        LibEguiCr.sgl_v2f_c4b(p4.x.to_f32, p4.y.to_f32, c.r, c.g, c.b, c.a)
      end

      TAU = (2.0 * Math::PI)

      # Full-circle tessellation segment count, using the same radius
      # cutoffs as upstream epaint (`Tessellator::add_circle`: 8/16/
      # 32/64/128). Small circles stay cheap, big ones stay round; the
      # 4x MSAA framebuffer (backend/sokol_shim.c) smooths the edges.
      def self.circle_segments(radius : Float64) : Int32
        if radius <= 2.0
          8
        elsif radius <= 5.0
          16
        elsif radius < 18.0
          32
        elsif radius < 50.0
          64
        else
          128
        end
      end

      def self.paint_circle(cmd : Egui::CircleCmd) : Nil
        apply_scissor(cmd.clip)

        if fill = cmd.fill
          LibEguiCr.sgl_begin_quads
          segments = circle_segments(cmd.radius)
          segments.times do |i|
            a0 = TAU * i / segments
            a1 = TAU * (i + 1) / segments
            v0 = Egui::Pos2.new(cmd.center.x + cmd.radius * Math.cos(a0),
              cmd.center.y + cmd.radius * Math.sin(a0))
            v1 = Egui::Pos2.new(cmd.center.x + cmd.radius * Math.cos(a1),
              cmd.center.y + cmd.radius * Math.sin(a1))
            # degenerate quad == triangle (c, c, v0, v1)
            quad_pts(cmd.center, cmd.center, v0, v1, fill)
          end
          LibEguiCr.sgl_end
        end

        if (stroke = cmd.stroke) && cmd.stroke_width > 0
          paint_ring(cmd.center, cmd.radius, 0.0, TAU, cmd.stroke_width, stroke, cmd.clip)
        end
      end

      def self.paint_line(cmd : Egui::LineCmd) : Nil
        apply_scissor(cmd.clip)

        d = cmd.p2 - cmd.p1
        len = d.length
        return if len < 1e-9
        # perpendicular unit vector scaled to half the stroke width
        n = Egui::Vec2.new(-d.y / len, d.x / len) * (cmd.width / 2.0)
        LibEguiCr.sgl_begin_quads
        quad_pts(cmd.p1 - n, cmd.p2 - n, cmd.p2 + n, cmd.p1 + n, cmd.color)
        LibEguiCr.sgl_end
      end

      def self.paint_arc(cmd : Egui::ArcCmd) : Nil
        clip = cmd.clip
        paint_ring(cmd.center, cmd.radius, cmd.start_angle, cmd.end_angle,
          cmd.width, cmd.color, clip)
      end

      # The shared geometry of stroked circles and arcs: a strip of quads
      # between radius - width/2 and radius + width/2.
      def self.paint_ring(center : Egui::Pos2, radius : Float64,
                          start_angle : Float64, end_angle : Float64,
                          width : Float64, color : Egui::Color32,
                          clip : Egui::Rect) : Nil
        apply_scissor(clip)

        r0 = {radius - width / 2.0, 0.0}.max
        r1 = radius + width / 2.0
        span = end_angle - start_angle
        segments = Math.max(8,
          (circle_segments(r1) * span.abs / TAU).ceil.to_i)

        LibEguiCr.sgl_begin_quads
        segments.times do |i|
          a0 = start_angle + span * i / segments
          a1 = start_angle + span * (i + 1) / segments
          c0 = Math.cos(a0)
          s0 = Math.sin(a0)
          c1 = Math.cos(a1)
          s1 = Math.sin(a1)
          quad_pts(
            Egui::Pos2.new(center.x + r0 * c0, center.y + r0 * s0),
            Egui::Pos2.new(center.x + r1 * c0, center.y + r1 * s0),
            Egui::Pos2.new(center.x + r1 * c1, center.y + r1 * s1),
            Egui::Pos2.new(center.x + r0 * c1, center.y + r0 * s1),
            color)
        end
        LibEguiCr.sgl_end
      end

      def self.bar(r : Egui::Rect, c : Egui::Color32) : Nil
        quad(r, c)
      end

      def self.load_font : Nil
        fons = @@fons.not_nil!
        FONT_PATHS.each do |path|
          next unless File.exists?(path)
          data = File.read(path)
          # fonsAddFontMem does NOT copy: the buffer must outlive the app.
          data_bytes = data.to_unsafe
          @@font_data = data
          id = LibEguiCr.fons_add_font_mem(fons, "sans", data_bytes,
            data.bytesize, 0)
          if id >= 0
            @@font_id = id
            return
          end
        end
        STDERR.puts "egui-cr: no system font found (tried #{FONT_PATHS.first} …)"
        @@font_id = -1
      end

      class_property font_data : String?

      # GPU textures via the shim (sg_make_image/sampler/view); the
      # core sees opaque UInt64 handles only.
      class SokolTextureRegistry < Egui::TextureRegistry
        def register_rgba(width : Int32, height : Int32,
                          data : Bytes) : UInt64
          return 0_u64 if width <= 0 || height <= 0
          LibEguiCr.make_texture(width, height,
            data.to_unsafe).to_u64
        end

        def load(path : String) : UInt64
          LibEguiCr.load_image(path.to_unsafe).to_u64
        end
      end

      # Real font metrics for the core's text measurement seam
      # (egui `Fonts`/`Galley` equivalent).
      class FontstashFonts < Egui::Fonts
        @metrics = {} of Float64 => {Float64, Float64}

        def initialize(@fons : Void*)
        end

        def measure(text : String, size : Float64) : Egui::Vec2
          return Egui::Vec2.zero if text.empty?
          asc, desc = metrics_at(size)
          bounds = StaticFloat32Array.new(4)
          width = LibEguiCr.fons_text_bounds(@fons, 0.0f32, 0.0f32,
            text.to_unsafe, Pointer(UInt8).null, bounds)
          Egui::Vec2.new(width.to_f64, asc - desc)
        end

        def self.metrics(fons : Void*, size : Float64) : {Float64, Float64}
          asc = uninitialized Float32
          desc = uninitialized Float32
          line = uninitialized Float32
          LibEguiCr.fons_set_size(fons, size.to_f32)
          LibEguiCr.fons_vert_metrics(fons,
            pointerof(asc), pointerof(desc), pointerof(line))
          {asc.to_f64, desc.to_f64}
        end

        private def metrics_at(size : Float64) : {Float64, Float64}
          @metrics[size] ||= begin
            m = FontstashFonts.metrics(@fons, size)
            m
          end
        end

        # A tiny fixed buffer that behaves like `float[4]`.
        class StaticFloat32Array
          def initialize(n : Int32)
            @buf = Pointer(Float32).malloc(n)
          end

          def to_unsafe : Float32*
            @buf
          end
        end
      end

      @@cbs : {LibEguiCr::InitCb, LibEguiCr::FrameCb, LibEguiCr::EventCb, LibEguiCr::CleanupCb}?
    end
  end
end
