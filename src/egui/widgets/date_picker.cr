# Windows 11 (WinUI)–style date picker: a field of three segments —
# day, month, year — in the ORDER the format spells them (default
# `%d.%m.%Y` → `15.09.2026`; `"%m/%d/%Y"` → `09/15/2026`). A click
# opens a flyout of wheel columns (one per segment, same order): the
# selection centered, the rest fading above/below, the wheel steps by
# one (no wrap), a click picks — edits land on a draft, settled by the
# footer's ✓ (fires the block once) or ✕ (dismisses). Days follow the
# picked month/year: a Feb 31 clamps to Feb 28/29.
#
#   ui.date_picker("born", @date) { |t| @date = t }
#   ui.date_picker("born", @date, format: "%m/%d/%Y") { |t| @date = t }

module Egui
  class DatePicker < WheelFieldPicker
    DEFAULT_SEGMENTS = [Segment.new(:day, ""), Segment.new(:month, "."),
                        Segment.new(:year, ".")]

    def initialize(id : String, value : Time,
                   format : String = "%d.%m.%Y",
                   &on_change : Time ->)
      super("date_picker", id, value, format, &on_change)
      @segments = DEFAULT_SEGMENTS if @segments.empty?
    end
  end
end
