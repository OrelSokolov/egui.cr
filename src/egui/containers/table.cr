# Table — a header-first table for everyday data rows, built on `Grid`
# with pinned column widths (a deliberately slim cousin of egui_extras'
# virtualized `Table`: no lazy loading, no resizable columns — wrap it
# in a `ScrollArea` for long lists).
#
#   Egui::Table.new("files", ["Name", "Size"], [0.7, 0.3]).show(ui) do |rows|
#     rows.label("a.txt"); rows.label("12 KB"); rows.end_row
#     rows.label("b.txt"); rows.label("4 KB");  rows.end_row
#   end
#
# Fractions are shares of the available width (default: equal split).

module Egui
  class Table
    def initialize(id : String, @headers : Array(String),
                   @fractions : Array(Float64)? = nil)
      @id = Id.from("table/#{id}")
    end

    def show(ui : Ui, &block : Grid ->) : Nil
      avail = ui.available_width
      n = @headers.size
      fr = @fractions || Array.new(n) { 1.0 / n }
      # Grid inserts item_spacing between columns, so split only the
      # remainder: fractions of the full available width would make the
      # table (n - 1) * spacing wider than it — and inside an auto-fit
      # window that feeds back into available_width next frame, growing
      # the window (and the table) every frame.
      usable = {avail - (n - 1) * ui.style.spacing.item_spacing.x, 1.0}.max
      widths = fr.first(n).map do |f|
        w = usable * f
        w = 8.0 if w < 8.0
        w = usable if w > usable
        w
      end
      widths += Array.new({n - widths.size, 0}.max) { 8.0 }

      # Header: pinned-width grid with title-colored text and a rule
      # below it.
      header_color = ui.style.visuals.title_color
      Grid.new(@id.child(1_u64).value.to_s, widths: widths).show(ui) do |grid|
        @headers.each { |h| grid.add(Label.new(RichText.new(h).color(header_color))) }
        grid.end_row
      end
      ui.separator

      Grid.new(@id.child(2_u64).value.to_s, widths: widths).show(ui) { |grid| yield grid }
    end
  end
end
