# egui-cr appear — демо-пруф appear-переходов (инкремент 2 плана
# plans/NATIVE_HTML_DEMO.md §3.2): свойства `appear:`/`appear-delay:`
# поверх painter-transform, порт именованных переходов Raven
# (examples/animations/animations.xml).
#
# Слева — кнопки переходов (как у Raven): нажатие перепроявляет
# центральную карточку выбранным переходом. «Play them all» — все три
# панели разом. Справа — приходящие/уходящие карточки со стэггером
# (appear-delay по индексу).
#
# Перепроявление: карточка скрывается на один кадр — end-frame
# pruning сносит её appear-состояние, и на следующем кадре переход
# играется заново (семантика «первого появления»).

require "../src/egui/driver_selector"

class AppearApp < Egui::App
  BG     = Egui::Color32.rgb(0x16, 0x17, 0x1a)
  PANEL  = Egui::Color32.rgb(0x1f, 0x21, 0x26)
  STROKE = Egui::Color32.rgb(0x33, 0x36, 0x3d)
  TEXT   = Egui::Color32.rgb(0xe8, 0xe8, 0xe8)
  ACCENT = Egui::Color32.rgb(0x3b, 0x82, 0xf6)

  TRANSITIONS = {"Fade", "Pop", "Zoom", "FlyUp", "FlyDown", "FlyLeft",
                 "FlyRight", "Drop", "SlideLeft", "SlideRight"}

  @themed = false
  @current = "Pop"
  @cards = ["one", "two", "three"]
  @next_card = 4
  # Перепроявление: до этого момента карточка сцены не эмитится —
  # состояние сносится, следующий кадр играет переход заново.
  @hide_until = -1.0

  def update(ctx : Egui::Context) : Nil
    theme_once(ctx)
    now = ctx.input.time

    ctx.central_panel do |ui|
      # Три колонки (переключатель / сцена / карточки) — ui.columns,
      # чтобы боковые панели не растягивались на всю ширину ряда.
      ui.columns(3) do |cols|
        left, stage, right = cols

        # -- transition picker ----------------------------------------------
        left.box(:column, fill: PANEL, stroke: STROKE, rounding: 14.0,
          margin: Egui::Vec2.new(4.0, 4.0), appear: "fly-right") do |l|
          label(l, "Transitions", 17.0)
          TRANSITIONS.each do |name|
            if l.button(name, id: "btn-#{name}").clicked?
              @current = name
              @hide_until = now + 1.0 / 30.0
            end
          end
          if l.button("Play them all", id: "btn-all").clicked?
            @hide_until = now + 1.0 / 30.0
          end
        end

        # -- the stage --------------------------------------------------------
        stage.box(:column, fill: PANEL, stroke: STROKE, rounding: 14.0,
          margin: Egui::Vec2.new(4.0, 4.0), appear: "drop",
          appear_delay: 0.08) do |st|
          if now < @hide_until
            # один кадр пустоты — карточка ниже не эмитится
            label(st, "…", 22.0)
          else
            st.box(:column, fill: ACCENT, rounding: 22.0,
              margin: Egui::Vec2.new(18.0, 18.0),
              appear: kebab(@current)) do |card|
              card.rich(Egui::RichText.new(@current).size(26.0)
                .color(Egui::Color32.rgb(255, 255, 255)))
              card.rich(Egui::RichText
                .new("Choose a transition on the left")
                .color(Egui::Color32.rgba(255, 255, 255, 200)))
            end
          end
        end

        # -- cards that come and go ------------------------------------------
        right.box(:column, fill: PANEL, stroke: STROKE, rounding: 14.0,
          margin: Egui::Vec2.new(4.0, 4.0), appear: "fly-left",
          appear_delay: 0.16) do |r|
          r.box(:row, wrap: false,
            margin: Egui::Vec2.new(0.0, 0.0)) do |bar|
            bar.rich(Egui::RichText.new("Cards").size(17.0))
            if bar.button("Add", id: "btn-add").clicked?
              @cards << "card #{@next_card}"
              @next_card += 1
            end
            if bar.button("Remove", id: "btn-remove").clicked? &&
               !@cards.empty?
              @cards.pop
            end
          end
          r.box(:column, wrap: false,
            margin: Egui::Vec2.new(0.0, 0.0)) do |list|
            @cards.each_with_index do |name, i|
              # стэггер: каждая следующая карточка стартует позже
              list.box(:row, fill: Egui::Color32.rgb(0x27, 0x2a, 0x31),
                rounding: 10.0, margin: Egui::Vec2.new(4.0, 4.0),
                appear: "pop", appear_delay: i * 0.06) do |row|
                row.rich(Egui::RichText.new(name).size(13.0))
              end
            end
          end
        end
      end
    end
  end

  private def kebab(pascal : String) : String
    pascal.gsub(/([a-z\d])([A-Z])/, "\\1-\\2").downcase
  end

  private def theme_once(ctx : Egui::Context) : Nil
    return if @themed
    Egui::DefaultTheme.build("appear", dark: true) do |v|
      v.window_fill = BG
      v.panel_fill = BG
      v.text_color = TEXT
      v.window_stroke = BG
    end.tap { |t| ctx.theme = t }
    @themed = true
  end

  private def label(ui : Egui::Ui, text : String, size : Float64) : Nil
    ui.rich(Egui::RichText.new(text).size(size))
  end
end

Egui.run(AppearApp.new,
  title: "egui.cr — appear transitions", inspector: :hidden)
