# A label that scrolls — "a TextArea without editing": the text lays
# out exactly like the TextArea does (soft word-wrap against the
# region width — the two can never disagree about where lines break,
# because this widget IS a read-only frameless TextArea under the
# hood), grows with its content, and once the content is taller than
# `max_height` it scrolls: wheel, touch drag, kinetic fling and the
# scrollbar all come from the delegate.
#
# Read-only means no caret, no keyboard pass and no soft keyboard;
# click-drag selection, double-click word select, Ctrl+C and the
# Copy / Select all context menu keep working.
#
#   ui.scrolledlabel(text)                    # grows with the text
#   ui.scrolledlabel(text, max_height: 200.0) # scrolls past 200pt

module Egui
  class ScrolledLabel
    include Widget

    def initialize(@text : String, @max_height : Float64? = nil,
                   @id : String? = nil)
    end

    def inspector_label : String?
      @text
    end

    def ui(ui : Ui) : Response
      # Measure with the SAME style the delegate TextArea renders in
      # (theme + inline #style — TextArea registers no style class, so
      # neither does this widget: a "label"-class font_size would make
      # the row count and the painted text diverge).
      style = effective_style(ui)
      font_size = style.font_size
      fonts = ui.ctx.fonts_for(style.font_family)
      line_h = font_size * Fonts::LINE_H_FACTOR
      # The delegate always reserves its scrollbar column (BAR_W,
      # browser-style) and sizes itself rows × line_h tall (frame:
      # false adds no inset): lay the galley at the width it will wrap
      # at and translate the content height back into rows. The layout
      # itself is MRU-cached in Fonts, so this measure is cheap.
      wrap_w = {ui.available_width - TextArea::BAR_W, 10.0}.max
      galley = fonts.layout([TextRun.new(@text, font_size)],
        max_width: wrap_w)
      rows = {(galley.size.y / line_h).ceil.to_i, 1}.max
      if (mh = @max_height) && mh > 0.0
        rows = {rows, {(mh / line_h).floor.to_i, 1}.max}.min
      end
      area = TextArea.new(@text, rows: rows, frame: false,
        focus_id: @id, readonly: true)
      ui.add(area)
    end
  end
end
