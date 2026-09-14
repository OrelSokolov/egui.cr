# Port of egui_upstream/crates/egui/src/sense.rs.
#
# What kind of interaction a widget is interested in. egui:
# `Sense { click, drag }` as a bitset; labels are `Sense::hover()`
# (no flags — just hoverable by being in `Memory`), buttons are
# `Sense::click()`.

module Egui
  @[Flags]
  enum Sense
    Click
    Drag
    # egui `Sense::focusable`: the widget can take keyboard focus and
    # participates in Tab/arrow navigation.
    Focusable

    def self.none : Sense
      Sense::None
    end

    def self.click : Sense
      Sense::Click
    end

    def self.drag : Sense
      Sense::Drag
    end

    def self.click_and_drag : Sense
      Sense::Click | Sense::Drag
    end

    def clickable? : Bool
      click?
    end

    def draggable? : Bool
      drag?
    end
  end
end
