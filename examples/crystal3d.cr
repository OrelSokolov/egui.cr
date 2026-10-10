# 3D demo — a rotating crystal: a quartz-like hexagonal prism with
# pyramidal terminations, spinning around its vertical axis, built on
# the framework's Viewport3D / Mesh3D seam. All geometry lives here;
# the smoothing comes from the framework:
#
#   Viewport3D#line_aa  — `:lines` meshes draw as projected 2D MSAA
#                         strokes (soft halo + core), not hard 1px GL
#                         lines
#   Mesh3D::Faces       — flat (per-face lambert) or smooth (per-vertex
#                         averaged normals → Gouraud gradients + a
#                         specular hot facet) shaded emission
#
#   drag    — orbit the camera
#   wheel   — zoom
#   select  — smoothing: off / shading / shading + edges

require "../src/egui/backend_selector"

# Crystal silhouette (example-local): world-space triangles and edges
# of a hexagonal prism with pyramidal caps, slightly oblique at the
# bottom — the classic quartz habit.
module CrystalGeom
  SIDES = 6

  # The crystal's triangles in LOCAL space (apply the model matrix
  # yourself before shading — a pure rotation keeps normals valid).
  def self.triangles(model : Egui::Mat4) : Array({Egui::Vec3, Egui::Vec3, Egui::Vec3})
    px = ->(x : Float64, y : Float64, z : Float64) do
      model.transform(Egui::Vec3.new(x, y, z))
    end
    r = 1.0
    ring_top = Array.new(SIDES) { |i|
      px.call(r * Math.cos(i * Math::TAU / SIDES), 0.9,
        r * Math.sin(i * Math::TAU / SIDES))
    }
    ring_bot = Array.new(SIDES) { |i|
      px.call(r * Math.cos((i + 0.5) * Math::TAU / SIDES), -1.0,
        r * Math.sin((i + 0.5) * Math::TAU / SIDES))
    }
    a_top = model.transform(Egui::Vec3.new(0.0, 1.8, 0.0))
    a_bot = model.transform(Egui::Vec3.new(0.15, -1.75, -0.05))

    tris = [] of {Egui::Vec3, Egui::Vec3, Egui::Vec3}
    SIDES.times do |i|
      j = (i + 1) % SIDES
      tris << {ring_top[i], ring_top[j], ring_bot[i]} # prism side quad
      tris << {ring_top[j], ring_bot[j], ring_bot[i]}
      tris << {ring_top[i], ring_top[j], a_top}       # top pyramid
      tris << {ring_bot[i], a_bot, ring_bot[j]}       # bottom pyramid
    end
    tris
  end

  # Silhouette edges in LOCAL space, for the wireframe line mesh.
  EDGES = begin
    r = 1.0
    ring_top = Array.new(SIDES) { |i|
      Egui::Vec3.new(r * Math.cos(i * Math::TAU / SIDES), 0.9,
        r * Math.sin(i * Math::TAU / SIDES))
    }
    ring_bot = Array.new(SIDES) { |i|
      Egui::Vec3.new(r * Math.cos((i + 0.5) * Math::TAU / SIDES), -1.0,
        r * Math.sin((i + 0.5) * Math::TAU / SIDES))
    }
    a_top = Egui::Vec3.new(0.0, 1.8, 0.0)
    a_bot = Egui::Vec3.new(0.15, -1.75, -0.05)
    edges = [] of {Egui::Vec3, Egui::Vec3}
    SIDES.times do |i|
      j = (i + 1) % SIDES
      edges << {ring_top[i], ring_top[j]}
      edges << {ring_bot[i], ring_bot[j]}
      edges << {ring_top[i], ring_bot[i]}
      edges << {ring_top[i], a_top}
      edges << {ring_bot[i], a_bot}
    end
    edges
  end
end

