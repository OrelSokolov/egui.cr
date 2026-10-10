# Sokol backend: sokol_app window + sokol_gfx (via sokol_gl) rendering + a
# Crystal text stack (backend/crystalfonts.cr primary — the freetype-cr
# pure-Crystal port; backend/freetype.cr C-FFI dev accelerator behind
# C_EXTENSIONS; shared glyph atlas). The
# eframe-equivalent run loop:
#
#   sapp events → RawInput → begin_frame → app.update → end_frame →
#   rasterize glyphs + upload atlas → paint list → sgl quads + text quads
#   → sgl_draw → sg_commit
#
# On Linux and Win32 the loop is detached (loop_redesign.md): the sokol
# window/GL/swap runs on a C render thread while this side keeps the
# Crystal scheduler and produces FramePackets (see #run_detached); macOS
# stays on the single-threaded legacy loop.

require "../../egui"
require "./text"
require "./crystalfonts"
# Win32 detached loop: the doorbell's A-side end is an overlapped socket
# (see run_detached) — Socket comes from the stdlib, egui itself never
# needs it elsewhere.
{% if flag?(:win32) %}
  require "socket"
{% end %}
# DEV-build bake accelerators (fonts + SVG): without --release the
# Crystal port's hot loops run 10-100x slower (no regalloc/inlining,
# bounds checks on every array access), while the C code is cc -O2
# regardless of Crystal's flags. Enabled per-backend by C_EXTENSIONS
# (USE_C_EXTENSIONS=1 in .env); release builds stay pure Crystal
# (byte-identical output, so dev and release render the same).
{% if Egui::Backend::C_EXTENSIONS %}
  # Fonts: system libfreetype through the C FFI (backend/freetype.cr).
  require "./freetype"
  # SVG: the C NanoSVG shim (backend/nanosvg.cr).
  require "./nanosvg"
  rasterizer = ->Egui::Backend::NanoSvg.rasterize(String, Egui::Color32, Int32, Int32)
  Egui::Svg.external_rasterizer = rasterizer
{% end %}

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
  @[Link("Xext")]
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
                                  width : Int32, height : Int32,
                                  borderless : Int32, transparent : Int32,
                                  swap_interval : Int32)
  fun gfx_init = egui_cr_gfx_init
  fun begin_pass = egui_cr_begin_pass(w : Int32, h : Int32)
  fun end_pass = egui_cr_end_pass
  fun set_clear_color = egui_cr_set_clear_color(r : Float32, g : Float32,
                                                b : Float32, a : Float32)
  fun present_clear = egui_cr_present_clear

  # detached render loop (shim, Linux + Win32): spawn the render thread
  # and get the main-thread doorbell handle (a pipe fd on Linux, an
  # overlapped socket on Win32); events arrive through a ring
  # (#events_pop), frames leave through the packet builder
  # (#begin_pass/#end_pass route there automatically).
  {% if flag?(:linux) || flag?(:win32) %}
    fun start = egui_cr_start(title : UInt8*, width : Int32, height : Int32,
                              borderless : Int32, transparent : Int32,
                              swap_interval : Int32) : Int64
    fun join = egui_cr_join
    fun wake_main = egui_cr_wake_main
    fun set_ppp = egui_cr_set_ppp(ppp : Float32)
    # Non-blocking drain of the doorbell into buf (up to cap bytes);
    # returns the byte count — same contract for the pipe and the socket.
    fun doorbell_drain = egui_cr_doorbell_drain(handle : Int64, buf : UInt8*,
                                                cap : Int32) : Int32
    {% if flag?(:win32) %}
      # Hand R's doorbell write end (a Crystal-created TCPSocket's fd) to
      # the shim before #start — see run_detached for why the pair must be
      # Crystal-made on Win32.
      fun doorbell_set_peer = egui_cr_doorbell_set_peer(fd : Int64)
    {% end %}

    # One input event as the render thread flattened it (backend/
    # sokol_shim.c sh_event_rec_t). `payload` carries the dropped-files
    # path list for FILES_DROPPED (free with #drop_payload_free).
    struct EventRecord
      type : Int32
      mx, my, sx, sy : Float32
      mods, mouse_button, key_code, char_code : UInt32
      payload : Void*
    end

    fun events_pop = egui_cr_events_pop(out : EventRecord*, cap : Int32) : Int32
    fun drop_payload_free = egui_cr_drop_payload_free(payload : Void*)
  {% end %}

  # sokol_app (window title/clipboard/fullscreen/quit go through shim
  # wrappers: on the detached path they must be marshalled to the
  # render thread's X connection)
  fun sapp_width : Int32
  fun sapp_height : Int32
  fun sapp_dpi_scale : Float32
  fun request_quit = egui_cr_request_quit
  fun fullscreen_q = egui_cr_fullscreen_q : Int32
  fun toggle_fullscreen = egui_cr_toggle_fullscreen
  fun set_window_title = egui_cr_set_window_title(title : UInt8*)
  fun clipboard_set = egui_cr_clipboard_set(str : UInt8*)
  fun clipboard_get = egui_cr_clipboard_get : UInt8*
  fun sapp_get_num_dropped_files = sapp_get_num_dropped_files : Int32
  fun sapp_get_dropped_file_path = sapp_get_dropped_file_path(index : Int32) : UInt8*

  # window management (shim: X11 / Win32)
  fun set_window_size = egui_cr_set_window_size(w : Int32, h : Int32)
  fun set_window_position = egui_cr_set_window_position(x : Int32, y : Int32)
  fun set_decorations = egui_cr_set_decorations(decorated : Int32)
  fun set_window_opacity = egui_cr_set_window_opacity(opacity : Float32)
  fun window_position = egui_cr_window_position(x : Int32*, y : Int32*) : Int32
  fun window_drag_start = egui_cr_window_drag_start
  fun window_resize_start = egui_cr_window_resize_start(direction : Int32)
  fun image_alpha_mask = egui_cr_image_alpha_mask(path : UInt8*, w : Int32*,
                                                  h : Int32*) : UInt8*
  fun image_info = egui_cr_image_info(path : UInt8*, w : Int32*,
                                      h : Int32*) : Int32
  fun set_window_shape = egui_cr_set_window_shape(mask : UInt8*, w : Int32,
                                                  h : Int32)
  fun mem_free = egui_cr_mem_free(p : Void*)
  fun window_minimize = egui_cr_window_minimize
  fun window_maximize = egui_cr_window_maximize
  fun window_restore = egui_cr_window_restore
  fun screen_size = egui_cr_screen_size(w : Int32*, h : Int32*)
  fun set_window_icon = egui_cr_set_window_icon(rgba : UInt8*, w : Int32, h : Int32)

  # native file dialogs (shim: Win32 IFileDialog on its own thread; the
  # start/done/result/free handle protocol is polled from a fiber)
  fun file_dialog_start = egui_cr_file_dialog_start(save : Int32, title : UInt16*,
                                                    filter : UInt16*,
                                                    directory : UInt16*,
                                                    file_name : UInt16*) : Void*
  fun file_dialog_done = egui_cr_file_dialog_done(handle : Void*) : Int32
  fun file_dialog_result = egui_cr_file_dialog_result(handle : Void*) : UInt16*
  fun file_dialog_free = egui_cr_file_dialog_free(handle : Void*)

  # sokol_gl (shim wrappers: on the detached path these become packet
  # ops replayed on the render thread; pass-throughs otherwise)
  fun sgl_viewport = egui_cr_sgl_viewport(x : Int32, y : Int32, w : Int32, h : Int32, origin_top_left : Bool)
  fun sgl_matrix_mode_projection = egui_cr_sgl_matrix_mode_projection
  fun sgl_matrix_mode_modelview = egui_cr_sgl_matrix_mode_modelview
  fun sgl_load_identity = egui_cr_sgl_load_identity
  fun sgl_ortho = egui_cr_sgl_ortho(l : Float32, r : Float32, b : Float32, t : Float32, n : Float32, f : Float32)
  fun sgl_scissor_rectf = egui_cr_sgl_scissor_rectf(x : Float32, y : Float32, w : Float32, h : Float32, origin_top_left : Bool)
  fun sgl_begin_quads = egui_cr_sgl_begin_quads
  fun sgl_end = egui_cr_sgl_end
  fun sgl_v2f_c4b = egui_cr_sgl_v2f_c4b(x : Float32, y : Float32, r : UInt8, g : UInt8, b : UInt8, a : UInt8)
  fun sgl_v2f_t2f_c4b = egui_cr_sgl_v2f_t2f_c4b(x : Float32, y : Float32, u : Float32, v : Float32,
                                                r : UInt8, g : UInt8, b : UInt8, a : UInt8)
  # 3D mesh (Viewport3D): one batched SoA mesh under `mvp` (16 floats,
  # column-major) mapped onto the framebuffer-pixel viewport rect;
  # primitive 0 = triangles, 1 = lines. Self-contained: pushes a
  # depth-tested pipeline, draws, and restores the default 2D state.
  fun mesh3d = egui_cr_mesh3d(mvp : Float32*, blend : Bool, primitive : Int32,
                              x : Int32, y : Int32, w : Int32, h : Int32,
                              count : Int32, verts : UInt8*)

  # textures (shim)
  fun make_texture = egui_cr_make_texture(w : Int32, h : Int32, data : UInt8*) : UInt32
  fun make_stream_texture = egui_cr_make_stream_texture(w : Int32, h : Int32) : UInt32
  fun update_texture = egui_cr_update_texture(view_id : UInt32, w : Int32,
                                              h : Int32, data : UInt8*)
  fun destroy_texture = egui_cr_destroy_texture(view_id : UInt32)
  fun sgl_bind_texture = egui_cr_sgl_texture(view_id : UInt32)
  fun sgl_bind_texture_nearest = egui_cr_sgl_texture_nearest(view_id : UInt32)
  fun sgl_enable_texture = egui_cr_sgl_enable_texture
  fun sgl_disable_texture = egui_cr_sgl_disable_texture
  fun load_image = egui_cr_load_image(path : UInt8*) : UInt32

  # text pipeline + glyph atlas (Crystal text stack). Atlases are
  # per-instance: atlas_create returns its own view, atlas_update
  # addresses it by view id — multiple font backends can coexist.
  fun text_pipeline_init = egui_cr_text_pipeline_init
  fun text_pipeline_push = egui_cr_text_pipeline_push
  fun text_pipeline_pop = egui_cr_text_pipeline_pop
  fun alpha_pipeline_push = egui_cr_alpha_pipeline_push
  fun alpha_pipeline_pop = egui_cr_alpha_pipeline_pop
  fun replace_pipeline_push = egui_cr_replace_pipeline_push
  fun replace_pipeline_pop = egui_cr_replace_pipeline_pop
  fun atlas_create = egui_cr_atlas_create(w : Int32, h : Int32, data : UInt8*) : UInt32
  fun atlas_update = egui_cr_atlas_update(view_id : UInt32, w : Int32, h : Int32,
                                          data : UInt8*)

  # cursor (shim): `name` is a CSS cursor keyword
  fun set_cursor = egui_cr_set_cursor(name : UInt8*)
  # cursor (shim): straight-alpha RGBA bitmap cursor (CSS
  # `cursor: url(…)`); (hx, hy) is the hotspot from the top-left
  fun set_cursor_image = egui_cr_set_cursor_image(rgba : UInt8*, w : Int32,
                                                  h : Int32, hx : Int32,
                                                  hy : Int32)
  # decode an image file to a CPU-side straight-alpha RGBA8 buffer
  # (malloc'd — free via #mem_free)
  fun load_rgba = egui_cr_load_rgba(path : UInt8*, w : Int32*, h : Int32*) : UInt8*
