# Port of egui's Grid (upstream containers/grid.rs, kept out of the
# vendored 0.36 tree but part of the classic API).
#
# Aligned columns in immediate mode: column widths are measured this
# frame and *used* next frame (persisted per-grid in `Memory#data`),
# exactly like upstream `Grid` — so wide content in row 1 lines up with
# row 2 without a second layout pass.
#
#   Egui::Grid.new("settings").show(ui) do |grid|
#     grid.label("Name"); grid.label("Size"); grid.end_row
#     grid.label("a.txt"); grid.label("12 KB"); grid.end_row
#   end
#
# Explicit `widths` (one per column) pin the columns instead of
# measuring them — what `Table` builds its fixed layout on. `striped`
# paints every other row with a faint fill (under the cells).

module Egui
  class Grid
    @ui : Ui? = nil

    def initialize(id : String, @widths : Array(Float64)? = nil,
                   @striped : Bool = false)
      @grid_id = Id.from("grid/#{id}")
      @spacing = Vec2.new(8.0, 3.0)
      @origin = Pos2.zero
      @y = 0.0
      @col = 0
      @row_index = 0
      @row_height = 0.0
      @col_widths = [] of Float64
      @measured = [] of Float64
      @row_heights = [] of Float64
      @stripe_slots = [] of {Int32, Int32}
    end

    def show(ui : Ui, &block : self ->) : Rect
      @ui = ui
      @spacing = ui.style.spacing.item_spacing
      @origin = ui.cursor
      @y = @origin.y
      @row_index = 0

      # Previous frame's column widths drive this frame's layout (the
      # classic one-frame convergence; frame 1 is unaligned). Explicit
      # widths skip the memory round-trip entirely.
      memory = ui.ctx.memory
      @col_widths = @widths || begin
        count = memory.data.get_int(widths_id, 0)
        count.times.map { |c|
          memory.data.get_f64(widths_id.child(c.to_u64 + 1), 0.0)
        }.to_a
      end

      yield self
      end_row unless @col.zero?

      # Persist this frame's measurements for the next layout (and keep
      # the cells alive across end-frame pruning — they have no
      # #interact call of their own).
      if @widths.nil? && !@measured.empty?
        memory.data.set_int(widths_id, @measured.size)
        @measured.each_with_index do |w, c|
          memory.data.set_f64(widths_id.child(c.to_u64 + 1), w)
        end
        memory.use_id(widths_id)
        (0...@measured.size).each do |c|
          memory.use_id(widths_id.child(c.to_u64 + 1))
        end
      end

      # Back-paint the stripes under their rows (slots were reserved
      # before the cells so the fill lands beneath them).
      unless @stripe_slots.empty?
        total_w = total_width
        @stripe_slots.each do |row, slot|
          top = @origin.y + @row_heights[0, row].sum +
                row * @spacing.y
          ui.painter.set(slot,
            RectCmd.new(ui.painter.clip,
              Rect.from_min_size(Pos2.new(@origin.x, top),
                Vec2.new(total_w, @row_heights[row]? || 0.0)),
              0.0, stripe_fill, nil, 0.0))
        end
      end

      content = Rect.from_min_size(@origin, content_size)
      ui.min_rect = ui.min_rect.union(content)
      ui.cursor = Pos2.new(ui.max_rect.min.x, content.bottom + @spacing.y)
      content
    end

    # egui `Grid::end_row` — finish this row and start a new one below.
    def end_row : Nil
      return if @ui.nil? || (@col.zero? && @row_height.zero?)
      @row_heights << @row_height
      @row_index += 1
      @col = 0
      @row_height = 0.0
      @y += @row_heights.last + @spacing.y
    end

    def label(text : String) : Response
      add(Label.new(text))
    end

    # Place a widget in the next column of the current row. The cell is
    # a child Ui as wide as the (previous-frame) column width; whatever
    # the cell ends up measuring becomes the new candidate width.
    def add(widget : Widget) : Response
      ui = @ui.not_nil!
      col = @col

      # Reserve the stripe slot before any cell paints (rows 1, 3, …).
      if @striped && col.zero? && @row_index.odd?
        @stripe_slots << {@row_index, ui.painter.add_noop}
      end

      x = @origin.x + (0...col).sum { |c| @col_widths[c]? || 0.0 } +
          col * @spacing.x
      cell = ui.child_ui(
        Rect.from_min_size(Pos2.new(x, @y), Vec2.new(@col_widths[col]? || 0.0, 1e6)),
        id: @grid_id.child(cell_slot_id))
      response = widget.ui(cell)

      measured = cell.min_rect.size
      # Crystal's []= doesn't append at index == size — pad first.
      while @measured.size <= col
        @measured << 0.0
      end
      if measured.x > @measured[col]
        @measured[col] = measured.x
      end
      while @col_widths.size <= col
        @col_widths << 0.0
      end
      if @widths # pinned layout still grows to fit overflowing cells
        @col_widths[col] = {measured.x, @col_widths[col]}.max
      elsif measured.x > @col_widths[col]
        @col_widths[col] = measured.x
      end
      @row_height = {@row_height, measured.y}.max
      @col += 1
      response
    end

    private def cell_slot_id : UInt64
      (@row_index * 4096 + @col).to_u64
    end

    private def total_width : Float64
      w = (0...@col_widths.size).sum { |c| @col_widths[c]? || 0.0 }
      w + ({@col_widths.size, 1}.max - 1) * @spacing.x
    end

    private def content_size : Vec2
      height = @row_heights.sum + @row_height +
               ({@row_heights.size + (@row_height > 0 ? 1 : 0), 1}.max - 1) * @spacing.y
      Vec2.new(total_width, height)
    end

    private def stripe_fill : Color32
      ui = @ui.not_nil!
      v = ui.style.visuals
      v.fade_color(v.text_color, v.dark ? 0.92 : 0.96)
    end

    private def widths_id : Id
      @grid_id.child(0xFFFF_u64)
    end
  end
end
