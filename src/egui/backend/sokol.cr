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

  # sokol_app
  fun sapp_width : Int32
  fun sapp_height : Int32
  fun sapp_dpi_scale : Float32
  fun sapp_quit

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

      # sapp_event_type values (sokol_app.h)
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

        init = ->{ on_init }
        frame = ->{ on_frame }
        event = ->(t : Int32, mx : Float32, my : Float32, sx : Float32, sy : Float32,
                    mods : UInt32, btn : UInt32, key : UInt32, chr : UInt32) {
          on_event(t, mx, my, sx, sy)
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
      end

      protected def self.on_event(type : Int32, mx : Float32, my : Float32,
                                  sx : Float32, sy : Float32) : Nil
        case type
        when MOUSE_MOVE
          @@events << Egui::Event.pointer_moved(Egui::Pos2.new(mx, my))
        when MOUSE_DOWN
          @@events << Egui::Event.pointer_pressed(Egui::Pos2.new(mx, my))
        when MOUSE_UP
          @@events << Egui::Event.pointer_released(Egui::Pos2.new(mx, my))
        when MOUSE_SCROLL
          @@events << Egui::Event.scroll(Egui::Vec2.new(sx, sy))
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

        w = LibEguiCr.sapp_width
        h = LibEguiCr.sapp_height
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
        end
      end

      def self.paint_rect(cmd : Egui::RectCmd) : Nil
        clip = cmd.clip
        LibEguiCr.sgl_scissor_rectf(
          clip.min.x.to_f32, clip.min.y.to_f32,
          {clip.width, 1.0}.max.to_f32, {clip.height, 1.0}.max.to_f32, true)

        if fill = cmd.fill
          LibEguiCr.sgl_begin_quads
          quad(cmd.rect, fill)
          LibEguiCr.sgl_end
        end

        if (stroke = cmd.stroke_color) && cmd.stroke_width > 0
          w = cmd.stroke_width
          r = cmd.rect
          LibEguiCr.sgl_begin_quads
          # top / bottom / left / right bars (corner rounding: slice 2+)
          bar(Egui::Rect.from_min_size(r.min, Egui::Vec2.new(r.width, w)), stroke)
          bar(Egui::Rect.from_min_size(Egui::Pos2.new(r.min.x, r.max.y - w),
            Egui::Vec2.new(r.width, w)), stroke)
          bar(Egui::Rect.from_min_size(r.min, Egui::Vec2.new(w, r.height)), stroke)
          bar(Egui::Rect.from_min_size(Egui::Pos2.new(r.max.x - w, r.min.y),
            Egui::Vec2.new(w, r.height)), stroke)
          LibEguiCr.sgl_end
        end
      end

      def self.paint_text(cmd : Egui::TextCmd) : Nil
        fons = @@fons
        return unless fons

        clip = cmd.clip
        LibEguiCr.sgl_scissor_rectf(
          clip.min.x.to_f32, clip.min.y.to_f32,
          {clip.width, 1.0}.max.to_f32, {clip.height, 1.0}.max.to_f32, true)

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
