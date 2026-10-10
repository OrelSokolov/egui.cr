require "spec"
require "../src/egui"

TV_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def tv_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(TV_SCREEN, events, time))
  ui = Egui::Ui.new(ctx, Egui::Id.from("spec"), TV_SCREEN)
  yield ui
  ctx.end_frame
end

# Where a given text was painted this frame (the TextCmd pos is the
# text box's left-center — inside the band that paints it).
def tv_text_pos(ctx : Egui::Context, needle : String) : Egui::Pos2?
  ctx.painter.commands.select(Egui::TextCmd)
    .find { |c| c.text == needle }.try(&.pos)
end

def tv_store : Egui::ListStore
  s = Egui::ListStore.new(:string, :int)
  s.append("alpha", 3)
  s.append("beta", 1)
  s.append("gamma", 2)
  s
end

describe "ListStore" do
  it "appends, gets, sets, removes" do
    s = Egui::ListStore.new(:string, :int, :bool)
    s.row_count.should eq(0)
    r0 = s.append("a", 1, true)
    r1 = s.append("b", 2, false)
    r0.should eq(0)
    r1.should eq(1)
    s.row_count.should eq(2)
    s.get_string(0, 0).should eq("a")
    s.get_int(1, 1).should eq(2)
    s.get_bool(0, 2).should be_true
    s.set(0, 1, 9)
    s.get_int(0, 1).should eq(9)
    s.remove(0)
    s.row_count.should eq(1)
    s.get_string(0, 0).should eq("b")
    s.clear
    s.row_count.should eq(0)
  end

  it "validates types (int widens to float, mismatches raise)" do
    s = Egui::ListStore.new(:string, :float)
    s.append("pi", 3)
    s.get_f64(0, 1).should eq(3.0)
    expect_raises(ArgumentError) { s.append("x", "not a float") }
    expect_raises(ArgumentError) { s.set(0, 0, 42) }
    expect_raises(ArgumentError) { Egui::ListStore.new(:string, :pointer) }
  end

  it "inserts at a position" do
    s = tv_store
    s.insert(1, "middle", 0)
    s.get_string(1, 0).should eq("middle")
    s.row_count.should eq(4)
  end

  it "sorts by column without moving model rows" do
    s = tv_store
    s.set_sort_column(0, :ascending)
    s.display_count.should eq(3)
    (0...3).map { |i| s.get_string(s.display_row(i), 0) }.should eq(["alpha", "beta", "gamma"])
    s.set_sort_column(0, :descending)
    (0...3).map { |i| s.get_string(s.display_row(i), 0) }.should eq(["gamma", "beta", "alpha"])
    # model order untouched
    (0...3).map { |r| s.get_string(r, 0) }.should eq(["alpha", "beta", "gamma"])
    s.set_sort_column(nil)
    (0...3).map { |i| s.get_string(s.display_row(i), 0) }.should eq(["alpha", "beta", "gamma"])
  end

  it "sorts numbers numerically and keeps the sort stable" do
    s = tv_store
    s.set_sort_column(1, :ascending)
    (0...3).map { |i| s.get_int(s.display_row(i), 1) }.should eq([1, 2, 3])
    # stable: equal keys keep insertion order
    s2 = Egui::ListStore.new(:int)
    s2.append(1); s2.append(0); s2.append(1)
    s2.set_sort_column(0, :ascending)
    (0...3).map { |i| s2.get_int(s2.display_row(i), 0) }.should eq([0, 1, 1])
    s2.display_index(1).should eq(0)
  end

  it "takes a custom sort func" do
    s = tv_store
    s.set_sort_func(1) { |a, b| s.get_int(a, 1) <=> s.get_int(b, 1) }
    s.set_sort_column(1, :ascending)
    (0...3).map { |i| s.get_int(s.display_row(i), 1) }.should eq([1, 2, 3])
  end

  it "filters rows while keeping indices" do
    s = tv_store
    s.filter = ->(r : Int32) { s.get_string(r, 0).starts_with?("a") }
    s.display_count.should eq(1)
    s.get_string(s.display_row(0), 0).should eq("alpha")
    s.row_count.should eq(3)
    s.display_index(2).should be_nil
    # filter + sort compose
    s.append("amber", 7)
    s.set_sort_column(0, :ascending)
    (0...s.display_count).map { |i| s.get_string(s.display_row(i), 0) }
      .should eq(["alpha", "amber"])
    s.filter = nil
    s.display_count.should eq(4)
  end

  it "bumps the version on mutation" do
    s = tv_store
    v = s.version
    s.append("delta", 0)
    s.version.should be > v
  end
end

