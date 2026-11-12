# Headless benchmark of the flexbox demo (examples/flex_demo.cr): the
# same sections, driven by Egui::Bench instead of the sokol backend.
#   crystal build bench/flex_bench.cr -o bin/benchmarks/flex_bench \
#     --link-flags "-L$(pwd)/lib" && ./bin/benchmarks/flex_bench
# FLEX_N / FLEX_FLOW=1 control the stress stand (chips count, engine).

require "../src/egui"
require "../src/egui/driver/sokol"

class FlexBenchApp < Egui::App
  BG   = Egui::Color32.rgb(0x16, 0x17, 0x1a)
  TEXT = Egui::Color32.rgb(0xe8, 0xe8, 0xe8)

  @themed = false
  @stress_n : Int32 = (ENV["FLEX_N"]? || "400").to_i
  @use_flex : Bool = ENV["FLEX_FLOW"]? != "1"
  @input = ""

  def update(ctx : Egui::Context) : Nil
    unless @themed
      Egui::DefaultTheme.build("flex_demo", dark: true) do |v|
        v.window_fill = BG
        v.panel_fill = BG
        v.text_color = TEXT
        v.window_stroke = BG
      end.tap { |t| ctx.theme = t }
      @themed = true
    end

    ctx.central_panel do |ui|
      ui.heading("flexbox — все режимы")
      ui.separator
      justify_row(ui)
      align_row(ui)
      wrap_chips(ui)
      grow_columns(ui)
      basis_and_order(ui)
      nested(ui)
      stress(ui)
    end
  end

  private def justify_row(ui : Egui::Ui) : Nil
    ui.flex(justify: :space_between, gap: 8.0, margin: Egui::Vec2.zero) do |f|
      f.child { |c| c.button("◀ Назад") }
      f.child(grow: 1.0, basis: 0.0) do |c|
        c.text_edit_singleline(@input) { |v| @input = v }
      end
      f.child { |c| c.button("Вперёд ▶") }
      f.child { |c| c.button("⋯") }
    end
    ui.separator
  end

  private def align_row(ui : Egui::Ui) : Nil
    ui.flex(align: :center, gap: 10.0, margin: Egui::Vec2.zero,
      align_content: :start) do |f|
      f.child { |c| c.label("метка по центру линии") }
      f.child(align_self: :end) { |c| c.checkbox(@use_flex, "align-self: end") { |v| @use_flex = v } }
      f.child { |c| c.label("короткая") }
      f.child(align_self: :start) { |c| c.label("start") }
      f.child { |c| c.button("высокая кнопка\nв две строки") }
    end
    ui.separator
  end

  private def wrap_chips(ui : Egui::Ui) : Nil
    ui.flex(wrap: :wrap, gap: Egui::Vec2.new(6.0, 10.0),
      margin: Egui::Vec2.zero, align_content: :start) do |f|
      {"раст", "dev", "prod", "hot-reload", "ecss", "exml", "sokol",
       "crystal", "flex", "wrap", "justify", "align", "grow",
       "shrink", "basis", "order"}.each do |tag|
        f.child { |c| c.button(tag) }
      end
    end
    ui.separator
  end

  private def grow_columns(ui : Egui::Ui) : Nil
    ui.horizontal(wrap: false) do |h|
      h.flex(direction: :column, height: 120.0, justify: :space_between,
        gap: 4.0, margin: Egui::Vec2.zero, width: "46%") do |f|
        f.child { |c| c.label("верх") }
        f.child(grow: 1.0, basis: 0.0) { |c| c.label("…растянутый центр…") }
        f.child { |c| c.label("низ") }
      end
      h.flex(direction: :row_reverse, gap: 6.0, margin: Egui::Vec2.zero,
        width: "50%") do |f|
        f.child { |c| c.button("первый") }
        f.child { |c| c.button("второй") }
        f.child { |c| c.button("третий") }
      end
    end
    ui.separator
  end

  private def basis_and_order(ui : Egui::Ui) : Nil
    ui.flex(gap: 6.0, margin: Egui::Vec2.zero) do |f|
      f.child(basis: "30%", order: 1) { |c| c.label("basis 30% (order 1)") }
      f.child(basis: 120.0) { |c| c.label("basis 120") }
      f.child(order: -1) { |c| c.label("auto, order −1 → первым") }
    end
    ui.separator
  end

  private def nested(ui : Egui::Ui) : Nil
    ui.flex(gap: 8.0, margin: Egui::Vec2.zero) do |outer|
      outer.child(grow: 1.0, basis: 0.0) do |col|
        col.flex(direction: :column, gap: 4.0, margin: Egui::Vec2.zero) do |mid|
          mid.child do |row|
            row.flex(gap: 4.0, margin: Egui::Vec2.zero) do |leaf|
              leaf.child { |c| c.button("a1") }
              leaf.child { |c| c.button("a2") }
            end
          end
          mid.child do |row|
            row.flex(gap: 4.0, margin: Egui::Vec2.zero) do |leaf|
              leaf.child { |c| c.button("b1") }
              leaf.child { |c| c.button("b2") }
              leaf.child { |c| c.button("b3") }
            end
          end
        end
      end
      outer.child(grow: 1.0, basis: 0.0) do |col|
        col.flex(direction: :column, gap: 4.0, margin: Egui::Vec2.zero) do |mid|
          3.times do |i|
            mid.child do |row|
              row.flex(justify: :space_between, margin: Egui::Vec2.zero) do |leaf|
                leaf.child { |c| c.label("row #{i}") }
                leaf.child { |c| c.button("…") }
              end
            end
          end
        end
      end
    end
    ui.separator
  end

  private def stress(ui : Egui::Ui) : Nil
    n = @stress_n
    if @use_flex
      ui.flex(wrap: :wrap, gap: Egui::Vec2.new(4.0, 6.0),
        margin: Egui::Vec2.zero, align_content: :start) do |f|
        n.times { |i| f.child { |c| c.label("чип #{i}") } }
      end
    else
      ui.horizontal(wrap: true) do |row|
        n.times { |i| row.label("чип #{i}") }
      end
    end
  end
end

app = FlexBenchApp.new
Egui::Bench.run(app, width: 1024.0, height: 768.0, warmup: 5, frames: 20)
