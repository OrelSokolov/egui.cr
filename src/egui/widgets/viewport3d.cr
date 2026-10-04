# egui.cr-native 3D viewport (no upstream counterpart): a widget that
# allocates a rect, clips to it, and draws caller-supplied depth-tested
# meshes through `Painter#mesh3d` (the backend's sgl 3D pipelines).
#
#   vp = Egui::Viewport3D.new("model", Egui::Vec2.new(600.0, 400.0))
#   vp.camera.distance = 5.0
#   vp.show(ui) do |frame|
#     frame.draw(mesh, model: Egui::Mat4.rotate_y(t))
#   end
#
# Built-in orbit camera: drag to rotate (yaw/pitch), wheel to zoom; the
# pointer-to-local pattern is the same as `Canvas::Interaction`. Apps
# label 3D points through `Frame3D#project` + ordinary `painter.text`.

module Egui
  # Orbit camera: yaw/pitch/distance around a target point. The view
  # matrix is a right-handed look-at; the projection a standard
  # perspective (GL conventions — the backend viewport flips NDC y to
  # the screen correctly).
  class Camera3D
    # Radians, yaw 0 looks from +z towards the target.
    property yaw : Float64
    # Radians, clamped by the widget to ±π/2-ish so the up vector never
    # degenerates.
    property pitch : Float64
    property distance : Float64
    property target : Vec3
    property fov_deg : Float64

    def initialize(@yaw : Float64 = 0.6, @pitch : Float64 = 0.45,
                   @distance : Float64 = 5.0,
                   @target : Vec3 = Vec3.zero, @fov_deg : Float64 = 50.0)
    end

    def eye : Vec3
      cp = Math.cos(@pitch)
      Vec3.new(
        @target.x + @distance * cp * Math.sin(@yaw),
        @target.y + @distance * Math.sin(@pitch),
        @target.z + @distance * cp * Math.cos(@yaw))
    end

    def view : Mat4
      Mat4.look_at(eye, @target, Vec3.up)
    end

    def projection(aspect : Float64) : Mat4
      Mat4.perspective(@fov_deg, {aspect, 1e-6}.max, 0.05, 100.0)
    end

    # projection × view × model — what a Mesh3DCmd carries.
    def mvp(model : Mat4, aspect : Float64) : Mat4
      projection(aspect) * view * model
    end

    # World point → screen position inside `viewport` (points, origin
    # top-left); nil when the point is behind the camera. For text
    # labels and point picking.
    def project(v : Vec3, viewport : Rect) : Pos2?
      pv = projection(viewport.width / {viewport.height, 1e-6}.max) * view
      # w of the clip-space point — negative/zero means behind the
      # camera, where the perspective divide flips the projection.
      w = pv[0, 3].to_f64 * v.x + pv[1, 3].to_f64 * v.y +
          pv[2, 3].to_f64 * v.z + pv[3, 3].to_f64
      return nil if w <= 1e-9
      ndc = pv.transform(v)
      Pos2.new(viewport.min.x + (ndc.x + 1.0) * 0.5 * viewport.width,
               viewport.min.y + (1.0 - ndc.y) * 0.5 * viewport.height)
    end
  end

  # Vertex accumulator for one draw call: every vertex is packed SoA
  # (x,y,z f32 + r,g,b,a u8 — 16 bytes) exactly as `Mesh3DCmd` wants.
  # One builder is one primitive: triangles or lines.
  class Mesh3D
    getter primitive : Symbol
    getter vertex_count : Int32
    @data : Bytes
    @len : Int32 = 0

    def initialize(@primitive : Symbol = :triangles)
      @data = Bytes.new(4096 * 16)
      @vertex_count = 0
    end

    def clear : Nil
      @len = 0
      @vertex_count = 0
    end

    # Make room for one more vertex, growing the backing buffer.
    private def reserve : Nil
      if @len + 16 > @data.size
        bigger = Bytes.new({@data.size * 2, @len + 16}.max)
        bigger.copy_from(@data)
        @data = bigger
      end
    end

    def vertex(v : Vec3, c : Color32) : Nil
      reserve
      i = @len
      IO::ByteFormat::LittleEndian.encode(v.x.to_f32, @data[i, 4])
      IO::ByteFormat::LittleEndian.encode(v.y.to_f32, @data[i + 4, 4])
      IO::ByteFormat::LittleEndian.encode(v.z.to_f32, @data[i + 8, 4])
      @data[i + 12] = c.r
      @data[i + 13] = c.g
      @data[i + 14] = c.b
      @data[i + 15] = c.a
      @len += 16
      @vertex_count += 1
    end

    # Flat-colored triangle.
    def triangle(a : Vec3, b : Vec3, c : Vec3, color : Color32) : Nil
      vertex(a, color)
      vertex(b, color)
      vertex(c, color)
    end

    # Gouraud triangle (per-vertex colors).
    def triangle(a : Vec3, b : Vec3, c : Vec3,
                 ca : Color32, cb : Color32, cc : Color32) : Nil
      vertex(a, ca)
      vertex(b, cb)
      vertex(c, cc)
    end

    def line(a : Vec3, b : Vec3, color : Color32) : Nil
      vertex(a, color)
      vertex(b, color)
    end

    # The packed bytes (a view — valid until the next #vertex/#clear).
    def bytes : Bytes
      @data[0, @len]
    end

    # --- shading helpers ------------------------------------------------
    #
    # Framework-side lambert + a cheap view-independent specular (a
    # tight pow() lobe on the same dot — the "hot facet" facing the
    # light), so apps don't each reinvent the school-lambert look.

    def self.shade(base : Color32, normal : Vec3, light : Vec3,
                   ambient : Float64 = 0.32, diffuse : Float64 = 0.58,
                   spec : Float64 = 0.35,
                   shininess : Float64 = 8.0) : Color32
      d = {normal.dot(light), 0.0}.max
      f = ambient + diffuse * d + spec * d ** shininess
      Color32.new(
        ({base.r.to_f64 * f, 255.0}.min).to_u8,
        ({base.g.to_f64 * f, 255.0}.min).to_u8,
        ({base.b.to_f64 * f, 255.0}.min).to_u8, base.a)
    end

    # Triangle accumulator for shaded emission: `#emit` either takes
    # each face's flat normal (faceted look) or — `smooth: true` —
    # averages the adjacent faces' normals into per-VERTEX normals and
    # shades per vertex, which the rasterizer interpolates into Gouraud
    # gradients across each face (polished look). Positions are stored
    # as given (app-space); a pure rotation keeps the derived normals
    # valid, non-uniform scale does not.
    class Faces
      def initialize
        @tris = [] of {Vec3, Vec3, Vec3}
      end

      def add(a : Vec3, b : Vec3, c : Vec3) : Nil
        @tris << {a, b, c}
      end

      def clear : Nil
        @tris.clear
      end

      def size : Int32
        @tris.size
      end

      def each(& : Vec3, Vec3, Vec3 ->)
        @tris.each { |(a, b, c)| yield a, b, c }
      end

      def emit(mesh : Mesh3D, base : Color32, light : Vec3,
               smooth : Bool = false,
               ambient : Float64 = 0.32, diffuse : Float64 = 0.58,
               spec : Float64 = 0.35,
               shininess : Float64 = 8.0) : Nil
        light = light.normalized
        unless smooth
          @tris.each do |a, b, c|
            n = (b - a).cross(c - a).normalized
            mesh.triangle(a, b, c, Mesh3D.shade(base, n, light,
              ambient, diffuse, spec, shininess))
          end
          return
        end
        # Per-vertex normals: dedup vertices by rounded position,
        # accumulate the flat normals of every incident face.
        index = Hash(String, Int32).new
        norms = [] of Vec3
        verts = Array(Vec3).new(@tris.size * 3)
        idxs = Array(Int32).new(@tris.size * 3)
        @tris.each do |a, b, c|
          n = (b - a).cross(c - a).normalized
          {a, b, c}.each do |v|
            key = "%.4f,%.4f,%.4f" % {v.x, v.y, v.z}
            unless (i = index[key]?)
              i = norms.size
              index[key] = i
              norms << Vec3.zero
            end
            verts << v
            idxs << i
            norms[i] = norms[i] + n
          end
        end
        colors = norms.map do |n|
          Mesh3D.shade(base, n.normalized, light,
            ambient, diffuse, spec, shininess)
        end
        idxs.each_with_index { |vi, k| mesh.vertex(verts[k], colors[vi]) }
      end
    end
  end

  # Handed to the `Viewport3D#show` block: draws meshes under an
  # optional model matrix through the widget's camera and projects
  # world points to the screen for labels.
  class Frame3D
    getter camera : Camera3D
    getter rect : Rect
    @painter : Painter
    @line_aa : Bool
    @line_width : Float64

    def initialize(@painter : Painter, @camera : Camera3D, @rect : Rect,
                   @line_aa : Bool, @line_width : Float64)
    end

    def draw(mesh : Mesh3D, model : Mat4 = Mat4.identity,
             blend : Bool = false) : Nil
      return if mesh.vertex_count.zero?
      if mesh.primitive == :lines && @line_aa
        draw_lines_msaa(mesh, model)
      else
        @painter.mesh3d(@rect, @camera.mvp(model, @rect.width / @rect.height),
          mesh.bytes, mesh.primitive, blend)
      end
    end

    # Anti-aliased line meshes: sokol_gl lines are hard 1px GL lines —
    # the one part of the 3D path MSAA cannot help (their coverage is
    # binary). Instead of emitting them, project each segment through
    # the camera and stroke it as ordinary 2D Painter lines, which the
    # backend rasterizes as quads under the swapchain's MSAA. Each
    # segment draws twice — a faint wide halo under a solid core — for
    # a soft falloff beyond what 4x samples give. Segments with an
    # endpoint behind the camera are skipped.
    private def draw_lines_msaa(mesh : Mesh3D, model : Mat4) : Nil
      data = mesh.bytes
      (0...mesh.vertex_count).step(2) do |i|
        o = i * 16
        a = model.transform(decode_vertex(data, o))
        b = model.transform(decode_vertex(data, o + 16))
        ca = vertex_color(data, o)
        pa = @camera.project(a, @rect)
        pb = @camera.project(b, @rect)
        next unless pa && pb
        halo = Color32.new(ca.r, ca.g, ca.b, (ca.a // 4).to_u8)
        @painter.line(pa, pb, @line_width + 2.0, halo)
        @painter.line(pa, pb, @line_width, ca)
      end
    end

    private def decode_vertex(data : Bytes, offset : Int32) : Vec3
      Vec3.new(
        IO::ByteFormat::LittleEndian.decode(Float32, data[offset, 4]).to_f64,
        IO::ByteFormat::LittleEndian.decode(Float32, data[offset + 4, 4]).to_f64,
        IO::ByteFormat::LittleEndian.decode(Float32, data[offset + 8, 4]).to_f64)
    end

    private def vertex_color(data : Bytes, offset : Int32) : Color32
      Color32.new(data[offset + 12], data[offset + 13],
        data[offset + 14], data[offset + 15])
    end

    # World point → screen position (nil behind the camera) — anchor
    # for ordinary `painter.text` labels over the 3D scene.
    def project(v : Vec3) : Pos2?
      @camera.project(v, @rect)
    end
  end

  # A depth-tested 3D viewport widget: opaque background quad, then
  # whatever meshes the block draws, all clipped to the widget rect.
  class Viewport3D
    include Widget

    getter camera : Camera3D
    getter size_hint : Vec2
    # Stretch to the full available width instead of `size_hint.x`.
    property? fill_width : Bool = false
    # Backdrop painted before the 3D content (nil = none).
    property background : Color32?
    property rounding : Float64 = 0.0
    # Anti-aliased line meshes: `:lines` meshes draw as projected 2D
    # MSAA strokes instead of hard 1px GL lines (see Frame3D#draw).
    property? line_aa : Bool = true
    # Stroke width of the anti-aliased lines (points).
    property line_width : Float64 = 1.5

    @pid : Id

    def initialize(id : String, @size_hint : Vec2,
                   @camera : Camera3D = Camera3D.new)
      @pid = Id.from("viewport3d/#{id}")
    end

    def ui(ui : Ui) : Response
      show(ui) { |_frame| }
    end

    # Allocate, interact (orbit: drag rotates, wheel zooms), paint.
    # Returns this frame's Response.
    def show(ui : Ui) : Response
      ctx = ui.ctx
      size = Vec2.new(
        @fill_width ? ui.available_width : @size_hint.x,
        @size_hint.y)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, @pid, Sense.click_and_drag)

      # --- orbit interaction ------------------------------------------
      # Drag rotates around the target; wheel zooms exponentially like
      # every orbit camera. Repaint is requested only while the camera
      # actually moves — an idle viewport costs no frames.
      if response.dragged?
        d = response.drag_delta
        if d.x.abs > 0.0 || d.y.abs > 0.0
          @camera.yaw -= d.x * 0.01
          @camera.pitch = (@camera.pitch - d.y * 0.01)
            .clamp(-1.45, 1.45)
        end
      end
      scroll = ctx.input.scroll.y
      unless scroll.abs < 1e-9
        @camera.distance = (@camera.distance * Math.exp(scroll * 0.001))
          .clamp(0.2, 60.0)
      end
      # Repaint only while the camera actually moves — an idle viewport
      # costs no frames.
      ctx.request_repaint if response.dragged? || scroll.abs > 1e-9

      # --- paint --------------------------------------------------------
      painter = ui.painter
      if (bg = @background)
        painter.rect(rect, @rounding, bg)
      end
      frame = Frame3D.new(painter, @camera, rect, line_aa?, @line_width)
      yield frame

      response.on_hover_and_drag_cursor(CursorIcon::Grabbing) if response.hovered?

      response.widget_text = "viewport3d"
      response
    end
  end
end