describe "TableView rendering" do
  it "paints the header and the visible rows" do
    ctx = Egui::Context.new
    s = tv_store
    tv = Egui::TableView.new("basic", s)
    tv.column("Name", 0)
    tv.column("N", 1, align: :right)
    2.times do |i|
      tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) }
    end
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Name")
    texts.should contain("alpha")
    texts.should contain("gamma")
  end

  it "virtualizes: 1000 rows paint only the viewport slice" do
    ctx = Egui::Context.new
    s = Egui::ListStore.new(:string)
    1000.times { |i| s.append("row-#{i}") }
    tv = Egui::TableView.new("big", s)
    tv.column("Name", 0)
    3.times do |i|
      tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) }
    end
    row_texts = ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).select { |t| t.starts_with?("row-") }
    # viewport is ~300px tall, rows ~27px → a dozen or so, never 1000
    row_texts.size.should be < 40
    row_texts.should contain("row-0")
    row_texts.should_not contain("row-999")
  end

  it "shows the empty text when there is nothing to display" do
    ctx = Egui::Context.new
    s = Egui::ListStore.new(:string)
    tv = Egui::TableView.new("empty", s)
    tv.column("Name", 0)
    tv.empty_text = "nothing here"
    2.times do |i|
      tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) }
    end
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("nothing here")
  end
end

describe "TableView selection" do
  it "clicks select a row (single mode)" do
    ctx = Egui::Context.new
    s = tv_store
    tv = Egui::TableView.new("sel", s)
    tv.column("Name", 0)
    tv.column("N", 1)
    2.times { |i| tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) } }

    beta = tv_text_pos(ctx, "beta").not_nil!
    tv_frame(ctx, [Egui::Event.pointer_moved(beta),
      Egui::Event.pointer_pressed(beta)], 0.048) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(beta)], 0.064) { |ui| tv.show(ui) }
    tv.selection.rows.should eq(Set{1})
    tv.selection.selected_row.should eq(1)

    # a plain click on another row replaces the selection
    gamma = tv_text_pos(ctx, "gamma").not_nil!
    tv_frame(ctx, [Egui::Event.pointer_moved(gamma),
      Egui::Event.pointer_pressed(gamma)], 0.080) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(gamma)], 0.096) { |ui| tv.show(ui) }
    tv.selection.rows.should eq(Set{2})
  end

  it "ctrl toggles and shift ranges (multiple mode)" do
    ctx = Egui::Context.new
    s = tv_store
    tv = Egui::TableView.new("multi", s)
    tv.column("Name", 0)
    tv.column("N", 1)
    tv.selection.mode = :multiple
    2.times { |i| tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) } }

    alpha = tv_text_pos(ctx, "alpha").not_nil!
    tv_frame(ctx, [Egui::Event.pointer_moved(alpha),
      Egui::Event.pointer_pressed(alpha)], 0.048) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(alpha)], 0.064) { |ui| tv.show(ui) }
    tv.selection.rows.should eq(Set{0})

    # ctrl+click on gamma adds it
    gamma = tv_text_pos(ctx, "gamma").not_nil!
    ctrl = Egui::Modifiers.new(ctrl: true)
    tv_frame(ctx, [Egui::Event.pointer_moved(gamma),
      Egui::Event.key_pressed(Egui::KeyCode::F12, ctrl),
      Egui::Event.pointer_pressed(gamma)], 0.080) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(gamma)], 0.096) { |ui| tv.show(ui) }
    tv.selection.rows.should eq(Set{0, 2})

    # shift+click on beta fills the anchor→clicked range (and keeps it)
    beta = tv_text_pos(ctx, "beta").not_nil!
    shift = Egui::Modifiers.new(shift: true)
    tv_frame(ctx, [Egui::Event.pointer_moved(beta),
      Egui::Event.key_pressed(Egui::KeyCode::F12, shift),
      Egui::Event.pointer_pressed(beta)], 0.112) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(beta)], 0.128) { |ui| tv.show(ui) }
    tv.selection.rows.should eq(Set{0, 1, 2})
  end

  it ":none ignores clicks" do
    ctx = Egui::Context.new
    s = tv_store
    tv = Egui::TableView.new("none", s)
    tv.column("Name", 0)
    tv.selection.mode = :none
    2.times { |i| tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) } }
    beta = tv_text_pos(ctx, "beta").not_nil!
    tv_frame(ctx, [Egui::Event.pointer_moved(beta),
      Egui::Event.pointer_pressed(beta)], 0.048) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(beta)], 0.064) { |ui| tv.show(ui) }
    tv.selection.rows.should be_empty
  end

  it "double-click activates the row" do
    ctx = Egui::Context.new
    s = tv_store
    tv = Egui::TableView.new("act", s)
    tv.column("Name", 0)
    activated = [] of Int32
    tv.on_activate { |r| activated << r }
    2.times { |i| tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) } }

    beta = tv_text_pos(ctx, "beta").not_nil!
    tv_frame(ctx, [Egui::Event.pointer_moved(beta),
      Egui::Event.pointer_pressed(beta)], 0.048) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(beta)], 0.064) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_pressed(beta)], 0.200) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(beta)], 0.216) { |ui| tv.show(ui) }
    activated.should eq([1])
  end
