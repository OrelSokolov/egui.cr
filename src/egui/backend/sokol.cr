# Sokol backend: sokol_app window + sokol_gfx (via sokol_gl) rendering + a
# Crystal text stack (backend/text.cr + backend/freetype.cr: FreeType with
# real hinting, stb light-hint fallback, shared glyph atlas). The
# eframe-equivalent run loop:
#
#   sapp events → RawInput → begin_frame → app.update → end_frame →
#   rasterize glyphs + upload atlas → paint list → sgl quads + text quads
#   → sgl_draw → sg_commit

require "../../egui"
require "./text"
require "./freetype"

@[Link("egui_cr_sokol")]
{% if flag?(:win32) %}
# sokol_app/Win32 + WGL: windowing/GDI and the GL context live in the
# system DLLs — no X11 stack, no dl/pthread/m (MSVC CRT is implicit).
@[Link("opengl32")]
@[Link("gdi32")]
@[Link("user32")]
@[Link("shell32")]
{% elsif flag?(:darwin) %}
# sokol_app/macOS = Cocoa + NSOpenGL. Frameworks are passed by the
# Rakefile's --link-flags (-framework Cocoa/OpenGL/QuartzCore), and
# brew's libfreetype resolves through -L/opt/homebrew/lib — no -l links
# are needed here.
{% else %}
@[Link("GL")]
@[Link("X11")]
@[Link("Xi")]
@[Link("Xcursor")]
@[Link("dl")]
@[Link("pthread")]
@[Link("m")]
{% end %}
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

  # stb_truetype exposure (Crystal text stack, see backend/text.cr)
  struct StbVertex
    x, y, cx, cy, cx1, cy1 : Int16
    type : UInt8
    padding : UInt8
  end

  fun font_info_new = egui_cr_font_info_new(data : UInt8*, font_index : Int32) : Void*
  fun font_vmetrics = egui_cr_font_vmetrics(info : Void*, ascent : Int32*,
                                            descent : Int32*, linegap : Int32*)
  fun font_find_glyph = egui_cr_font_find_glyph(info : Void*, unicode : Int32) : Int32
  fun glyph_hmetrics = egui_cr_glyph_hmetrics(info : Void*, glyph : Int32,
                                              advance : Int32*, lsb : Int32*)
  fun glyph_kern = egui_cr_glyph_kern(info : Void*, g1 : Int32, g2 : Int32) : Int32
  fun scale_for_pixel_height = egui_cr_scale_for_pixel_height(info : Void*,
                                                              pixels : Float32) : Float32
  fun glyph_shape = egui_cr_glyph_shape(info : Void*, glyph : Int32,
                                        count : Int32*) : StbVertex*
  fun glyph_shape_free = egui_cr_glyph_shape_free(info : Void*, vertices : StbVertex*)

  # text pipeline + glyph atlas (Crystal text stack). Atlases are
  # per-instance: atlas_create returns its own view, atlas_update
  # addresses it by view id — multiple font backends can coexist.
  fun text_pipeline_init = egui_cr_text_pipeline_init
  fun text_pipeline_push = egui_cr_text_pipeline_push
  fun text_pipeline_pop = egui_cr_text_pipeline_pop
  fun atlas_create = egui_cr_atlas_create(w : Int32, h : Int32, data : UInt8*) : UInt32
  fun atlas_update = egui_cr_atlas_update(view_id : UInt32, w : Int32, h : Int32,
                                          data : UInt8*)

  # cursor (shim): `name` is a CSS cursor keyword
  fun set_cursor = egui_cr_set_cursor(name : UInt8*)
end

