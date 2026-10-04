# Viewport3D specs (headless — the paint command is inspectable
# without a GPU): camera math stability, Mesh3D packing, command
# emission with clip/viewport propagation, orbit interaction.
require "spec"
require "../src/egui"

VP_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))

def vp_step(ctx : Egui::Context, viewport : Egui::Viewport3D,
            events : Array(Egui::Event),
            &app : Egui::Context, Egui::Response ->) : Nil
  raw = Egui::RawInput.new(VP_SCREEN, events, 0.016)
  ctx.begin_frame(raw)
  response = nil
  ctx.central_panel do |ui|
    response = viewport.show(ui) { |_frame| }
  end
  ctx.end_frame
  app.call(ctx, response.not_nil!)
end

def vp_probe(ctx : Egui::Context, viewport : Egui::Viewport3D) : Egui::Rect
  rect = nil
  vp_step(ctx, viewport, [] of Egui::Event) { |_c, r| rect = r.rect }
  rect.not_nil!
end

describe Egui::Mat4 do
  it "identity transforms a point to itself" do
    v = Egui::Vec3.new(1.0, -2.0, 3.0)
    Egui::Mat4.identity.transform(v).x.should be_close(1.0, 1e-6)
    Egui::Mat4.identity.transform(v).y.should be_close(-2.0, 1e-6)
    Egui::Mat4.identity.transform(v).z.should be_close(3.0, 1e-6)
  end

  it "rotate_y maps +z to +x after a quarter turn" do
    r = Egui::Mat4.rotate_y(Math::PI / 2.0)
    out = r.transform(Egui::Vec3.new(0.0, 0.0, 1.0))
    out.x.should be_close(1.0, 1e-5)
    out.z.should be_close(0.0, 1e-5)
  end

  it "perspective maps the camera-axis point to the NDC center" do
    cam = Egui::Camera3D.new(yaw: 0.0, pitch: 0.0, distance: 4.0)
    ndc = (cam.projection(1.0) * cam.view)
      .transform(Egui::Vec3.new(0.0, 0.0, 0.0))
    ndc.x.should be_close(0.0, 1e-5)
    ndc.y.should be_close(0.0, 1e-5)
    (-1.0..1.0).should contain(ndc.z)
  end

  it "project lands the target at the viewport center" do
    cam = Egui::Camera3D.new(yaw: 0.7, pitch: 0.4, distance: 5.0)
    rect = Egui::Rect.from_min_size(Egui::Pos2.new(100.0, 50.0),
      Egui::Vec2.new(400.0, 300.0))
    p = cam.project(Egui::Vec3.zero, rect).not_nil!
    p.x.should be_close(300.0, 1e-3)
    p.y.should be_close(200.0, 1e-3)
  end

  it "project returns nil behind the camera" do
    cam = Egui::Camera3D.new(yaw: 0.0, pitch: 0.0, distance: 4.0)
    # a point BEHIND the eye (further from the target than the camera)
    cam.project(Egui::Vec3.new(0.0, 0.0, 6.0),
      Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(100.0, 100.0)))
      .should be_nil
  end
end

describe Egui::Mesh3D do
  it "packs vertices SoA (12 bytes f32 xyz + 4 bytes rgba)" do
    m = Egui::Mesh3D.new(:triangles)
    m.triangle(Egui::Vec3.new(0.0, 0.0, 0.0), Egui::Vec3.new(1.0, 0.0, 0.0),
      Egui::Vec3.new(0.0, 1.0, 0.0), Egui::Color32.rgb(255, 128, 0))
    m.vertex_count.should eq 3
    b = m.bytes
    b.size.should eq 48
    x = IO::ByteFormat::LittleEndian.decode(Float32, b[16, 4])
    x.should eq 1.0f32
    b[12].should eq 255 # r
    b[13].should eq 128 # g
    b[14].should eq 0   # b
    b[15].should eq 255 # a
  end

  it "clear resets the batch" do
    m = Egui::Mesh3D.new(:lines)
    m.line(Egui::Vec3.zero, Egui::Vec3.new(1, 1, 1),
      Egui::Color32.rgb(255, 255, 255))
    m.vertex_count.should eq 2
    m.clear
    m.vertex_count.should eq 0
    m.bytes.size.should eq 0
  end
end

describe Egui::Mesh3D::Faces do
  it "emits flat shading as one color per face" do
    faces = Egui::Mesh3D::Faces.new
    faces.add(Egui::Vec3.new(0, 0, 0), Egui::Vec3.new(1, 0, 0),
      Egui::Vec3.new(0, 1, 0))
    mesh = Egui::Mesh3D.new(:triangles)
    light = Egui::Vec3.new(0, 0, 1)
    faces.emit(mesh, Egui::Color32.rgb(255, 255, 255), light)
    mesh.vertex_count.should eq 3
    b = mesh.bytes
    c1 = {b[12], b[13], b[14]}
    c2 = {b[28], b[29], b[30]}
    c3 = {b[44], b[45], b[46]}
    c1.should eq c2
    c2.should eq c3
    # face normal is +z, aligned with the light — brighter than ambient
    c1[0].should be > 80
  end

  it "emits smooth shading as per-vertex gradients" do
    # Two faces sharing the edge (0,0,0)-(1,0,0) with different
    # normals: smooth mode averages them per shared vertex, so the
    # second face's colors differ vertex-to-vertex.
    faces = Egui::Mesh3D::Faces.new
    faces.add(Egui::Vec3.new(0, 0, 0), Egui::Vec3.new(1, 0, 0),
      Egui::Vec3.new(0, 1, 0))
    faces.add(Egui::Vec3.new(0, 0, 0), Egui::Vec3.new(1, 0, 0),
      Egui::Vec3.new(0, 0, 1))
    mesh = Egui::Mesh3D.new(:triangles)
    faces.emit(mesh, Egui::Color32.rgb(255, 255, 255),
      Egui::Vec3.new(0, 0, 1), smooth: true)
    mesh.vertex_count.should eq 6
    b = mesh.bytes
    colors = (0...6).map { |i| {b[i * 16 + 12], b[i * 16 + 13], b[i * 16 + 14]} }
    # vertex (1,0,0) is shared by both faces (averaged normal, tilted
    # towards the light) while (0,0,1) belongs to one face only — the
    # per-vertex gradient the rasterizer interpolates.
    colors[4].should_not eq colors[5]
    colors[4][0].should be > colors[5][0]
  end