end

describe "TableView sorting and resizing" do
  it "header clicks sort ascending then descending" do
    ctx = Egui::Context.new
    s = tv_store
    tv = Egui::TableView.new("sort", s)
    tv.column("Name", 0)
    tv.column("N", 1)
    2.times { |i| tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) } }

    name_h = tv_text_pos(ctx, "Name").not_nil!
    tv_frame(ctx, [Egui::Event.pointer_moved(name_h),
      Egui::Event.pointer_pressed(name_h)], 0.048) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(name_h)], 0.064) { |ui| tv.show(ui) }
    s.sort_column.should eq({0, :ascending})
    # the view now paints rows in sorted order
    tv_frame(ctx, time: 0.080) { |ui| tv.show(ui) }
    first_row = tv_text_pos(ctx, "alpha").not_nil!
    second_row = tv_text_pos(ctx, "beta").not_nil!
    first_row.y.should be < second_row.y

    tv_frame(ctx, [Egui::Event.pointer_moved(name_h),
      Egui::Event.pointer_pressed(name_h)], 0.096) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(name_h)], 0.112) { |ui| tv.show(ui) }
    s.sort_column.should eq({0, :descending})
  end

  it "dragging a header boundary resizes the columns and persists" do
    ctx = Egui::Context.new
    s = tv_store
    tv = Egui::TableView.new("resize", s)
    tv.column("Name", 0)
    tv.column("N", 1)
    2.times { |i| tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) } }

    # Two equal columns over 400px: the boundary sits at x=200.
    grip = Egui::Pos2.new(200.0, 12.0)
    tv_frame(ctx, [Egui::Event.pointer_moved(grip),
      Egui::Event.pointer_pressed(grip)], 0.048) { |ui| tv.show(ui) }
    moved = Egui::Pos2.new(250.0, 12.0)
    tv_frame(ctx, [Egui::Event.pointer_moved(moved)], 0.064) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(moved)], 0.080) { |ui| tv.show(ui) }

    id = Egui::Id.from("table_view/resize")
    ctx.memory.data.get_int(id.child(0x5000_u64), 0).should eq(2)
    w0 = ctx.memory.data.get_f64(id.child(0x5001_u64), 0.0)
    w1 = ctx.memory.data.get_f64(id.child(0x5002_u64), 0.0)
    w0.should be_close(250.0, 1.0)
    w1.should be_close(150.0, 1.0)

    # …and the next frame keeps the resized layout (the second column
    # header "N" now starts at the dragged boundary)
    tv_frame(ctx, time: 0.096) { |ui| tv.show(ui) }
    tv_text_pos(ctx, "N").not_nil!.x.should be >= 250.0
  end
end

describe "TableView keyboard" do
  it "arrows walk the selection, Enter activates" do
    ctx = Egui::Context.new
    s = tv_store
    tv = Egui::TableView.new("keys", s)
    tv.column("Name", 0)
    tv.column("N", 1)
    activated = [] of Int32
    tv.on_activate { |r| activated << r }
    2.times { |i| tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) } }

    # Click alpha — also asks for focus (lands the next frame).
    alpha = tv_text_pos(ctx, "alpha").not_nil!
    tv_frame(ctx, [Egui::Event.pointer_moved(alpha),
      Egui::Event.pointer_pressed(alpha)], 0.048) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(alpha)], 0.064) { |ui| tv.show(ui) }
    tv.selection.rows.should eq(Set{0})

    tv_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::Down)], 0.080) { |ui| tv.show(ui) }
    tv.selection.rows.should eq(Set{1})
    tv_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::Down)], 0.096) { |ui| tv.show(ui) }
    tv.selection.rows.should eq(Set{2})
    tv_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::Up)], 0.112) { |ui| tv.show(ui) }
    tv.selection.rows.should eq(Set{1})

    tv_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::Enter)], 0.128) { |ui| tv.show(ui) }
    activated.should eq([1])
  end

  it "Ctrl+A selects everything (multiple mode)" do
    ctx = Egui::Context.new
    s = tv_store
    tv = Egui::TableView.new("selectall", s)
    tv.column("Name", 0)
    tv.selection.mode = :multiple
    2.times { |i| tv_frame(ctx, time: 0.016 * (i + 1)) { |ui| tv.show(ui) } }

    alpha = tv_text_pos(ctx, "alpha").not_nil!
    tv_frame(ctx, [Egui::Event.pointer_moved(alpha),
      Egui::Event.pointer_pressed(alpha)], 0.048) { |ui| tv.show(ui) }
    tv_frame(ctx, [Egui::Event.pointer_released(alpha)], 0.064) { |ui| tv.show(ui) }

    ctrl_a = Egui::Modifiers.new(ctrl: true)
    tv_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::A, ctrl_a)], 0.080) { |ui| tv.show(ui) }
    tv.selection.rows.should eq(Set{0, 1, 2})
  end
end
