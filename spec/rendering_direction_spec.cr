require "spec"
require "../src/egui"

RD_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 600.0))

def rd_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(RD_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

# rendering_direction (dialogue mode): a :up region lays its widgets
# out bottom-first — every widget flips, because every widget places
# itself through Ui#allocate_space. :down is the default everywhere.
describe "rendering_direction" do
  it "defaults to :down" do
    ctx = Egui::Context.new
    rd_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.rendering_direction.should eq(:down)
        ui.scope do |sub|
          sub.rendering_direction.should eq(:down)
        end
      end
    end
  end

  it ":up stacks widgets upward from the region's bottom edge" do
    ctx = Egui::Context.new
    r1 = r2 = nil

    rd_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.with_rendering_direction(:up) do |sub|
          sub.rendering_direction.should eq(:up)
          region_bottom = sub.max_rect.bottom
          r1 = sub.add_sized(Egui::Vec2.new(50.0, 20.0),
            Egui::Label.new("first")).rect
          r2 = sub.add_sized(Egui::Vec2.new(50.0, 20.0),
            Egui::Label.new("second")).rect
          # the first widget sits ON the bottom edge…
          r1.not_nil!.bottom.should eq(region_bottom)
        end
      end
    end

    a, b = r1.not_nil!, r2.not_nil!
    # …and the second one is stacked strictly ABOVE it (same column,
    # separated by the item spacing)
    b.bottom.should be < a.top
    b.left.should eq(a.left)
    b.width.should eq(a.width)
  end

  it "inherits into scopes: a scope in an up region flows up too" do
    ctx = Egui::Context.new
    inner_rect = region_bottom = nil

    rd_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.with_rendering_direction(:up) do |sub|
          region_bottom = sub.max_rect.bottom
          sub.scope do |deep|
            deep.rendering_direction.should eq(:up)
            inner_rect = deep.add_sized(Egui::Vec2.new(50.0, 20.0),
              Egui::Label.new("x")).rect
          end
        end
      end
    end

    # the scope's first widget sits at the scope's bottom edge
    inner_rect.not_nil!.bottom.should eq(region_bottom.not_nil!)
  end

  it "frames in an up region grow upward from the flow line" do
    ctx = Egui::Context.new
    body = outer = nil
    m = Egui::Vec2.new(4.0, 4.0)

    rd_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.with_rendering_direction(:up) do |sub|
          line = sub.cursor.y
          outer = sub.frame(margin: m) do |f|
            body = f.add_sized(Egui::Vec2.new(50.0, 20.0),
              Egui::Label.new("bubble")).rect
          end
          # the frame hugs the flow line from above
          outer.not_nil!.bottom.should eq(line)
          outer.not_nil!.top.should be < line
        end
      end
    end

    # the frame's contents start at its inner bottom (bottom margin in)
    body.not_nil!.bottom.should eq(outer.not_nil!.bottom - m.y)
    body.not_nil!.top.should be < body.not_nil!.bottom
  end

  it "horizontal rows in an up region grow up, not down" do
    ctx = Egui::Context.new
    in_row = after_line = nil

    rd_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.with_rendering_direction(:up) do |sub|
          sub.add_sized(Egui::Vec2.new(50.0, 20.0), Egui::Label.new("msg"))
          line = sub.cursor.y
          sub.horizontal do |row|
            in_row = row.add_sized(Egui::Vec2.new(30.0, 16.0),
              Egui::Button.new("ok")).rect
          end
          after_line = sub.cursor.y
          line_value = line
          # the row's widget stays ABOVE the flow line…
          in_row.not_nil!.bottom.should be <= line_value
          in_row.not_nil!.top.should be < line_value
          # …and the flow continues above the row
          after_line.not_nil!.should be < line_value
        end
      end
    end
  end

  it "available_height in an up region measures upward" do
    ctx = Egui::Context.new
    rd_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.with_rendering_direction(:up) do |sub|
          full = sub.available_height
          full.should be > 0.0
          sub.add_sized(Egui::Vec2.new(50.0, 20.0), Egui::Label.new("x"))
          sub.available_height.should be < full
        end
      end
    end
  end
end