end

module Egui
  module Backend
    # The sokol_gfx rendering backend (eframe/glow_integration role).
    module Sokol
      class_getter app : Egui::App?

      @@events = [] of Egui::Event
      @@fonts : Egui::Backend::AtlasFonts?
      # The monospace stack (TextCmd family "monospace"); nil = primary only.
      @@mono_fonts : Egui::Backend::AtlasFonts? = nil
      # Real variant faces of the PRIMARY stack (TextCmd bold/italic
      # flags): registered via select_fonts(bold:/italic:/bold_italic:).
      # nil = that variant isn't installed — the text draws through the
      # base stack's real glyphs (never an emulated variant).
      @@bold_fonts : Egui::Backend::AtlasFonts? = nil
      @@italic_fonts : Egui::Backend::AtlasFonts? = nil
      @@bold_italic_fonts : Egui::Backend::AtlasFonts? = nil
      # THE glyph atlas every stack the backend itself creates bakes
      # into (primary/mono chains + materialized deferred families): one
      # GPU texture, one CPU buffer, regardless of how many font
      # families a font picker flips through. Stacks created by the app
      # (`select_fonts` / `register_font` before #run) keep their own
      # atlas — mixed ownership is fine, each side resets its own.
      @@shared_atlas : GlyphAtlas? = nil
      # Extra named stacks (`Sokol.register_font`) — what a widget group
      # draws through when its style sets `font_family` (see
      # `Context#font_families` / `Fonts` resolution in #fonts_for_cmd).
      @@named_fonts = {} of String => Egui::Backend::AtlasFonts
      # System-scan families not yet loaded (`register_deferred_font`):
      # name → font file paths, materialized on first use. Names came
      # cheap (name-table read only); the parse is paid per pick.
      @@deferred_fonts = {} of String => Array(String)
      # Materialized deferred stacks, memoized by file path — ONE
      # parse per family, shared by the ctx measure side
      # (`Context#font_loader`) and #fonts_for_cmd here. A nil value
      # (unloadable file) is remembered too: no re-parse per frame.
      # Capped by LRU eviction (see #evict_stale_stacks): a font
      # selector walking 1500 families must not accumulate 1500 stacks
      # of .ttf data + glyph caches.
      @@materialized = {} of String => Egui::Backend::AtlasFonts?
      # LRU bookkeeping for the materialized stacks: frame counter and
      # the frame each stack last drew in (see #evict_stale_stacks).
      @@frame_counter = 0_u64
      @@stack_frames = {} of Egui::Backend::AtlasFonts => UInt64
      @@icon : NamedTuple(rgba: Bytes, width: Int32, height: Int32)? = nil
      # On-demand repaint: the last painted command list (re-emitted
      # verbatim on idle frames) and the framebuffer size it matched.
      @@last_commands : Array(Egui::PaintCmd)?
      @@last_fb_w = 0
      @@last_fb_h = 0
      @@start = Time.instant
      @@cursor : Egui::CursorIcon? = nil
      # Last applied bitmap cursor — holds the object alive too, so the
      # buffer pointer #same? dedupes against can't be GC-recycled.
      @@cursor_image : Egui::CustomCursorImage? = nil
      # Last applied scissor (framebuffer px, x/y/w/h) — see #apply_scissor.
      @@last_scissor : Tuple(Float64, Float64, Float64, Float64)? = nil
      # Transparent window mode (run(transparent: true)): clear to
      # alpha 0 and blend UI quads premultiplied.
      @@transparent = false
      # Framebuffer pixels per UI point (retina: 2.0). UI layout and paint
      # commands stay in points; text is rasterized at the physical size.
      @@pixels_per_point : Float64 = 1.0

      # --- frame-flow debug (EGUI_FRAME_DEBUG=1) ------------------------
      # Logs idle/full frame transitions, a heartbeat while idle and
      # input-event counts — enough to tell "the loop stopped calling
      # frames" (C watchdog: OUTSIDE) from "the app decided nothing
      # changed" (idle) from "a frame never finished" (watchdog: INSIDE)
      # when chasing freezes. The C side adds per-phase [loop] lines
      # (x11_events / frame_cb+commit / glx_swap / xflush).
      @@frame_debug : Bool = ENV["EGUI_FRAME_DEBUG"]? ? true : false
      # Win32 detached loop: R's doorbell write end. Pinned in a class var
      # so the GC can never collect (and finalize) the TCPSocket whose fd
      # the shim now owns — run_detached hands it over before #start and
      # C closes it in egui_cr_join.
      {% if flag?(:win32) %}
        @@doorbell_peer : TCPSocket? = nil
      {% end %}
      # Debug-clock epoch (Time::Instant — the monotonic clock has no
      # absolute seconds, only differences; #dbg_now spans from here).
      @@dbg_t0 = Time.instant
      @@dbg_kind : String? = nil
      @@dbg_idle_since : Float64 = 0.0
      @@dbg_beat : Float64 = 0.0
      @@dbg_moves = 0
      @@dbg_last_entry : Float64 = 0.0

      # Seconds on the debug clock (since @@dbg_t0).
      private def self.dbg_now : Float64
        (Time.instant - @@dbg_t0).total_seconds
      end

      private def self.dbg_frame(kind : String, detail : String) : Nil
        return unless @@frame_debug
        now = dbg_now
        if kind != @@dbg_kind
          STDERR.puts "[frame] %8.3f #{kind}  #{detail}" % now
          @@dbg_kind = kind
          @@dbg_idle_since = now if kind == "idle"
          @@dbg_beat = now
        elsif kind == "idle" && now - @@dbg_beat >= 2.0
          STDERR.puts "[frame] %8.3f still idle (%.1fs)  #{detail}" %
            {now, now - @@dbg_idle_since}
          @@dbg_beat = now
        elsif kind == "full" && now - @@dbg_beat >= 5.0
          # A run of full frames is the healthy state while a session
          # is alive — one line per 5 s proves frames keep flowing.
          STDERR.puts "[frame] %8.3f full frames flowing  #{detail}" % now
          @@dbg_beat = now
        end
        @@dbg_moves = 0
      end

      # Client-side chrome (the `chrome:` run option): while the window
      # is borderless, Egui::WindowFrame — the Windows 11 dark-theme
      # look — is drawn before every app frame. `chrome_enabled` is the
      # app's standing choice; `chrome_active` is the per-frame state
      # (follows the decorations toggle at runtime).
      @@title = "egui-cr"
      @@chrome_enabled = false
      @@chrome_active = false
      @@chrome_style : WindowFrame::Style = WindowFrame::Style::Windows

      def self.title : String
        @@title
      end

      def self.title=(title : String) : String
        @@title = title
      end

      def self.chrome_enabled? : Bool
        @@chrome_enabled
      end

      def self.chrome_active? : Bool
        @@chrome_active
      end

      def self.chrome_active=(flag : Bool) : Bool
        @@chrome_active = flag
      end

      def self.chrome_style : WindowFrame::Style
        @@chrome_style
      end

      # Live-switch the client-side frame style (Windows/Ubuntu/Macos).
      def self.chrome_style=(style : WindowFrame::Style) : WindowFrame::Style
        @@chrome_style = style
      end

      # System port Quit → sokol_app `sapp_quit`: closes the window on
      # every backend platform and leaves the run loop.
      class QuitPort < Egui::SystemPorts::Quit::Implementation
        def quit : Nil
          LibEguiCr.request_quit
        end
      end

      # System port Window → sokol_app (title, fullscreen) + shim
      # (resize/move/minimize/maximize: X11 core + _NET_WM_STATE, Win32).
      class WindowPort < Egui::SystemPorts::Window::Implementation
        def set_title(title : String) : Nil
          title.to_unsafe # ensure a contiguous buffer
          LibEguiCr.set_window_title(title.to_unsafe)
          Sokol.title = title # keep the client-side caption in sync
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
          LibEguiCr.toggle_fullscreen
        end

        def fullscreen? : Bool
          LibEguiCr.fullscreen_q != 0
        end

        def set_icon(rgba : Bytes, width : Int32, height : Int32) : Nil
          LibEguiCr.set_window_icon(rgba, width, height)
        end

        # Borderless toggle (shim): X11 _MOTIF_WM_HINTS, Win32 window
        # styles + SWP_FRAMECHANGED, macOS NSWindowStyleMaskTitled.
        # The default client-side chrome follows the state: it shows
        # while the window is borderless and hides when the system
        # frame comes back.
        def set_decorations(decorated : Bool) : Nil
          LibEguiCr.set_decorations(decorated ? 1 : 0)
          Sokol.chrome_active = !decorated && Sokol.chrome_enabled?
        end

        def position : Egui::Vec2?
          x = uninitialized Int32
          y = uninitialized Int32
          return nil if LibEguiCr.window_position(pointerof(x), pointerof(y)) == 0
          Egui::Vec2.new(x.to_f64, y.to_f64)
        end

        # Native move/resize: X11 _NET_WM_MOVERESIZE, Win32
        # WM_NCLBUTTONDOWN, macOS performWindowDrag/ResizeWithEvent:.
        # Direction codes are the X11 convention (0..7), shared by the
        # shim's Win32 HT* mapping.
        RESIZE_EDGES = {:top_left => 0, :top => 1, :top_right => 2,
                        :right => 3, :bottom_right => 4, :bottom => 5,
                        :bottom_left => 6, :left => 7}

        def start_drag : Nil
          LibEguiCr.window_drag_start
          hand_off_release
        end

        def start_resize(edge : Symbol) : Nil
          code = RESIZE_EDGES[edge]?
          if code
            LibEguiCr.window_resize_start(code)
            hand_off_release
          end
        end

        # The native move/resize loop consumes the button release (its
        # own pointer grab), so egui would keep the button "pressed"
        # until the next real click — inject a synthetic release into
        # the next frame's input to close the interaction cleanly.
        private def hand_off_release : Nil
          pos = Egui::Backend::Sokol.last_pointer_pos
          Egui::Backend::Sokol.inject_event(
            Egui::Event.pointer_released(pos))
        end

        # X11 XShape / Win32 SetWindowRgn, built from scanline runs of
        # the opaque mask pixels (see the shim). macOS no-op — the
        # window's own alpha composites natively there.
        def set_shape(mask : Bytes, width : Int32, height : Int32) : Nil
          return if width <= 0 || height <= 0
          LibEguiCr.set_window_shape(mask.to_unsafe, width, height)
        end

        # Whole-window opacity (shim): X11 _NET_WM_WINDOW_OPACITY,
        # Win32 WS_EX_LAYERED + LWA_ALPHA, macOS NSWindow.alphaValue.
        def set_opacity(alpha : Float64) : Nil
          LibEguiCr.set_window_opacity(alpha.clamp(0.0, 1.0).to_f32)
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

      # System port Clipboard → sokol_app set/get clipboard string. The
      # get goes through the shim's mailbox on the detached path (the X
      # connection lives on the render thread) and returns a malloc'd
      # copy that we free after building the String.
      class ClipboardPort < Egui::SystemPorts::Clipboard::Implementation
        # The last text WE set: when the X read fails (a stalled
        # compositor path), fall back to it — the same owner shortcut
        # sapp has (`XGetSelectionOwner == self → return the buffer`).
        @last_set : String? = nil

        def set(text : String) : Nil
          text.to_unsafe # ensure a contiguous buffer
          @last_set = text
          LibEguiCr.clipboard_set(text.to_unsafe)
        end

        def get : String?
          ptr = LibEguiCr.clipboard_get
          return @last_set if ptr.null?
          begin
            String.new(ptr)
          ensure
            LibEguiCr.mem_free(ptr)
          end
        end
      end

      # sapp_event_type values (sokol_app.h)
      KEY_DOWN      =  1
      KEY_UP        =  2
      CHAR          =  3
      MOUSE_DOWN    =  4
      MOUSE_UP      =  5
      MOUSE_SCROLL  =  6
      MOUSE_MOVE    =  7
      RESIZED       = 14
      FILES_DROPPED = 23

      # eframe::run_native — blocks until the window closes.
      #
      # * *icon* — window icon as straight RGBA8 pixels (`width`×
      #   `height`), applied right after the window exists. Win32 only
      #   today (WM_SETICON); a no-op elsewhere.
      # * *decorations* — `false` creates a borderless window (no system
      #   title bar / frame) so the app can draw its own chrome; it can
      #   still be toggled at runtime via SystemPorts::Window.
      # * *transparent* — per-pixel window transparency: pixels left at
      #   alpha 0 show the desktop through (splash screens, custom
      #   chrome). The backdrop is cleared to fully transparent and UI
      #   quads blend into a premultiplied swapchain; on Linux this also
      #   drops MSAA (the ARGB visuals are single-sample).
      # * *chrome* — the client-side frame for a borderless window:
      #   `Egui::WindowFrame` drawn by the backend before every app
      #   frame, including edge resize grips. `nil` (default) = on for
      #   borderless opaque windows, off for transparent ones
      #   (splash-style apps draw their own shape); `false` opts out for
      #   fully custom chrome. A runtime `Window.set_decorations`
      #   toggle shows/hides it in step.
      # * *chrome_style* — which chrome look to draw: Windows 11 dark
      #   (default), Windows XP Luna (blue gradient titlebar + thick
      #   blue frame), Windows XP Silver (same chrome silver-grey,
      #   rose #DFA1A6→#913448 close button), classic Ubuntu Ambiance (gradient +
      #   round orange close) or macOS (traffic lights left, close
      #   first). Switchable live via `Sokol.chrome_style=`.
      # * *inspector* — `:on` enables the runtime widget inspector
      # (right-click any widget → «Inspect»; F12 toggles the bottom
      # panel — see `egui/inspector.cr`) with the panel visible from
      # the start; `:hidden` enables it the same way but starts with
      # the panel closed (invoked via F12 or «Inspect»). Off by
      # default.
      # Decode an image file (PNG/…) into a CPU-side straight-alpha RGBA
      # buffer — the source for `CustomCursorImage` (a GPU texture can't
      # be read back). Returns nil when the file can't be decoded.
      def self.load_rgba(path : String)
        w = uninitialized Int32
        h = uninitialized Int32
        ptr = LibEguiCr.load_rgba(path.to_unsafe, pointerof(w), pointerof(h))
        return nil if ptr.null? || w <= 0 || h <= 0
        size = w * h * 4
        rgba = Bytes.new(size) { |i| ptr[i] }
        LibEguiCr.mem_free(ptr)
        {rgba: rgba, width: w, height: h}
      end

      def self.run(app : Egui::App, title : String = "egui-cr",
                   width : Int32 = 800, height : Int32 = 600,
                   icon : NamedTuple(rgba: Bytes, width: Int32,
                     height: Int32)? = nil,
                   decorations : Bool = true,
                   transparent : Bool = false,
                   chrome : Bool? = nil,
                   chrome_style : WindowFrame::Style = WindowFrame::Style::Windows,
                   inspector : Symbol = :off,
                   vsync : Bool = true) : Nil
        @@app = app
        @@icon = icon
        @@transparent = transparent
        @@title = title
        @@chrome_enabled = chrome.nil? ? !decorations && !transparent : chrome.not_nil!
        @@chrome_active = @@chrome_enabled && !decorations
        @@chrome_style = chrome_style
        if inspector == :on || inspector == :hidden
          app.ctx.inspector_enabled = true
          # :hidden = invocable (F12 / right-click → «Inspect»), panel
          # closed until then.
          app.ctx.inspector.open = false if inspector == :hidden
        else
          app.ctx.inspector_enabled = false
        end
        {% if flag?(:debug) %}
          # The debug-only .ecss style-diff session (see egui/ecss.cr):
          # apps opt in with the `enable_ecss` macro — the methods only
          # exist in debug builds, so release binaries never touch the
          # file system for styles.
          if app.responds_to?(:ecss_app_id)
            Egui::Ecss::Session.enable(app.ctx, app.ecss_app_id)
          end
        {% end %}
        # Framework CLI: pull --page out of ARGV (in place, so the app's
        # own file/flag parsing still works) and deep-link the router.
        # Validation is soft — an unknown page renders the "Page not
        # found" warning page (see Egui::Router).
        cli = Egui::CLI.parse(ARGV)
        if (route = cli[:route])
          app.ctx.router.navigate(route)
        end
        # The native (Win32) icon above + the client-side caption's
        # icon slot show the same pixels.
        Egui::WindowFrame.icon = icon if icon
        Egui::SystemPorts::Quit.use(QuitPort.new)
        Egui::SystemPorts::Window.use(WindowPort.new)
        Egui::SystemPorts::Screen.use(ScreenPort.new)
        Egui::SystemPorts::Clipboard.use(ClipboardPort.new)
        {% if flag?(:win32) %}
          Egui::SystemPorts::Dialogs.use_native_dialogs do |save, title, filters, dir, name|
            native_file_dialog(save, title, filters, dir, name)
          end
        {% end %}

        # Backdrop from the first tick: push the initial theme's panel
        # fill to the backend before the window exists, so the freshly
        # mapped window shows the theme's color (X11: the pre-map
        # background pixel; detached: the render thread's pre-packet
        # clear pass; Win32/macOS legacy: egui_cr_present_clear) instead
        # of an uninitialized black framebuffer during font loading and
        # the first-frame glyph bake.
        bg = app.ctx.style.visuals.panel_fill
        LibEguiCr.set_clear_color(
          bg.r.to_f32 / 255.0f32, bg.g.to_f32 / 255.0f32,
          bg.b.to_f32 / 255.0f32, bg.a.to_f32 / 255.0f32)

        init = -> { on_init }
        frame = -> { on_frame }
        event = ->(t : Int32, mx : Float32, my : Float32, sx : Float32, sy : Float32, mods : UInt32, btn : UInt32, key : UInt32, chr : UInt32) {
          translate_event(t, mx, my, sx, sy, mods, btn, key, chr,
            Pointer(Void).null)
        }
        cleanup = -> { }

        # Keep proc objects referenced (GC) and enter the sapp loop.
        @@cbs = {init, frame, event, cleanup}

        # Linux/Win32: the detached render loop (loop_redesign.md) —
        # sokol's window/GL/swap cycle runs on a C thread while THIS
        # thread keeps the Crystal scheduler, producing FramePackets.
        # Disable with EGUI_RENDER_THREAD=0 (bisecting / regression
        # hunting). macOS stays on the legacy loop: AppKit requires the
        # process main thread, which is where the Crystal scheduler
        # lives (see loop_redesign.md §8).
        {% if flag?(:linux) || flag?(:win32) %}
          if ENV["EGUI_RENDER_THREAD"]? != "0"
            run_detached(title, width, height, decorations, transparent,
              vsync)
            return
          end
        {% end %}

        LibEguiCr.sapp_run(init, frame, event, cleanup, title.to_unsafe,
          width, height, decorations ? 0 : 1, transparent ? 1 : 0,
          vsync ? 1 : 0)
      end

      {% if flag?(:linux) || flag?(:win32) %}
        # The main-thread half of the detached loop: block on the
        # doorbell (an evented read — the scheduler keeps serving PTY
        # readers and dialog fibers while we wait), translate input from
        # the event ring, and produce frames into the packet mailbox
        # whenever input / repaint requests / texture evictions demand
        # one. The render thread replays the last packet on its own, so
        # idle frames need no work here at all.
        private def self.run_detached(title : String, width : Int32,
                                      height : Int32, decorations : Bool,
                                      transparent : Bool,
                                      vsync : Bool) : Nil
          handle : Int64
          {% if flag?(:win32) %}
            # Win32 doorbell: the C-made loopback pair's A end can't be
            # adopted by Crystal's IOCP scheduler — an evented read on it
            # never completes (INIT sat in the socket buffer forever:
            # black window). Create the pair Crystal-side instead: the
            # accepted socket is IOCP-native, and its peer fd becomes R's
            # write end (plain send(), no overlapped needed there).
            server = TCPServer.new("127.0.0.1", 0)
            @@doorbell_peer = TCPSocket.new("127.0.0.1",
              server.local_address.port)
            pipe = server.accept
            server.close
            LibEguiCr.doorbell_set_peer(@@doorbell_peer.not_nil!.fd.to_i64!)
            handle = LibEguiCr.start(title.to_unsafe, width, height,
              decorations ? 0 : 1, transparent ? 1 : 0, vsync ? 1 : 0)
            return if handle < 0
            # A's end for the C-side non-blocking drains (FIONREAD + recv).
            handle = pipe.fd.to_i64!
          {% else %}
            handle = LibEguiCr.start(title.to_unsafe, width, height,
              decorations ? 0 : 1, transparent ? 1 : 0, vsync ? 1 : 0)
            return if handle < 0
            pipe = IO::FileDescriptor.new(handle.to_i32)
          {% end %}
          Egui::Runtime.natural_scheduler = true
          Egui::Runtime.wake = ->{ LibEguiCr.wake_main }
          doorbell = Bytes.new(256)
          records = Pointer(LibEguiCr::EventRecord).malloc(64)

          # The render thread signals INIT once the window + GL context
          # exist (the C-side init does sg/sgl setup — GL work belongs
          # to R). Only then may Crystal build fonts and draw.
          until drain_pipe_once(pipe, doorbell) == :init
            # (blocks inside; a QUIT here means the window died at birth)
          end
          on_init_detached

          app = @@app.not_nil!
          # Frame pacing: production is paced by the render thread's
          # present-acks (one wake byte per presented frame — the FPS
          # reads the display rate, like the legacy loop ticked by its
          # own swap). While a repaint run is active but acks starve
          # (swap stall, occluded window), a 60 Hz fallback keeps
          # app.update/PTY running; input doorbells always produce
          # immediately.
          fallback = 1.0 / 60.0
          last_produce = Time.instant - 1.second
          busy = false
          {% if flag?(:win32) %}
            # Win32: the doorbell read must NOT carry a read timeout.
            # Crystal 1.21's IOCP runtime cancels a timed-out overlapped
            # read with CancelIoEx, but when the completion slipped in
            # just before the cancel (ERROR_NOT_FOUND) it does not wait
            # for the already-queued completion packet — the fiber-stack
            # OVERLAPPED is then reused by the next read while the OS
            # still holds it. The stale packet later reaches the IOCP
            # forwarder thread, which panics the process
            # ("PostQueuedCompletionStatus failed … ERROR_INVALID_HANDLE",
            # silent exit seconds into a busy frame run). Same class of
            # race as the C-side drain one below (drain_doorbells_raw).
            # So the read below is untimed, and the 60 Hz fallback
            # deadline is served by this watchdog fiber: it sleeps until
            # the deadline the main loop armed and injects a tag-5
            # doorbell byte through the peer socket (untimed one-byte
            # write; like the ack/event tags, 5 is ignored by the loop
            # and only serves as a wake).
            fallback_mu = Thread::Mutex.new
            fallback_due : Time::Instant? = nil
            spawn do
              peer = @@doorbell_peer.not_nil!
              loop do
                due = fallback_mu.synchronize { fallback_due }
                nap = due ? due - Time.instant : 50.milliseconds
                if nap > Time::Span::ZERO
                  sleep(nap)
                else
                  fallback_mu.synchronize { fallback_due = nil }
                  begin
                    peer.write(Bytes[5_u8])
                  rescue IO::Error | Socket::Error
                    # R is gone — the main read returns 0 and the loop exits
                  end
                end
              end
            end
          {% end %}
          loop do
            # Wait for a doorbell: indefinitely when nothing is pending,
            # until the fallback deadline while a repaint run is active.
            {% if flag?(:win32) %}
              fallback_mu.synchronize do
                fallback_due = busy ? last_produce + fallback.seconds : nil
              end
              n = pipe.read(doorbell)
              break if n.zero?                          # R died
              break if doorbell[0, n].includes?(3_u8)    # QUIT
            {% else %}
              wait = busy ? (last_produce + fallback.seconds - Time.instant) : 1.hour
              pipe.read_timeout = {wait, 1.millisecond}.max
              begin
                n = pipe.read(doorbell)
                break if n.zero?                          # R died
                break if doorbell[0, n].includes?(3_u8)    # QUIT
              rescue IO::TimeoutError
                # no ack in the fallback window — produce anyway below
              end
            {% end %}
            # Keep doorbells from filling the pipe during busy runs.
            break if drain_doorbells_raw(handle, doorbell)
            drain_events(records)
            if frame_pending?(app)
              last_produce = Time.instant
              produce_frame
              busy = app.ctx.needs_repaint?
            else
              busy = false
              dbg_frame("idle", "moves=#{@@dbg_moves} repaint=#{app.ctx.needs_repaint?}")
            end
          end
          LibEguiCr.join
        end

        # One blocking read of the doorbell; returns the highest tag seen
        # this pass (nil when nothing arrived / the handle closed).
        private def self.drain_pipe_once(pipe : IO, buf : Bytes) : Symbol?
          n = pipe.read(buf)
          return nil if n.zero?
          tag = nil
          n.times do |i|
            case buf[i]
            when 2 then tag = :init
            when 3 then tag = :quit
            end
          end
          tag
        end

        # Raw non-blocking drain loop: while producing frames back-to-back
        # the blocking #read never runs, so doorbell bytes would pile up
        # and eventually silence R's writes.
        # Win32 exception: the drain's plain recv() on the IOCP-registered
        # socket races Crystal's overlapped reads (a stale OVERLAPPED
        # completion then panics the IOCP forwarder thread — silent exit
        # after seconds). The loop's own #read consumes every pending byte
        # each iteration there anyway (TCP buffer pressure is not a
        # concern at ~60 one-byte acks/s), so the C drain stays off.
        private def self.drain_doorbells_raw(handle : Int64, buf : Bytes) : Bool
          {% if flag?(:win32) %}
            false
          {% else %}
            quit = false
            loop do
              n = LibEguiCr.doorbell_drain(handle, buf, buf.size)
              break if n <= 0
              quit = true if buf[0, n].includes?(3_u8)
            end
            quit
          {% end %}
        end

        # True when the event ring / repaint flags / texture evictions
        # or a resize make a new frame necessary. Idle frames are R's
        # business alone (it replays the last packet every tick).
        private def self.frame_pending?(app : Egui::App) : Bool
          return true unless @@events.empty?
          return true if app.ctx.needs_repaint?
          return true if app.ctx.textures.pending_destroys?
          return true if Egui::SystemPorts::AsyncDialogs.take_delivered > 0
          LibEguiCr.sapp_width != @@last_fb_w ||
            LibEguiCr.sapp_height != @@last_fb_h
        end

        # Pop the render thread's event ring into @@events through the
        # shared translation (same code the legacy callback used).
        private def self.drain_events(records : Pointer(LibEguiCr::EventRecord)) : Nil
          while (n = LibEguiCr.events_pop(records, 64)) > 0
            n.times do |i|
              r = records[i]
              translate_event(r.type, r.mx, r.my, r.sx, r.sy, r.mods,
                r.mouse_button, r.key_code, r.char_code, r.payload)
            end
          end
        end

        # #on_init minus the GL setup (the render thread's init callback
        # owns sg/sgl/pipelines on the detached path).
        private def self.on_init_detached : Nil
          on_init(skip_gl: true)
        end

        # The frame production half of the loop: input → update →
        # tessellate → publish. Painting is #paint_frame unchanged —
        # every draw call it makes lands in the packet builder instead
        # of GL (see the shim's routing).
        private def self.produce_frame : Nil
          dbg_frame("full", "events=#{@@events.size} moves=#{@@dbg_moves}")
          frame_t0 = Time.instant if @@frame_debug

          ppp = LibEguiCr.sapp_dpi_scale.to_f64
          @@pixels_per_point = ppp > 0.0 ? ppp : 1.0
          LibEguiCr.set_ppp(@@pixels_per_point.to_f32)
          set_stack_scales
          fb_w = LibEguiCr.sapp_width
          fb_h = LibEguiCr.sapp_height

          app = @@app.not_nil!
          app.ctx.pixels_per_point = @@pixels_per_point

          time = (Time.instant - @@start).total_seconds
          raw = Egui::RawInput.new(
            Egui::Rect.from_min_size(Egui::Pos2.zero,
              Egui::Vec2.new(fb_w.to_f64 / @@pixels_per_point,
                fb_h.to_f64 / @@pixels_per_point)),
            @@events, time)
          @@events = [] of Egui::Event

          app.ctx.begin_frame(raw)
          app.ctx.inspector.before_update if app.ctx.inspector_enabled?
          Egui::WindowFrame.show(app.ctx, @@title, @@chrome_style) if @@chrome_active
          app.update(app.ctx)
          commands = app.ctx.end_frame

          @@last_commands = commands
          @@last_fb_w = fb_w
          @@last_fb_h = fb_h

          paint_frame(app.ctx, fb_w, fb_h, commands, touch_fonts: true)

          if (t0 = frame_t0) &&
             (ms = (Time.instant - t0).total_milliseconds) > 100.0
            STDERR.puts "[frame] %8.3f SLOW full frame: %.0fms" %
              {dbg_now, ms}
          end
        end
      {% end %}

      # Win32 IFileDialog through the shim: the picker runs on its own
      # thread (own STA); this fiber sleep-polls it, so the scheduler
      # keeps serving the frame loop while the dialog is open — the
      # AsyncDialogs contract. Nil when the thread failed to start or
      # the user cancelled (empty path).
      private def self.native_file_dialog(save : Bool, title : String,
                                          filters : Array(String),
                                          directory : String?,
                                          default_name : String?) : String?
        # "name\0pattern\0" pairs, double-NUL terminated (shim format).
        filter = String.build do |s|
          unless filters.empty?
            pats = filters.join(";")
            s << "Files (#{pats})\0#{pats}\0"
          end
          s << "All files\0*.*\0"
        end
        handle = LibEguiCr.file_dialog_start(
          save ? 1 : 0,
          title.to_utf16, filter.to_utf16,
          (directory || "").to_utf16, (default_name || "").to_utf16)
        return nil if handle.null?
        begin
          until LibEguiCr.file_dialog_done(handle) != 0
            sleep 15.milliseconds
          end
          ptr = LibEguiCr.file_dialog_result(handle)
          len = 0
          while ptr[len] != 0
            len += 1
          end
          len.zero? ? nil : String.from_utf16(Slice.new(ptr, len))
        ensure
          LibEguiCr.file_dialog_free(handle)
        end
      end

      protected def self.on_init(skip_gl : Bool = false) : Nil
        # sg_setup + sgl_setup + the text pipelines are GL work: on the
        # detached path they belong to the render thread's init callback
        # (already run by the time we get here).
        unless skip_gl
          LibEguiCr.gfx_init
          LibEguiCr.text_pipeline_init
          # Present the backdrop before anything heavy runs (font
          # parsing, first app update + glyph bake): the mapped window
          # must not sit on an uninitialized framebuffer for the whole
          # startup. No-op on the detached path — the render thread
          # clears every pre-packet tick.
          LibEguiCr.present_clear
        end
        # Window icon first thing after the window exists (taskbar and
        # caption pick it up before the first paint).
        if (icon = @@icon) && !icon[:rgba].empty?
          Egui::SystemPorts::Window.set_icon(icon[:rgba], icon[:width], icon[:height])
        end
        app = @@app.not_nil!
        # Font backend: prefer FreeType (real hinting), fall back to the
        # built-in monospace stub. Candidates come from the Fonts system
        # port (per-platform). A font installed via select_fonts BEFORE
        # run (e.g. an app's monospace face) wins — don't clobber it
        # with the default.
        if (preselected = @@fonts)
          app.ctx.fonts = preselected
        else
          font_paths = Egui::SystemPorts::Fonts.search_paths
          if font = fonts_from_system(font_paths, shared_atlas)
            @@fonts = font
            app.ctx.fonts = font
          else
            STDERR.puts "egui-cr: no system font found (tried #{font_paths.first} …)"
            app.ctx.fonts = Egui::MonospaceFonts.new
          end
        end
        # Named stacks registered before #run land in the Context now.
        @@named_fonts.each do |name, fonts|
          app.ctx.register_font_family(name, fonts)
        end
        # System font families: names from a cheap name-table scan (no
        # font parsing at startup — see SystemPorts::Fonts), the stacks
        # themselves deferred until a family is first picked. The ctx
        # measure side and the draw side share one materialized stack
        # per family through materialize_font's memo.
        app.ctx.font_loader = ->(paths : Array(String)) : Egui::Fonts? {
          materialize_font(paths)
        }
        # Cut stacks (the CSS weight axis) register at runtime, long
        # after this scan — route them into the backend registry too
        # so TextCmds naming them resolve (see Context#cut_stack).
        app.ctx.font_register = ->(name : String, paths : Array(String)) {
          register_deferred_font(name, paths)
        }
        Egui::SystemPorts::Fonts.installed_families.each do |name, path|
          next if @@named_fonts.has_key?(name) ||
                  @@deferred_fonts.has_key?(name)
          register_deferred_font(name, [path])
        end
        app.ctx.textures = SokolTextureRegistry.new
      end

      # Default font-backend chain, shared by on_init, examples and
      # benches: the freetype-cr port (pure Crystal, what release
      # ships). Dev builds with C_EXTENSIONS enabled accelerate through
      # the C-FFI FreeType first — same glyphs, faster bake under debug
      # codegen. `atlas` = the registry's shared glyph atlas (nil —
      # default — bakes into a private atlas: specs, standalone tools).
      def self.fonts_from_system(paths : Array(String),
                                 atlas : GlyphAtlas? = nil) : AtlasFonts?
        {% if Egui::Backend::C_EXTENSIONS %}
          FreetypeFonts.from_system(paths, atlas) ||
            CrystalFonts.from_system(paths, atlas)
        {% else %}
          CrystalFonts.from_system(paths, atlas)
        {% end %}
      end

      # The one glyph atlas the backend's own stacks bake into (see
      # @@shared_atlas) — created lazily so a headless use of this
      # module (specs) never allocates the 16 MiB buffer.
      private def self.shared_atlas : GlyphAtlas
        @@shared_atlas ||= GlyphAtlas.new(ATLAS_SIZE)
      end

      # Every stack the registry knows: the primary/mono/variant slots,
      # the app-registered named stacks and every materialized deferred
      # family. What the registry-level atlas reset and the per-frame
      # scale sync iterate.
      private def self.all_stacks : Array(Egui::Backend::AtlasFonts)
        ([@@fonts, @@mono_fonts, @@bold_fonts, @@italic_fonts,
          @@bold_italic_fonts].concat(@@named_fonts.values)
          .concat(@@materialized.values.compact)).compact
      end

      # Swap the active font backend at runtime (e.g. a preview app
      # toggling between the C FreeType and the Crystal port). The new
      # backend's atlas is uploaded and bound on the next frame.
      # `mono:` optionally installs a SECOND stack (Context#mono_fonts)
      # for TextCmd family "monospace" — terminal grids, code. Nil
      # (default) keeps mono text on the primary stack.
      # `bold:`/`italic:`/`bold_italic:` install the primary stack's REAL
      # variant faces (Context#bold_fonts & co) — what TextCmd bold /
      # italic flags draw and measure through. A nil variant is no
      # emulation: the base stack's real glyphs serve the text.
      def self.select_fonts(font : AtlasFonts, mono : AtlasFonts? = nil,
                            bold : AtlasFonts? = nil,
                            italic : AtlasFonts? = nil,
                            bold_italic : AtlasFonts? = nil) : Nil
        @@fonts = font
        @@mono_fonts = mono
        @@bold_fonts = bold
        @@italic_fonts = italic
        @@bold_italic_fonts = bold_italic
        app = @@app
        return unless app
        app.ctx.fonts = font
        app.ctx.mono_fonts = mono
        app.ctx.bold_fonts = bold
        app.ctx.italic_fonts = italic
        app.ctx.bold_italic_fonts = bold_italic
      end

      # Register a NAMED font stack (`Context#font_families`): a widget
      # group whose style sets `font_family: name` measures and draws
      # through it. Callable before #run (the name lands in the class
      # registry here and in the Context once the app exists). The
      # names "monospace" and "system" are reserved — they install the
      # mono/primary slots instead of an extra stack.
      def self.register_font(name : String, fonts : AtlasFonts) : Nil
        @@named_fonts[name] = fonts
        @@app.try &.ctx.register_font_family(name, fonts)
      end

      # Register a system-scan family: the NAME lands in the catalogs
      # now (Context#deferred_font_paths / #font_family_catalog and the
      # backend's own registry); the stack parses on first use. The
      # reserved names are not deferrable.
      def self.register_deferred_font(name : String, paths : Array(String)) : Nil
        return if name == "system" || name == "monospace"
        @@deferred_fonts[name] = paths
        @@app.try &.ctx.register_deferred_font(name, paths)
      end

      # Materialize a deferred family's stack through the standard
      # backend chain, memoized per file (see @@materialized) and baked
      # into the registry's shared glyph atlas. Evictable by LRU (see
      # #evict_stale_stacks) — a re-pick simply re-parses the file.
      private def self.materialize_font(paths : Array(String)) : Egui::Backend::AtlasFonts?
        key = paths.first? || return nil
        unless @@materialized.has_key?(key)
          @@materialized[key] = fonts_from_system(paths, shared_atlas)
        end
        @@materialized[key]
      end

      # The stack a TextCmd's family resolves to (the backend twin of
      # `Context#fonts_for`): nil or the reserved "system" → primary,
      # "monospace" → the mono stack, a registered name → that stack,
      # a deferred name → its materialized stack (loaded right here on
      # first draw), anything else → primary (a typo degrades to the
      # default). The primary then shifts to a REAL variant face when
      # the cmd is bold/italic and one is installed (nil variants are
      # no emulation — the base stack's own glyphs serve the text).
      private def self.fonts_for_cmd(cmd : Egui::TextCmd) : AtlasFonts?
        stack = case family = cmd.family
                when nil
                  @@fonts
                when "monospace"
                  # select_fonts installs the mono SLOT; register_font may
                  # instead register "monospace" as a NAMED family — honor
                  # both before degrading to the primary face.
                  @@mono_fonts || @@named_fonts["monospace"]? || @@fonts
                when "system"
                  @@fonts
                else
                  if (named = @@named_fonts[family]?)
                    named
                  elsif (paths = @@deferred_fonts[family]?)
                    if (real = materialize_font(paths))
                      @@named_fonts[family] = real
                      real
                    else
                      @@deferred_fonts.delete(family)
                      @@fonts
                    end
                  else
                    @@fonts
                  end
                end
        # Variant faces exist for the PRIMARY stack only: named stacks
        # (fontbrowser rows, app-registered families) are exact files
        # and draw as loaded, whatever flags the run carries.
        return stack unless stack.same?(@@fonts) || stack.nil?
        if cmd.bold? && cmd.italic?
          @@bold_italic_fonts || @@bold_fonts || @@italic_fonts || stack
        elsif cmd.bold?
          @@bold_fonts || stack
        elsif cmd.italic?
          @@italic_fonts || stack
        else
          stack
        end
      end

      # Last pointer position reported to egui (window-local points);
      # zero before any pointer event. Ports use it when they need to
      # synthesize input (see WindowPort#hand_off_release).
      def self.last_pointer_pos : Egui::Pos2
        @@app.try &.ctx.input.pointer_pos || Egui::Pos2.zero
      end

      # 8-bit alpha mask of an image file (255 = opaque pixel), the
      # input for SystemPorts::Window.set_shape (e.g. the splash PNG).
      # Nil when the file cannot be decoded. The C-side buffer is
      # copied into a Crystal Bytes and freed.
      def self.image_alpha_mask(path : String) : NamedTuple(mask: Bytes, width: Int32, height: Int32)?
        w = uninitialized Int32
        h = uninitialized Int32
        ptr = LibEguiCr.image_alpha_mask(path.to_unsafe, pointerof(w), pointerof(h))
        return nil unless ptr
        count = (w.to_i64 * h.to_i64).to_i32
        mask = Bytes.new(count) { |i| ptr[i] }
        LibEguiCr.mem_free(ptr)
        {mask: mask, width: w, height: h}
      end

      # Queue a synthetic input event for the next frame's RawInput
      # (ports that take over the event stream — native window drags —
      # use it to close interactions the platform no longer reports).
      def self.inject_event(event : Egui::Event) : Nil
        @@events << event
      end

      protected def self.on_event(type : Int32, mx : Float32, my : Float32,
                                  sx : Float32, sy : Float32, mods : UInt32,
                                  btn : UInt32, key : UInt32,
                                  chr : UInt32) : Nil
        translate_event(type, mx, my, sx, sy, mods, btn, key, chr, nil)
      end

      # sokol event tuple → Egui::Event, shared by the legacy callback
      # (#on_event) and the detached loop's ring drain (#drain_events).
      # `payload` carries the dropped-files path list on the detached
      # path; nil on legacy (the paths are queried through sapp then).
      protected def self.translate_event(type : Int32, mx : Float32,
                                         my : Float32, sx : Float32,
                                         sy : Float32, mods : UInt32,
                                         btn : UInt32, key : UInt32,
                                         chr : UInt32,
                                         payload : Void*) : Nil
        # sokol reports pointer positions in framebuffer pixels (macOS
        # multiplies by the backing scale); the UI works in points
        # (sapp_width), like upstream egui's pixels_per_point conversion.
        if (scale = LibEguiCr.sapp_dpi_scale) > 1.0f32
          mx /= scale
          my /= scale
        end
        if @@frame_debug && type != MOUSE_MOVE
          STDERR.puts "[event] %8.3f type=#{type} btn=#{btn} key=#{key} chr=#{chr}" %
            dbg_now
        end
        case type
        when MOUSE_MOVE
          @@dbg_moves += 1 if @@frame_debug
          @@events << Egui::Event.pointer_moved(Egui::Pos2.new(mx, my))
        when MOUSE_DOWN
          # sapp mouse_button: 0 = left, 1 = right, 2 = middle.
          # Secondary presses drive context menus
          # (Response#context_menu); middle is dropped here (no
          # middle-click behavior yet).
          button = btn == 1 ? PointerButton::Secondary : PointerButton::Primary
          @@events << Egui::Event.pointer_pressed(Egui::Pos2.new(mx, my), button)
        when MOUSE_UP
          button = btn == 1 ? PointerButton::Secondary : PointerButton::Primary
          @@events << Egui::Event.pointer_released(Egui::Pos2.new(mx, my), button)
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
          # Control chars (including DEL) are dropped as well: the macOS
          # keyDown path reports Enter/Backspace here as \r / \x7F while
          # the KEY_DOWN event already carries them (win32/x11 filter
          # these out) — keeping the text copy would make focused
          # consumers like the terminal double-fire the key.
          if (chr >= 0x20 && chr != 0x7F && chr < 0xD800) ||
             (chr >= 0xE000 && chr < 0x110000)
            @@events << Egui::Event.text_input(chr.unsafe_chr.to_s)
          end
        when FILES_DROPPED
          if payload
            # Detached path: the render thread copied the paths out of
            # sokol's drop buffer; layout is {int count; char* paths[8]}.
            count = payload.as(Int32*).value
            base = (payload.as(UInt8*) + 8).as(Pointer(Pointer(UInt8)))
            paths = Array(String).new(count) do |i|
              p = base[i]
              p ? String.new(p) : ""
            end
            @@events << Egui::Event.dropped_files(paths)
            {% if flag?(:linux) || flag?(:win32) %}
              LibEguiCr.drop_payload_free(payload)
            {% end %}
          else
            # sokol_app collects the paths before the event fires; query
            # them through the sapp drop API (valid until the next drop).
            count = LibEguiCr.sapp_get_num_dropped_files
            paths = Array(String).new(count) do |i|
              ptr = LibEguiCr.sapp_get_dropped_file_path(i)
              ptr ? String.new(ptr) : ""
            end
            @@events << Egui::Event.dropped_files(paths)
          end
        when RESIZED
          # screen_rect is rebuilt from sapp_width/height each active
          # frame; the event just marks the frame non-idle.
          @@events << Egui::Event.new(:window_resized)
        end
      end

      protected def self.on_frame : Nil
        # Advance async system ports (file dialogs) — one bounded
        # scheduler pass, then deliver completed requests. Must run
        # before begin_frame so callbacks land in a stable frame state.
        Egui::SystemPorts::AsyncDialogs.pump_pass
        # Same slot for native reader fibers (PTY sessions) — nil (a
        # no-op) unless backend/pty was required, and a no-op under the
        # detached loop where the scheduler runs naturally.
        Egui::Runtime.frame_scheduler_pass.try &.call
        delivered = Egui::SystemPorts::AsyncDialogs.take_delivered

        if @@frame_debug
          # Wall-clock gap between on_frame entries: anything way over
          # the vsync period (~16 ms) is time spent OUTSIDE Crystal —
          # sapp_commit / glXSwapBuffers / X11 stall (sokol swaps after
          # frame_cb returns).
          now = dbg_now
          if (@@dbg_last_entry > 0.0) &&
             (gap = now - @@dbg_last_entry) > 0.15
            STDERR.puts "[frame] %8.3f frame GAP %.0fms (swap/C-loop stall)" %
              {now, gap * 1000.0}
          end
          @@dbg_last_entry = now
        end

        ppp = LibEguiCr.sapp_dpi_scale.to_f64
        @@pixels_per_point = ppp > 0.0 ? ppp : 1.0
        set_stack_scales
        fb_w = LibEguiCr.sapp_width
        fb_h = LibEguiCr.sapp_height

        app = @@app.not_nil!
        # Raster caches (Svg textures — the font-atlas analogue) bake
        # at the physical pixel scale, like AtlasFonts#scale above.
        app.ctx.pixels_per_point = @@pixels_per_point

        # On-demand repaint: sokol_app's loop swaps every vsync tick
        # regardless, but an idle frame (no events, no repaint request,
        # nothing animating, same window size, no dialog just delivered)
        # skips app.update + tessellation and simply re-emits the last
        # paint commands — the visuals are identical, the CPU cost is
        # not. Any input, resize or dialog callback switches right back
        # to a full frame.
        if (cache = @@last_commands) &&
           delivered.zero? && @@events.empty? && !app.ctx.needs_repaint? &&
           !app.ctx.textures.pending_destroys? &&
           fb_w == @@last_fb_w && fb_h == @@last_fb_h
          dbg_frame("idle", "moves=#{@@dbg_moves} repaint=#{app.ctx.needs_repaint?}")
          paint_frame(app.ctx, fb_w, fb_h, cache, touch_fonts: false)
          return
        end
        dbg_frame("full", "events=#{@@events.size} moves=#{@@dbg_moves} repaint=#{app.ctx.needs_repaint?} delivered=#{delivered}")
        frame_t0 = Time.instant if @@frame_debug

        time = (Time.instant - @@start).total_seconds
        raw = Egui::RawInput.new(
          Egui::Rect.from_min_size(Egui::Pos2.zero,
            Egui::Vec2.new(fb_w.to_f64 / @@pixels_per_point,
              fb_h.to_f64 / @@pixels_per_point)),
          @@events, time)
        @@events = [] of Egui::Event

        app.ctx.begin_frame(raw)
        # The inspector panel bites the bottom edge FIRST (before the
        # chrome bar and the app's panels) so it sits under everything.
        app.ctx.inspector.before_update if app.ctx.inspector_enabled?
        # Default client-side chrome first: the caption is a top panel,
        # so the app's own panels land below it.
        Egui::WindowFrame.show(app.ctx, @@title, @@chrome_style) if @@chrome_active
        app.update(app.ctx)
        # Inspector overlays (pick menu, color popup, selection frame)
        # run inside #end_frame — AFTER the deferred central panel, so a
        # widget's context menu opened there has already claimed the
        # press and the inspector yields to it (no second popup; the
        # «Inspect …» row rides as that menu's last item instead).
        commands = app.ctx.end_frame

        @@last_commands = commands
        @@last_fb_w = fb_w
        @@last_fb_h = fb_h

        paint_frame(app.ctx, fb_w, fb_h, commands, touch_fonts: true)

        if (t0 = frame_t0) &&
           (ms = (Time.instant - t0).total_milliseconds) > 100.0
          # The whole slow frame, phase by phase. On the legacy path the
          # swap happens right after this callback returns — a slow
          # frame here plus a frame GAP line at the next entry means the
          # present path, not the app.
          STDERR.puts "[frame] %8.3f SLOW full frame: %.0fms" % {dbg_now, ms}
        end
      end

      # measure() must see the draw-path ppem (see AtlasFonts#scale) —
      # set it before begin_frame so this frame's layout agrees with
      # what paint_text will actually emit. Every stack that can draw
      # this frame, named ones included, plus the deferred stacks
      # materialized so far (they reach @@named_fonts only once a
      # TextCmd resolves to them — a family only MEASURED still needs
      # the right scale).
      private def self.set_stack_scales : Nil
        [@@fonts, @@mono_fonts, @@bold_fonts, @@italic_fonts,
          @@bold_italic_fonts].concat(@@named_fonts.values)
          .concat(@@materialized.values.compact).each do |f|
          f.try &.scale = @@pixels_per_point
        end
      end

      # Emit a frame to the GPU. `touch_fonts` is false on idle frames —
      # the cached commands reference glyphs that are already in the
      # atlas, so no rasterization/upload work is needed.
      private def self.paint_frame(ctx : Egui::Context, fb_w : Int32,
                                   fb_h : Int32,
                                   commands : Array(Egui::PaintCmd),
                                   touch_fonts : Bool) : Nil
        # The scissor dedupe is per-frame: on the detached path every
        # packet is replayed from a fresh sgl state, so the first clip
        # of each frame must always be emitted.
        @@last_scissor = nil
        # egui `PlatformOutput::cursor_icon` / `cursor_image`: apply
        # whichever changed — a bitmap cursor wins over the CSS keyword,
        # which the shim maps onto the platform cursors (Xcursor theme
        # / Win32 IDC_*). Both sides dedupe (buffer identity here, bytes
        # in the shim), so re-pushing the same request is free.
        if (image = ctx.cursor_image)
          unless @@cursor_image.try &.same?(image)
            @@cursor_image = image
            LibEguiCr.set_cursor_image(image.rgba.to_unsafe, image.width,
              image.height, image.hotspot_x, image.hotspot_y)
          end
          # Force the icon path to re-apply once the bitmap goes away
          # (the egui-winit `current_cursor_icon` resync contract).
          @@cursor = nil
        else
          @@cursor_image = nil
          icon = ctx.cursor_icon
          if icon != @@cursor
            @@cursor = icon
            LibEguiCr.set_cursor(icon.to_css.to_unsafe)
          end
        end

        w = fb_w.to_f64 / @@pixels_per_point
        h = fb_h.to_f64 / @@pixels_per_point
        # Backdrop follows the theme (its base surface color) so edges
        # never flash the stale palette after a theme swap — except in a
        # transparent window, where the backdrop is fully transparent
        # and the swapchain alpha becomes the window alpha.
        if @@transparent
          LibEguiCr.set_clear_color(0.0f32, 0.0f32, 0.0f32, 0.0f32)
        else
          bg = ctx.style.visuals.panel_fill
          LibEguiCr.set_clear_color(
            bg.r.to_f32 / 255.0f32, bg.g.to_f32 / 255.0f32,
            bg.b.to_f32 / 255.0f32, bg.a.to_f32 / 255.0f32)
        end

        # Rasterize every glyph this frame's text needs (at the PHYSICAL
        # pixel size — see paint_text) and upload the atlas BEFORE the
        # render pass — sg_update_image is illegal inside a pass. An
        # overflowed atlas (font-size drags bake a glyph set per
        # fractional size) is wiped and re-baked here, so the pass never
        # rasterizes and no glyph stays blank-cached. Commands are
        # grouped per stack in ONE pass (fonts_for_cmd resolves — and on
        # first use materializes — the family of every command anyway).
        if touch_fonts
          @@frame_counter += 1
          by_stack = {} of Egui::Backend::AtlasFonts => Array(Egui::TextCmd)
          commands.each do |cmd|
            next unless cmd.is_a?(Egui::TextCmd)
            next unless stack = fonts_for_cmd(cmd)
            (by_stack[stack] ||= [] of Egui::TextCmd) << cmd
          end
          by_stack.each do |stack, cmds|
            cmds.each { |cmd| stack.touch(cmd, @@pixels_per_point) }
            @@stack_frames[stack] = @@frame_counter
          end
          # Registry-level overflow recovery. Every stack here bakes
          # into ONE shared atlas, so a reset by any stack invalidates
          # EVERYONE's cached UVs: reset the atlas once (the epoch bump
          # makes each stack drop its glyph cache lazily, in #glyph),
          # acknowledge the flags, then re-touch ALL of this frame's
          # text — not just the overflowing stack's slice. Stacks on a
          # private atlas (app-registered before #run) keep the local
          # reset_if_full semantics.
          if by_stack.keys.any?(&.needs_reset?)
            if (shared = @@shared_atlas)
              shared.reset
              all_stacks.each do |stack|
                if stack.atlas.same?(shared)
                  stack.clear_overflow_flag
                else
                  stack.reset_if_full
                end
              end
            else
              by_stack.each_key(&.reset_if_full)
            end
            by_stack.each do |stack, cmds|
              cmds.each { |cmd| stack.touch(cmd, @@pixels_per_point) }
            end
          end
          # One upload for the shared atlas (first flush wins, the rest
          # see it clean), one per private atlas.
          by_stack.each_key(&.flush)
          evict_stale_stacks
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

        # Every UI quad blends (rgb: src*a + dst*(1-a),
        # a: a + dst_a*(1-a)): translucent fills (the modal scrim,
        # shadows) composite over what's below, and transparent windows
        # receive a correctly premultiplied image; opaque quads are
        # unaffected. Without this the sokol_gl default pipeline (no
        # blending) makes any alpha<255 fill overwrite dst — the modal
        # scrim rendered as solid black.
        LibEguiCr.alpha_pipeline_push
        commands.each { |cmd| paint(cmd) }
        LibEguiCr.alpha_pipeline_pop

        LibEguiCr.end_pass

        # Raster-cache evictions queued mid-frame (Svg#paint's
        # TextureRegistry#destroy_later) run now, after every
        # ImageCmd referencing them has been drawn. A real flush
        # invalidates the idle-frame cache — the cached commands may
        # reference the destroyed ids, and replaying them would hit
        # sg_apply_bindings with a dead view.
        if ctx.textures.pending_destroys?
          ctx.textures.flush_destroys
          @@last_commands = nil
        end
      end

      # Cap on simultaneously live materialized stacks (the shared
      # atlas removes the GPU-side pressure; this caps the CPU side —
      # .ttf data + glyph/kern/measure caches per family, a few MiB
      # each). Above it, the least-recently-drawn stacks are dropped.
      MAX_LIVE_STACKS = 64

      # LRU eviction of materialized deferred stacks (the font-selector
      # leak): drop the oldest stacks from @@materialized and the
      # deferred-origin @@named_fonts entries pointing at them, and
      # roll the app's Context back to the deferred state for those
      # families (its #fonts_for caches resolved stacks forever —
      # without that, the ctx reference would keep the "evicted" stack
      # alive and measure/draw would diverge: ctx measuring the old
      # object while fonts_for_cmd re-materializes a new one). A re-pick
      # simply re-parses the file. Primary/mono slots and app-registered
      # named stacks are never evicted; atlas slots recycle on the next
      # registry reset (glyphs are never freed individually — upstream
      # egui works the same way).
      private def self.evict_stale_stacks : Nil
        live = @@materialized.values.compact.uniq
        overflow = live.size - MAX_LIVE_STACKS
        return unless overflow > 0
        candidates = live.reject { |s| s.same?(@@fonts) || s.same?(@@mono_fonts) }
          .sort_by! { |s| @@stack_frames[s]? || 0_u64 }
        ctx = @@app.try &.ctx
        candidates.first(overflow).each do |victim|
          @@materialized.reject! { |_path, stack| !stack.nil? && stack.same?(victim) }
          @@deferred_fonts.each do |name, paths|
            next unless @@named_fonts[name]?.same?(victim)
            @@named_fonts.delete(name)
            if ctx
              ctx.font_families.delete(name)
              ctx.register_deferred_font(name, paths)
            end
          end
          @@stack_frames.delete(victim)
        end
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
        when Egui::TriCmd
          paint_tri(cmd)
        when Egui::ArcCmd
          paint_arc(cmd)
        when Egui::ShadowCmd
          paint_shadow(cmd)
        when Egui::ImageCmd
          paint_image(cmd)
        when Egui::Mesh3DCmd
          paint_mesh3d(cmd)
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
        # sgl_scissor_rect emits a command UNCONDITIONALLY (no
        # same-rect dedupe in sokol_gl), and a scissor between two
        # begin/end blocks breaks sgl's consecutive-draw merging — so
        # a painted SVG stroke (one LineCmd per segment, one scissor
        # each) used to mint two commands per segment and blow past
        # sgl's command budget, silently dropping everything after
        # it. Skip the no-op emit instead; identical state lets sgl
        # merge the draws.
        return if @@last_scissor == {x, y, w, h}
        @@last_scissor = {x, y, w, h}
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
        # untextured geometry would sample this texture instead of the
        # internal white fallback.
        #
        # The text (straight-alpha) pipeline: the sokol_gl DEFAULT
        # pipeline has no blending, so an RGBA texture's transparent
        # texels would overwrite the destination with black — an icon
        # with soft/rounded edges would come out as a hard black box.
        LibEguiCr.sgl_bind_texture_nearest(cmd.texture_id.to_u32!) if cmd.nearest?
        LibEguiCr.sgl_bind_texture(cmd.texture_id.to_u32!) unless cmd.nearest?
        LibEguiCr.sgl_enable_texture
        LibEguiCr.text_pipeline_push
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
        LibEguiCr.text_pipeline_pop
        LibEguiCr.sgl_disable_texture
      end

      # One batched 3D mesh (Viewport3D): clip to the widget's rect,
      # map the NDC cube onto it (framebuffer pixels — same ppp scaling
      # as the scissor), and hand the packed SoA vertices + column-major
      # mvp to the shim. The shim restores the default 2D state on
      # return, so later commands are unaffected.
      def self.paint_mesh3d(cmd : Egui::Mesh3DCmd) : Nil
        apply_scissor(cmd.clip)
        s = @@pixels_per_point
        v = cmd.viewport
        x = (v.min.x * s).floor.to_i
        y = (v.min.y * s).floor.to_i
        w = {(v.max.x * s).ceil.to_i - x, 1}.max
        h = {(v.max.y * s).ceil.to_i - y, 1}.max
        count = cmd.data.size // 16
        prim = cmd.primitive == :lines ? 1 : 0
        LibEguiCr.mesh3d(cmd.mvp.to_unsafe, cmd.blend?, prim,
          x, y, w, h, count, cmd.data.to_unsafe)
      end

      def self.paint_rect(cmd : Egui::RectCmd) : Nil
        apply_scissor(cmd.clip)

        # Replace rects draw with blending OFF (the fill is already
        # premultiplied and must overwrite dst alpha — see
        # Painter#rect_replace); everything else blends normally.
        if cmd.replace?
          LibEguiCr.replace_pipeline_push
          paint_rect_body(cmd)
          LibEguiCr.replace_pipeline_pop
        else
          paint_rect_body(cmd)
        end
      end

      def self.paint_rect_body(cmd : Egui::RectCmd) : Nil
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
        corner.call(r.min.x + round, r.min.y + round, Math::PI)       # top-left
        corner.call(r.max.x - round, r.min.y + round, Math::PI * 1.5) # top-right
        corner.call(r.max.x - round, r.max.y - round, 0.0)            # bottom-right
        corner.call(r.min.x + round, r.max.y - round, Math::PI / 2.0) # bottom-left

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
        fonts = fonts_for_cmd(cmd)
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
        # Bold/italic cmds already draw through a REAL variant face
        # resolved in #fonts_for_cmd (a missing variant degrades to the
        # base face — never an emulated one), so the quads below are
        # plain: one pass, no shear, no double strike.
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

        p1 = cmd.p1
        p2 = cmd.p2
        # Snap axis-aligned lines to the pixel grid: a width-1 line
        # centered on a pixel boundary antialiases across two rows
        # (looks 2px); centered on k+0.5 it covers exactly one.
        if (p2.y - p1.y).abs < 1e-9 # horizontal
          y = p1.y.floor + 0.5
          p1 = Egui::Pos2.new(p1.x, y)
          p2 = Egui::Pos2.new(p2.x, y)
        elsif (p2.x - p1.x).abs < 1e-9 # vertical
          x = p1.x.floor + 0.5
          p1 = Egui::Pos2.new(x, p1.y)
          p2 = Egui::Pos2.new(x, p2.y)
        end
        d = p2 - p1
        len = d.length
        return if len < 1e-9
        # perpendicular unit vector scaled to half the stroke width
        n = Egui::Vec2.new(-d.y / len, d.x / len) * (cmd.width / 2.0)
        LibEguiCr.sgl_begin_quads
        quad_pts(p1 - n, p2 - n, p2 + n, p1 + n, cmd.color)
        LibEguiCr.sgl_end
      end

      def self.paint_arc(cmd : Egui::ArcCmd) : Nil
        clip = cmd.clip
        paint_ring(cmd.center, cmd.radius, cmd.start_angle, cmd.end_angle,
          cmd.width, cmd.color, clip)
      end

      # A filled triangle as a degenerate quad (a, a, b, c) — the same
      # trick the circle fan in #paint_circle uses.
      def self.paint_tri(cmd : Egui::TriCmd) : Nil
        apply_scissor(cmd.clip)
        LibEguiCr.sgl_begin_quads
        quad_pts(cmd.a, cmd.a, cmd.b, cmd.c, cmd.fill)
        LibEguiCr.sgl_end
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

      # --- box-shadow (CSS) --------------------------------------------------
      #
      # A blurred band around (outset) or inside (inset) a rounded rect,
      # built from gradient bands: each band is a quad strip between two
      # offsets of the rect's rounded perimeter, per-vertex alpha from a
      # gaussian-ish falloff table — Gouraud interpolation does the
      # smoothing, the same machinery as the fill2 vertical gradients.
      # Upstream egui blurs shadows the same way conceptually (tessellator
      # `feathering` widened to `blur_width`), but has no inset at all.

      # One point of a rounded-rect perimeter: position, INWARD unit
      # normal (edge normals axis-aligned, corner normals aimed at the
      # corner center) and the (one or two) sides the point belongs to —
      # inset band depths differ per side, corner points blend the two.
      alias PerimPt = {Egui::Pos2, Egui::Vec2, Symbol, Symbol}

      # Walk the rounded perimeter clockwise: top edge → TR arc → right
      # edge → BR arc → bottom edge → BL arc → left edge → TL arc.
      # Straight edges carry only their endpoints — alpha never varies
      # along an edge, so one quad per band spans it.
      def self.rounded_perimeter(r : Egui::Rect, radius : Float64) : Array(PerimPt)
        radius = {radius, r.width / 2.0, r.height / 2.0}.min
        pts = [] of PerimPt
        corner = ->(cx : Float64, cy : Float64, a0 : Float64, s1 : Symbol, s2 : Symbol) do
          6.times do |i|
            a = a0 + (Math::PI / 2.0) * i / 5.0
            dir = Egui::Vec2.new(Math.cos(a), Math.sin(a))
            pts << {Egui::Pos2.new(cx + radius * dir.x, cy + radius * dir.y),
                    dir * -1.0, s1, s2}
          end
        end
        pts << {Egui::Pos2.new(r.min.x + radius, r.min.y),
                Egui::Vec2.new(0.0, 1.0), :top, :top}
        corner.call(r.max.x - radius, r.min.y + radius, Math::PI * 1.5, :top, :right)
        pts << {Egui::Pos2.new(r.max.x, r.min.y + radius),
                Egui::Vec2.new(-1.0, 0.0), :right, :right}
        corner.call(r.max.x - radius, r.max.y - radius, 0.0, :right, :bottom)
        pts << {Egui::Pos2.new(r.max.x - radius, r.max.y),
                Egui::Vec2.new(0.0, -1.0), :bottom, :bottom}
        corner.call(r.min.x + radius, r.max.y - radius, Math::PI / 2.0, :bottom, :left)
        pts << {Egui::Pos2.new(r.min.x, r.max.y - radius),
                Egui::Vec2.new(1.0, 0.0), :left, :left}
        corner.call(r.min.x + radius, r.min.y + radius, Math::PI, :left, :top)
        pts
      end

      # Gaussian-ish falloff for one band stop: full alpha at the caster
      # edge (t=0), ~0.14 at the band rim (t=1) — a CSS blur of `b`
      # reads as a gaussian with σ ≈ b/2, i.e. exp(-2t²) over the band.
      def self.shadow_stop(color : Egui::Color32, t : Float64) : Egui::Color32
        a = (color.a.to_f64 * Math.exp(-2.0 * t * t) + 0.5).floor.to_u8
        Egui::Color32.new(color.r, color.g, color.b, a)
      end

      # Emit the band quads between perimeter offset `t0 * depth` and
      # `t1 * depth` (depth is per-point — sides can differ for inset
      # shadows); outward when `sign` is -1, inward when +1.
      def self.shadow_band(pts : Array(PerimPt),
                           depths : Array(Float64), t0 : Float64, t1 : Float64,
                           color : Egui::Color32, sign : Float64) : Nil
        c0 = shadow_stop(color, t0)
        c1 = shadow_stop(color, t1)
        pts.each_with_index do |(p, n, _, _), i|
          q = pts[(i + 1) % pts.size]
          qn = q[1]
          p0 = p + n * (sign * depths[i] * t0)
          p1 = q[0] + qn * (sign * depths[i + 1 == pts.size ? 0 : i + 1] * t0)
          p0b = p + n * (sign * depths[i] * t1)
          p1b = q[0] + qn * (sign * depths[i + 1 == pts.size ? 0 : i + 1] * t1)
          sgl_quad_colors(p0, p1, p1b, p0b, c0, c1)
        end
      end

      def self.sgl_quad_colors(p0 : Egui::Pos2, p1 : Egui::Pos2,
                               p2 : Egui::Pos2, p3 : Egui::Pos2,
                               c_edge : Egui::Color32,
                               c_inner : Egui::Color32) : Nil
        LibEguiCr.sgl_v2f_c4b(p0.x.to_f32, p0.y.to_f32,
          c_edge.r, c_edge.g, c_edge.b, c_edge.a)
        LibEguiCr.sgl_v2f_c4b(p1.x.to_f32, p1.y.to_f32,
          c_edge.r, c_edge.g, c_edge.b, c_edge.a)
        LibEguiCr.sgl_v2f_c4b(p2.x.to_f32, p2.y.to_f32,
          c_inner.r, c_inner.g, c_inner.b, c_inner.a)
        LibEguiCr.sgl_v2f_c4b(p3.x.to_f32, p3.y.to_f32,
          c_inner.r, c_inner.g, c_inner.b, c_inner.a)
      end

      def self.paint_shadow(cmd : Egui::ShadowCmd) : Nil
        return if cmd.color.a.zero?
        apply_scissor(cmd.clip)

        if cmd.inset?
          paint_shadow_inset(cmd)
        else
          paint_shadow_outset(cmd)
        end
      end

      # Outset: the caster is the rect translated by `offset` and
      # expanded by `spread` (corner radius grows with both, like
      # upstream `Shadow::as_shape`); `blur` fades outward from there.
      # A ~zero blur leaves the plain offset/spread silhouette.
      def self.paint_shadow_outset(cmd : Egui::ShadowCmd) : Nil
        base = cmd.rect.translate(cmd.offset).expand(cmd.spread)
        radius = cmd.rounding + cmd.spread
        blur = cmd.blur

        if blur <= 0.5
          if cmd.spread > 0.5 || cmd.offset.x.abs >= 0.5 || cmd.offset.y.abs >= 0.5
            rounded_rect_fill(base, radius, cmd.color)
          end
          return
        end

        # The caster silhouette itself is solid shadow (CSS fills the
        # offset shape before blurring) — without it, an `offset` shows
        # a gap between the rect and the outward fade.
        rounded_rect_fill(base, radius, cmd.color)
        pts = rounded_perimeter(base, radius)
        # Bands cover the blur width; alpha stops follow exp(-2t²).
        bands = {blur.ceil.to_i, 1}.max.clamp(1..4)
        depths = Array.new(pts.size, blur)
        LibEguiCr.sgl_begin_quads
        bands.times do |k|
          shadow_band(pts, depths, k.to_f64 / bands,
            (k + 1).to_f64 / bands, cmd.color, -1.0)
        end
        LibEguiCr.sgl_end
      end

      # Inset: the band lives INSIDE the rect, per-side depth = half the
      # blur plus the offset's push towards that side (CSS `inset 0 1px`
      # — y+1 is down — deepens the TOP band, thins the bottom one to
      # nothing), plus `spread` everywhere. Corner depths are the mean
      # of their two sides, clamped so the inner corner radius stays
      # non-negative; every depth also clamps to half the rect's small
      # side so opposing bands never cross the center.
      def self.paint_shadow_inset(cmd : Egui::ShadowCmd) : Nil
        r = cmd.rect
        b = cmd.blur * 0.5 + cmd.spread
        d_top = {b + cmd.offset.y, 0.0}.max
        d_bottom = {b - cmd.offset.y, 0.0}.max
        d_left = {b + cmd.offset.x, 0.0}.max
        d_right = {b - cmd.offset.x, 0.0}.max
        return if d_top <= 0.0 && d_bottom <= 0.0 &&
                  d_left <= 0.0 && d_right <= 0.0

        pts = rounded_perimeter(r, cmd.rounding)
        radius = {cmd.rounding, r.width / 2.0, r.height / 2.0}.min
        side = {r.width, r.height}.min / 2.0
        depths = pts.map do |(_, _, s1, s2)|
          d = (side_depth(s1, d_top, d_bottom, d_left, d_right) +
               side_depth(s2, d_top, d_bottom, d_left, d_right)) / 2.0
          # radius - 0.25 keeps the inner corner non-inverted; the
          # max(0) collapses bands at near-sharp corners instead of
          # flipping them outward.
          {d, {radius - 0.25, 0.0}.max, side}.min
        end
        max_depth = depths.max
        return if max_depth <= 0.0

        bands = {max_depth.ceil.to_i, 1}.max.clamp(1..4)
        LibEguiCr.sgl_begin_quads
        bands.times do |k|
          shadow_band(pts, depths, k.to_f64 / bands,
            (k + 1).to_f64 / bands, cmd.color, 1.0)
        end
        LibEguiCr.sgl_end
      end

      def self.side_depth(side : Symbol, d_top : Float64, d_bottom : Float64,
                          d_left : Float64, d_right : Float64) : Float64
        case side
        when :top    then d_top
        when :bottom then d_bottom
        when :left   then d_left
        else              d_right
        end
      end

      def self.bar(r : Egui::Rect, c : Egui::Color32) : Nil
        quad(r, c)
      end

      # GPU textures via the shim (sg_make_image/sampler/view); the
      # core sees opaque UInt64 handles only.
      class SokolTextureRegistry < Egui::TextureRegistry
        # Real GPU textures — Svg#paint engages its raster-texture
        # cache on this flag.
        def graphical? : Bool
          true
        end

        # Evictions queued during #destroy_later die after the pass —
        # see the base-class comment.
        @pending_destroys = [] of UInt64

        def destroy_later(id : UInt64) : Nil
          @pending_destroys << id unless id.zero?
        end

        def pending_destroys? : Bool
          !@pending_destroys.empty?
        end

        def flush_destroys : Nil
          @pending_destroys.each do |id|
            LibEguiCr.destroy_texture(id.to_u32!)
          end
          @pending_destroys.clear
        end

        def register_rgba(width : Int32, height : Int32,
                          data : Bytes) : UInt64
          return 0_u64 if width <= 0 || height <= 0
          LibEguiCr.make_texture(width, height,
            data.to_unsafe).to_u64
        end

        def load(path : String) : UInt64
          LibEguiCr.load_image(path.to_unsafe).to_u64
        end

        # Header-only probe (stbi_info shim) — pixel size for layout
        # without decoding the whole image.
        def image_size(path : String) : Egui::Vec2?
          w, h = 0, 0
          if LibEguiCr.image_info(path.to_unsafe, pointerof(w),
                                  pointerof(h)) == 1 && w > 0 && h > 0
            Egui::Vec2.new(w.to_f, h.to_f)
          end
        end

        def create_stream(width : Int32, height : Int32) : UInt64
          LibEguiCr.make_stream_texture(width, height).to_u64
        end

        def update(id : UInt64, width : Int32, height : Int32,
                   data : Bytes) : Nil
          return if id.zero?
          LibEguiCr.update_texture(id.to_u32!, width, height,
            data.to_unsafe)
        end

        def destroy(id : UInt64) : Nil
          return if id.zero?
          LibEguiCr.destroy_texture(id.to_u32!)
        end
      end

      @@cbs : {LibEguiCr::InitCb, LibEguiCr::FrameCb, LibEguiCr::EventCb, LibEguiCr::CleanupCb}?
    end
  end
end
