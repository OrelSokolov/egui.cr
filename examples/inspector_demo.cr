# Widget Inspector demo — `Sokol.run(…, inspector: :on)`.
#
# Right-click any widget → «Inspect» opens the bottom panel:
# * «Элемент» — per-element style overrides (live, the top cascade
#   layer), with the same База/Hover/Active switch as the class tab —
#   one `background` key, state rules like CSS pseudo-classes;
# * «Класс» — the widget's stylesheet class rules (button, checkbox…),
#   base state plus :hover/:active overlays.
# F12 toggles the panel. The Spinner at the bottom is the honest
# "no stylable properties" case.

require "../src/egui"
require "../src/egui/backend/sokol"

class InspectorDemoApp < Egui::App
  @speed = 0.4
  @checked = false
  @progress = 0.7

  def update(ctx : Egui::Context) : Nil
    ctx.window("Inspector demo", Egui::Pos2.new(24.0, 24.0),
      width: 560.0) do |ui|
      ui.heading("Инспектор стилей")
      ui.label("Правый клик по любому виджету → Inspect. F12 — панель.")
      ui.separator

      ui.label("Кнопки (явные id):")
      ui.horizontal do |row|
        row.button("Сохранить", id: "save")
        row.button("Отмена", id: "cancel")
        row.button("Без id") # auto id — 6 случайных букв
      end

      ui.separator
      ui.label("Прочее:")
      ui.hyperlink_to("egui — inspiration", "https://github.com/emilk/egui")
      ui.checkbox(@checked, "Чекбокс", id: "agree") { |v| @checked = v }
      ui.slider(@speed, 0.0..2.0, "Скорость", id: "speed") { |v| @speed = v }
      ui.progress_bar(@progress, text: "Прогресс")
      ui.selectable(true, "Выбранный пункт", id: "sel")
      ui.toggle_button(@checked, "Тумблер", id: "toggle") { |v| @checked = v }

      ui.separator
      ui.label("Не-стилизуемый виджет (spinner):")
      ui.horizontal do |row|
        row.spinner
        row.label("…у него нет stylable-свойств")
      end
    end
  end
end

Egui::Backend::Sokol.run(InspectorDemoApp.new,
  title: "egui-cr — inspector demo", inspector: :on)
