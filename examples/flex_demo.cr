# egui.cr flexbox demo — чистый flex без приложения вокруг: каждый
# режим в своём контейнере плюс стресс-стенд A/B (тот же контент через
# flex и через обычный cursor-flow — сравнить FPS внизу окна).
#
# Зачем: переведённые на flex контейнеры в реальных приложениях
# тормозили (двухпроходный замер × вложенность); это песочница, где
# flex изолирован и измерим. FPS показывает сам фреймворк (EMA по
# dt), стресс-ползунок задаёт число чипов.
#
#   rake build:dev[flex_demo] && ./bin/html/flex_demo

require "../src/egui/driver_selector"

class FlexDemoApp < Egui::App
  BG   = Egui::Color32.rgb(0x16, 0x17, 0x1a)
  TEXT = Egui::Color32.rgb(0xe8, 0xe8, 0xe8)

  @themed = false
  # Стресс-стенд: сколько чипов и каким движком их класть.
  @stress_n = 400
  @use_flex = true
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
      ui.horizontal(wrap: false) do |h|
        h.label("FPS: #{ctx.fps.round(1)}")
        h.separator
        h.label("двухпроходный замер: дети ~2×/кадр, вложенность линейна")
      end
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

  # justify-content: панель инструментов — кнопки прибиты к краям,
  # поле поиска растёт на всё середину (grow при basis 0).
  private def justify_row(ui : Egui::Ui) : Nil
    ui.heading("justify-content: space-between + grow (basis 0)")
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

  # align-items: одна строка с разновысокими детьми — метки центруются
  # по общей линии, чекбокс прижат вниз (align-self: :end).
  private def align_row(ui : Egui::Ui) : Nil
    ui.heading("align-items: center + align-self: :end")
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

  # flex-wrap: чипы переносятся строками, gap по обеим осям.
  private def wrap_chips(ui : Egui::Ui) : Nil
    ui.heading("flex-wrap: wrap + gap 6×10")
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

  # Направления: row-reverse и column с явной высотой + justify :end.
  private def grow_columns(ui : Egui::Ui) : Nil
    ui.heading("direction: column (height 120) + row-reverse")
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
    ui.label("row-reverse: первый — справа; column c height: grow работает по вертикали.")
    ui.separator
  end

  # flex-basis (px и %) + order.
  private def basis_and_order(ui : Egui::Ui) : Nil
    ui.heading("basis 30% / 120px / auto + order")
    ui.flex(gap: 6.0, margin: Egui::Vec2.zero) do |f|
      f.child(basis: "30%", order: 1) { |c| c.label("basis 30% (order 1)") }
      f.child(basis: 120.0) { |c| c.label("basis 120") }
      f.child(order: -1) { |c| c.label("auto, order −1 → первым") }
    end
    ui.separator
  end

  # Вложенность: depth 3 (строка → колонка → строка) — тот случай,
  # что раньше давал 2^depth; теперь линейно.
  private def nested(ui : Egui::Ui) : Nil
    ui.heading("вложенность depth 3 (линейная стоимость)")
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

  # Стресс: N чипов одним движком — flex или обычный cursor-flow;
  # переключайте и сравнивайте FPS в шапке. Это изоляция «тормозит
  # flex или приложение»: здесь flex один и плоский.
  private def stress(ui : Egui::Ui) : Nil
    ui.heading("Стресс: A/B flex ↔ cursor-flow")
    ui.horizontal(wrap: false) do |h|
      h.label("чипов:")
      h.slider(@stress_n.to_f64, 100.0..5000.0) { |v| @stress_n = v.round.to_i }
      h.separator
      if h.button(@use_flex ? "движок: FLEX" : "движок: CURSOR-FLOW").clicked?
        @use_flex = !@use_flex
      end
    end
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

Egui.run(FlexDemoApp.new,
  title: "egui.cr — flexbox demo", inspector: :hidden)