class Crystal3DApp < Egui::App
  CRYSTAL = Egui::Color32.rgb(0x6e, 0xb8, 0xff) # icy blue
  EDGE    = Egui::Color32.rgba(230, 245, 255, 190)
  LIGHT   = Egui::Vec3.new(0.45, 0.8, 0.4).normalized
  APEX    = Egui::Vec3.new(0.0, 1.8, 0.0)

  SMOOTH_MODES = ["off", "shading", "shading + edges", "edges only"]

  @viewport : Egui::Viewport3D
  @spin : Float64 = 0.0
  @speed : Float64 = 1.0
  @spinning = true
  @wireframe = true
  @smoothing = "edges only"

  def initialize
    super
    @viewport = Egui::Viewport3D.new("crystal", Egui::Vec2.new(800.0, 560.0))
    @viewport.fill_width = true
    @viewport.camera.distance = 5.5
    @viewport.camera.pitch = 0.42
  end

  def update(ctx : Egui::Context) : Nil
    dt = ctx.input.dt
    if @spinning
      @spin += dt * @speed
      ctx.request_repaint # keep the rotation animated
    end

    ctx.side_panel(:left, "controls", width: 240.0) do |panel|
      panel.heading("Crystal 3D")
      panel.label("drag: orbit · wheel: zoom")
      panel.separator
      if panel.button(@spinning ? "Pause" : "Spin").clicked?
        @spinning = !@spinning
      end
      panel.label("speed")
      panel.slider(@speed, 0.0..3.0) { |v| @speed = v }
      panel.checkbox(@wireframe, "wireframe") { |v| @wireframe = v }
      panel.label("smoothing")
      panel.select_box("c3d_smooth", @smoothing, SMOOTH_MODES, 200.0) do |m|
        @smoothing = m
      end
      panel.separator
      panel.label("yaw   %.2f rad" % @viewport.camera.yaw)
      panel.label("pitch %.2f rad" % @viewport.camera.pitch)
      panel.label("dist  %.2f" % @viewport.camera.distance)
    end

    ctx.central_panel do |ui|
      edges_only = @smoothing == "edges only"
      smooth_shading = @smoothing != "off"
      # line_aa on  → projected 2D MSAA strokes (framework AA)
      # line_aa off → raw GL lines inside the 3D pass
      @viewport.line_aa = @smoothing == "shading + edges" || edges_only

      @viewport.show(ui) do |frame|
        model = Egui::Mat4.rotate_y(@spin) * Egui::Mat4.rotate_x(0.12)

        unless edges_only
          faces = Egui::Mesh3D::Faces.new
          CrystalGeom.triangles(model).each { |a, b, c| faces.add(a, b, c) }
          mesh = Egui::Mesh3D.new(:triangles)
          faces.emit(mesh, CRYSTAL, LIGHT, smooth: smooth_shading)
          frame.draw(mesh)
        end

        if @wireframe || edges_only
          edges = Egui::Mesh3D.new(:lines)
          CrystalGeom::EDGES.each do |a, b|
            edges.line(model.transform(a), model.transform(b), EDGE)
          end
          frame.draw(edges)
        end

        # A screen-space label anchored to the crystal's top apex —
        # the Frame3D#project → painter.text pattern (the apex rotates
        # with the model, so project the TRANSFORMED point).
        if (p = frame.project(model.transform(APEX)))
          ui.painter.text(p + Egui::Vec2.new(6.0, -14.0), "α-Quartz",
            ui.style.font_size, Egui::Color32.rgb(0x9f, 0xd5, 0xff))
        end

        # FPS overlay pinned to the viewport's top-right corner —
        # ctx.fps is the framework's smoothed meter, colored by health
        # (green ≥ 55, yellow ≥ 30, red below).
        fps = "%.1f fps" % ctx.fps
        fps_w = ctx.fonts.measure(fps, ui.style.font_size).x
        color = case ctx.fps
                when .>=(55.0) then Egui::Color32.rgba(0x7d, 0xdc, 0x8a, 220)
                when .>=(30.0) then Egui::Color32.rgba(0xf5, 0xd0, 0x67, 220)
                else                 Egui::Color32.rgba(0xf2, 0x84, 0x7d, 220)
                end
        ui.painter.text(
          Egui::Pos2.new(frame.rect.max.x - fps_w - 10.0,
            frame.rect.min.y + 16.0),
          fps, ui.style.font_size, color)
      end
    end
  end
end

Egui.run(Crystal3DApp.new,
  title: "egui.cr — crystal 3D (rotating)", inspector: :hidden)