end

describe Egui::Viewport3D do
  it "emits a Mesh3DCmd with the widget rect as viewport and clip" do
    ctx = Egui::Context.new
    vp = Egui::Viewport3D.new("t", Egui::Vec2.new(400.0, 300.0))
    rect = nil
    raw = Egui::RawInput.new(VP_SCREEN, [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      vp.show(ui) do |frame|
        mesh = Egui::Mesh3D.new(:triangles)
        mesh.triangle(Egui::Vec3.new(-1, -1, 0), Egui::Vec3.new(1, -1, 0),
          Egui::Vec3.new(0, 1, 0), Egui::Color32.rgb(255, 255, 255))
        frame.draw(mesh)
      end
    end
    ctx.end_frame
    cmds = ctx.painter.commands.select(Egui::Mesh3DCmd)
    cmds.size.should eq 1
    cmd = cmds.first
    cmd.data.size.should eq 48
    cmd.primitive.should eq :triangles
    cmd.blend?.should be_false
    cmd.viewport.should eq rect.not_nil! if (rect = vp_probe(Egui::Context.new, vp))
    cmd.clip.intersects?(cmd.viewport).should be_true
  end

  it "does not emit a command for an empty mesh" do
    ctx = Egui::Context.new
    vp = Egui::Viewport3D.new("t", Egui::Vec2.new(400.0, 300.0))
    vp_step(ctx, vp, [] of Egui::Event) { |_c, _r| }
    # background rect may be painted, but no Mesh3DCmd
    ctx.painter.commands.select(Egui::Mesh3DCmd).should be_empty
  end

  it "line_aa draws :lines meshes as MSAA 2D strokes, not GL lines" do
    ctx = Egui::Context.new
    vp = Egui::Viewport3D.new("t", Egui::Vec2.new(400.0, 300.0))
    vp.line_aa = true
    lines = nil
    raw = Egui::RawInput.new(VP_SCREEN, [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      vp.show(ui) do |frame|
        mesh = Egui::Mesh3D.new(:lines)
        mesh.line(Egui::Vec3.new(0, 0, 0), Egui::Vec3.new(1, 1, 0),
          Egui::Color32.rgb(255, 255, 255))
        frame.draw(mesh)
      end
    end
    ctx.end_frame
    ctx.painter.commands.select(Egui::Mesh3DCmd).should be_empty
    lines = ctx.painter.commands.select(Egui::LineCmd)
    # halo + core stroke per segment
    lines.size.should eq 2
    lines[0].width.should be > lines[1].width
  end

  it "line_aa=false keeps :lines meshes in the 3D pass" do
    ctx = Egui::Context.new
    vp = Egui::Viewport3D.new("t", Egui::Vec2.new(400.0, 300.0))
    vp.line_aa = false
    raw = Egui::RawInput.new(VP_SCREEN, [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      vp.show(ui) do |frame|
        mesh = Egui::Mesh3D.new(:lines)
        mesh.line(Egui::Vec3.new(0, 0, 0), Egui::Vec3.new(1, 1, 0),
          Egui::Color32.rgb(255, 255, 255))
        frame.draw(mesh)
      end
    end
    ctx.end_frame
    cmds = ctx.painter.commands.select(Egui::Mesh3DCmd)
    cmds.size.should eq 1
    cmds.first.primitive.should eq :lines
    ctx.painter.commands.select(Egui::LineCmd).should be_empty
  end

  it "drag orbits the camera and wheel zooms" do
    ctx = Egui::Context.new
    vp = Egui::Viewport3D.new("t", Egui::Vec2.new(400.0, 300.0))
    rect = vp_probe(ctx, vp)
    yaw0 = vp.camera.yaw
    dist0 = vp.camera.distance

    center = rect.center
    inside = Egui::Pos2.new(center.x, center.y)
    # A drag classifies only after the press frame — press first, then
    # move in a later frame while the button is still held.
    vp_step(ctx, vp, [
      Egui::Event.pointer_moved(inside),
      Egui::Event.pointer_pressed(inside),
    ]) { |_c, _r| }
    vp_step(ctx, vp, [
      Egui::Event.pointer_moved(Egui::Pos2.new(inside.x + 40.0, inside.y + 10.0)),
    ]) { |_c, _r| }
    vp.camera.yaw.should_not eq yaw0

    wheel = [Egui::Event.scroll(Egui::Vec2.new(0.0, -120.0))]
    vp_step(ctx, vp, wheel) { |_c, _r| }
    vp.camera.distance.should be < dist0
  end
end
