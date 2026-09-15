# Table — a striped, header-first table for everyday data rows, built
# on `Grid` with pinned column widths (a deliberately slim cousin of
# egui_extras' virtualized `Table`: no lazy loading, no resizable
# columns — wrap it in a `ScrollArea` for long lists).
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
                   @fractions : Array(Float64)? = nil,
                   @striped : Bool = true)
      @id = Id.from("table/#{id}")
    end

    def show(ui : Ui, &block : Grid ->) : Nil
      avail = ui.available_width
      n = @headers.size
      fr = @fractions || Array.new(n) { 1.0 / n }
      widths = fr.first(n).map { |f| (avail * f).clamp(8.0, avail) }
      widths += Array.new({n - widths.size, 0}.max) { 8.0 }

      # Header: pinned-width grid with title-colored text and a rule
      # below it (the body's first stripe starts under the rule).
      header_color = ui.style.visuals.title_color
      Grid.new(@id.child(1_u64).value.to_s, widths: widths).show(ui) do |grid|
        @headers.each { |h| grid.add(Label.new(RichText.new(h).color(header_color))) }
        grid.end_row
      end
      ui.separator

      Grid.new(@id.child(2_u64).value.to_s, widths: widths,
        striped: @striped).show(ui) { |grid| yield grid }
    end
  end
end
