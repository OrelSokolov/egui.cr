# TableTextRenderer — auto-layout for TEXT tables (GFM markdown
# tables and friends): per-column min/max content measurement,
# HTML-style proportional width distribution, WRAPPED cell text
# (long cells break into lines like HTML <td>), and full borders.
#
#   Egui::TableTextRenderer.new([["h1", "h2"], ["a", "b"]])
#     .render(ui, style) { |text, header| MyCellWidget.new(text) }
#
# The width algorithm (the HTML table-layout: auto sketch):
#   min_c = the widest unbreakable word in column c,
#   max_c = the widest cell rendered on ONE line;
#   everything fits        → columns at max (no wrap);
#   room between min and max → columns take min + (max-min) * share
#   (share = how much of the free width the column's stretch is
#   worth — proportional, so wide columns shed more pixels than
#   narrow ones);
#   not even the mins fit  → squeeze the mins proportionally (cells
#   hard-break long words, same fallback as any wrapped label).
#
# The cell factory block builds each cell's widget (markdown passes
# its RichLabels, so links/selection keep working); measurement uses
# the same styled runs the widget will lay out, so the reserved
# height matches what renders.

module Egui
  class TableTextRenderer
    def initialize(@rows : Array(Array(String)),
                   @padding : Vec2 = Vec2.new(6.0, 4.0),
                   @min_col : Float64 = 24.0)
    end

    def render(ui : Ui, style : Style,
               &cell : String, Bool -> Widget) : Rect
      return Rect.new(ui.cursor, ui.cursor) if @rows.empty?
      ctx = ui.ctx
      fonts = ctx.fonts_for(style.font_family)
      resolve = ->(family : String?, bold : Bool, italic : Bool) { ctx.fonts_for(family, bold, italic) }
      visuals = style.visuals
      cols = @rows.map(&.size).max
      avail = ui.available_width

      # Styled runs per cell, once (measurement and wrap reuse them).
      runs_by_cell = @rows.map do |row|
        row.map do |text|
          rich = RichText.new(text)
          runs = rich.styled_runs(style.font_size, visuals.text_color,
            visuals.hyperlink_color)
          runs = RichText.fade_code_runs(runs, visuals) if ctx.mono_fonts.nil?
          runs
        end
      end

      # --- column widths (min = longest word, max = single line) ----
      mins = Array.new(cols, 0.0)
      maxs = Array.new(cols, 0.0)
      runs_by_cell.each do |row_runs|
        row_runs.each_with_index do |runs, ci|
          wmin = 0.0
          wmax = 0.0
          runs.each do |r|
            stack = resolve.call(r.family, r.bold?, r.italic?)
            wmax += stack.measure(r.text, r.size).x
            r.text.split(' ').each do |word|
              w = stack.measure(word, r.size).x
              wmin = {wmin, w}.max
            end
          end
          # room for the padding too — a cell can never get narrower
          # than its widest word + its own padding
          mins[ci] = {mins[ci], wmin + @padding.x * 2.0, @min_col}.max
          maxs[ci] = {maxs[ci], wmax + @padding.x * 2.0, mins[ci]}.max
        end
      end
      widths = distribute(maxs, mins, avail)

      # --- row heights (wrap each cell at its column width) ---------
      heights = @rows.each_with_index.map do |row, ri|
        h = 0.0
        row.each_with_index do |_text, ci|
          galley = fonts.layout(runs_by_cell[ri][ci],
            {widths[ci] - @padding.x * 2.0, 1.0}.max, resolve)
          h = {h, galley.size.y}.max
        end
        h + @padding.y * 2.0
      end.to_a

      total = Vec2.new(widths.sum, heights.sum)
      top = ui.cursor
      rect = ui.allocate_at_least(total)

      # --- borders: outer stroke + every inner grid line ------------
      border = visuals.fade_color(visuals.text_color, 0.38)
      ui.painter.rect(rect, 0.0, nil, border, 1.0)
      (1...@rows.size).each do |ri|
        y = rect.top + heights[0...ri].sum
        ui.painter.line(Pos2.new(rect.left, y),
          Pos2.new(rect.right, y), 1.0, border)
      end
      (1...cols).each do |ci|
        x = rect.left + widths[0...ci].sum
        ui.painter.line(Pos2.new(x, rect.top),
          Pos2.new(x, rect.bottom), 1.0, border)
      end

      # --- cells (the block's widgets, laid out inside their box) ---
      y = rect.top
      @rows.each_with_index do |row, ri|
        x = rect.left
        row.each_with_index do |text, ci|
          box = Rect.from_min_size(Pos2.new(x, y),
            Vec2.new(widths[ci], heights[ri]))
          inner = ui.child_ui(Rect.from_min_size(
            Pos2.new(box.left + @padding.x, box.top + @padding.y),
            Vec2.new({widths[ci] - @padding.x * 2.0, 1.0}.max,
              {heights[ri] - @padding.y * 2.0, 1.0}.max)))
          inner.add(yield text, ri.zero?)
          x += widths[ci]
        end
        y += heights[ri]
      end
      rect
    end

    # HTML-ish width distribution (see the class comment). Returns
    # `maxs` untouched when everything fits on one line already.
    private def distribute(maxs : Array(Float64), mins : Array(Float64),
                           avail : Float64) : Array(Float64)
      sum_max = maxs.sum
      return maxs if sum_max <= avail && sum_max > 0
      sum_min = mins.sum
      if avail >= sum_min && sum_min > 0
        room = sum_max - sum_min
        share = room > 0 ? (avail - sum_min) / room : 0.0
        mins.each_with_index.map { |mn, i| mn + (maxs[i] - mn) * share }.to_a
      elsif sum_min > 0
        mins.map { |mn| mn * avail / sum_min }
      else
        mins
      end
    end
  end
end