module Egui
  module Backend
    # The sokol_gfx rendering backend (eframe/glow_integration role).
    module Sokol
      class_getter app : Egui::App?

      @@events = [] of Egui::Event
      @@fonts : Egui::Backend::AtlasFonts?
      @@start = Time.instant
      @@cursor = Egui::CursorIcon::Default
      # Framebuffer pixels per UI point (retina: 2.0). UI layout and paint
      # commands stay in points; text is rasterized at the physical size.
      @@pixels_per_point : Float64 = 1.0

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
        LibEguiCr.text_pipeline_init
        app = @@app.not_nil!
        # Font backend: prefer FreeType (real hinting), fall back to the
        # stb light-hint rasterizer, then to the built-in monospace stub.
        # Candidates come from the Fonts system port (per-platform).
        # Windows: no FreeType binding is linked there (see freetype.cr),
        # so the stb rasterizer is the primary backend.
        font_paths = Egui::SystemPorts::Fonts.search_paths
        font = {% if flag?(:win32) %}
                 LightHintedFonts.from_system(font_paths)
               {% else %}
                 FreetypeFonts.from_system(font_paths) ||
                   LightHintedFonts.from_system(font_paths)
               {% end %}
        if font
          @@fonts = font
          app.ctx.fonts = font
        else
          STDERR.puts "egui-cr: no system font found (tried #{font_paths.first} …)"
          app.ctx.fonts = Egui::MonospaceFonts.new
        end
        app.ctx.textures = SokolTextureRegistry.new
      end

      # Swap the active font backend at runtime (e.g. a preview app
      # toggling between FreeType and the light-hint fallback). The new
      # backend's atlas is uploaded and bound on the next frame.
      def self.select_fonts(font : AtlasFonts) : Nil
        @@fonts = font
        @@app.try &.ctx.fonts = font
      end

      protected def self.on_event(type : Int32, mx : Float32, my : Float32,
                                  sx : Float32, sy : Float32, mods : UInt32,
                                  btn : UInt32, key : UInt32,
                                  chr : UInt32) : Nil
        # sokol reports pointer positions in framebuffer pixels (macOS
        # multiplies by the backing scale); the UI works in points
        # (sapp_width), like upstream egui's pixels_per_point conversion.
        if (scale = LibEguiCr.sapp_dpi_scale) > 1.0f32
          mx /= scale
          my /= scale
        end
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
        # Advance async system ports (file dialogs) — one bounded
        # scheduler pass, then deliver completed requests. Must run
        # before begin_frame so callbacks land in a stable frame state.
        Egui::SystemPorts::AsyncDialogs.pump

        # sokol reports sizes in FRAMEBUFFER pixels (sapp_width on retina
        # with high_dpi is 2x the window points); the UI lays out in
        # points, like upstream egui with pixels_per_point.
        ppp = LibEguiCr.sapp_dpi_scale.to_f64
        @@pixels_per_point = ppp > 0.0 ? ppp : 1.0

        app = @@app.not_nil!
        time = (Time.instant - @@start).total_seconds
        raw = Egui::RawInput.new(
          Egui::Rect.from_min_size(Egui::Pos2.zero,
            Egui::Vec2.new(LibEguiCr.sapp_width.to_f64 / @@pixels_per_point,
              LibEguiCr.sapp_height.to_f64 / @@pixels_per_point)),
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

        # Framebuffer pixels (native resolution on retina) and their
        # point-space counterparts.
        fb_w = LibEguiCr.sapp_width
        fb_h = LibEguiCr.sapp_height
        w = fb_w.to_f64 / @@pixels_per_point
        h = fb_h.to_f64 / @@pixels_per_point
        # Backdrop follows the theme (its base surface color) so edges
        # never flash the stale palette after a theme swap.
        bg = app.ctx.style.visuals.panel_fill
        LibEguiCr.set_clear_color(
          bg.r.to_f32 / 255.0f32, bg.g.to_f32 / 255.0f32,
          bg.b.to_f32 / 255.0f32, bg.a.to_f32 / 255.0f32)

        # Rasterize every glyph this frame's text needs (at the PHYSICAL
        # pixel size — see paint_text) and upload the atlas BEFORE the
        # render pass — sg_update_image is illegal inside a pass.
        if fonts = @@fonts
          commands.each do |cmd|
            fonts.touch(cmd, @@pixels_per_point) if cmd.is_a?(Egui::TextCmd)
          end
          fonts.flush
        end

        LibEguiCr.begin_pass(fb_w, fb_h)

        # Ortho stays in POINTS; the framebuffer-sized viewport scales them
        # up on retina, so all geometry (rects/lines/circles/images) renders
        # at native resolution without per-command changes.
        LibEguiCr.sgl_viewport(0, 0, fb_w, fb_h, true)
        LibEguiCr.sgl_matrix_mode_projection
        LibEguiCr.sgl_load_identity
        LibEguiCr.sgl_ortho(0.0f32, w.to_f32, h.to_f32, 0.0f32, -1.0f32, 1.0f32)
        LibEguiCr.sgl_matrix_mode_modelview
        LibEguiCr.sgl_load_identity

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
      # pixel row/column stays inside the scissor. Scissor rects are in
      # FRAMEBUFFER pixels — scale the point-space clip by ppp first.
      def self.apply_scissor(clip : Egui::Rect) : Nil
        s = @@pixels_per_point
        x = (clip.min.x * s).floor
        y = (clip.min.y * s).floor
        w = {(clip.max.x * s).ceil - x, 1.0}.max
        h = {(clip.max.y * s).ceil - y, 1.0}.max
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
        fonts = @@fonts
        return unless fonts

        apply_scissor(cmd.clip)

        # Text is the one thing that must be rasterized at PHYSICAL
        # resolution: at 1x-on-retina every coverage edge goes soft after
        # the compositor upscale. Metrics are linear in size, so all
        # positions below are simply the point-space ones times `ppp`;
        # the glyph quads then snap to whole framebuffer pixels (rounded
        # pen + rounded baseline) like upstream egui's pixel snapping.
        ppp = @@pixels_per_point
        draw_size = cmd.size * ppp

        # TextCmd.pos anchors the LEFT-CENTER of the text box; convert to a
        # baseline using the font's ascender/descender.
        asc, desc = fonts.metrics_at(draw_size)
        baseline = ((cmd.pos.y + (asc + desc) / 2.0 / ppp) * ppp).round.to_f32

        view = fonts.atlas_view_id
        return if view.zero?

        color = cmd.color
        x_origin = cmd.pos.x * ppp
        inv = (1.0 / ppp).to_f32 # emit in points; the viewport scales back
        # letter_spacing is absolute px — widen it with the draw size so
        # the tracking reads the same at 2x as at 1x.
        saved_spacing = fonts.letter_spacing
        fonts.letter_spacing = saved_spacing * ppp
        LibEguiCr.sgl_bind_texture(view)
        LibEguiCr.sgl_enable_texture
        LibEguiCr.text_pipeline_push
        LibEguiCr.sgl_begin_quads
        fonts.walk(cmd.text, draw_size) do |pen, g|
          next if g.w == 0 || g.h == 0
          x0 = (x_origin + pen + g.xoff).round.to_f32
          y0 = baseline - g.ytop.to_f32
          x1 = x0 + g.w.to_f32
          y1 = y0 + g.h.to_f32
          LibEguiCr.sgl_v2f_t2f_c4b(x0 * inv, y0 * inv, g.u0, g.v0, color.r, color.g, color.b, color.a)
          LibEguiCr.sgl_v2f_t2f_c4b(x1 * inv, y0 * inv, g.u1, g.v0, color.r, color.g, color.b, color.a)
          LibEguiCr.sgl_v2f_t2f_c4b(x1 * inv, y1 * inv, g.u1, g.v1, color.r, color.g, color.b, color.a)
          LibEguiCr.sgl_v2f_t2f_c4b(x0 * inv, y1 * inv, g.u0, g.v1, color.r, color.g, color.b, color.a)
        end
        LibEguiCr.sgl_end
        LibEguiCr.text_pipeline_pop
        LibEguiCr.sgl_disable_texture
        fonts.letter_spacing = saved_spacing
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

      @@cbs : {LibEguiCr::InitCb, LibEguiCr::FrameCb, LibEguiCr::EventCb, LibEguiCr::CleanupCb}?
    end
  end
end
