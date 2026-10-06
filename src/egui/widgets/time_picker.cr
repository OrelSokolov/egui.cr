# Windows 11 (WinUI)–style time picker: a field of hour : minute :
# second segments (the order and separators come from the format,
# default `%H:%M:%S`) opening a wheel flyout — faded H/M/S caps label
# the columns, the selection is centered, the wheel steps by one (no
# wrap), a click picks; the footer's ✓ commits the draft (fires the
# block once), ✕ dismisses it. See `DatePicker` (the date twin) and
# `WheelFieldPicker` (the engine).
#
#   ui.time_picker("alarm", @time) { |t| @time = t }
#   ui.time_picker("alarm", @time, format: "%H:%M") { |t| @time = t }

module Egui
  class TimePicker < WheelFieldPicker
    DEFAULT_SEGMENTS = [Segment.new(:hour, ""), Segment.new(:minute, ":"),
                        Segment.new(:second, ":")]

    def initialize(id : String, value : Time,
                   format : String = "%H:%M:%S",
                   &on_change : Time ->)
      super("time_picker", id, value, format, &on_change)
      @segments = DEFAULT_SEGMENTS if @segments.empty?
    end
  end
end
