# TreeView — a hierarchical list (egui has no in-tree widget; upstream
# demos hand-roll one from `CollapsingHeader`, egui_extras has none
# either). Each `node` is a CollapsingHeader-style toggle row whose
# open/closed flag persists in `Memory#data` keyed by its path id, so
# tree state survives frames and needs no app-held state.
#
#   ui.tree_view("files") do |tree|
#     tree.node("src", default_open: true) do |sub|
#       sub.leaf("main.cr") { select("src/main.cr") }
#     end
#     tree.leaf("README.md") { select("README.md") }
#   end

module Egui
  class TreeView
    def initialize(id : String, @depth : Int32 = 0,
                   @base_id : Id = Id.from("tree"))
      @base_id = Id.from("tree/#{id}") if @depth.zero?
    end

    def show(ui : Ui, &block : self ->) : Nil
      @ui = ui
      @path_prefix = @base_id
      yield self
    end

    # A collapsible branch. Clicking the row toggles it; `selected`
    # paints the row with the selection fill; the block lays out the
    # children (already indented by `style.spacing.indent`).
    def node(text : String, selected : Bool = false,
             default_open : Bool = false, &block : self ->) : Nil
      ui = @ui.not_nil!
      node_id = @path_prefix.child(Id.from(text).value)

      line_h = {ui.style.font_size * Fonts::LINE_H_FACTOR,
        ui.style.spacing.interact_size.y}.max
      indent = @depth * ui.style.spacing.indent
      rect = ui.allocate_at_least(
        Vec2.new(ui.max_rect.width - indent, line_h))
      row = Rect.from_min_size(Pos2.new(rect.left + indent, rect.top),
        Vec2.new({rect.width - indent, 0.0}.max, line_h))
      response = ui.interact(row, node_id, Sense.click)

      open = ui.ctx.memory.data.get_bool(node_id, default_open)
      if response.clicked?
        open = !open
        ui.ctx.memory.data.set_bool(node_id, open)
        ui.ctx.request_repaint
      end

      paint_row(ui, row, text, @depth, open, selected, response)

      if open
        child = TreeView.new("", @depth + 1, node_id)
        child.show_indented(ui)
        yield child
      end
    end

    # A leaf row — no children, the block is its click handler.
    def leaf(text : String, selected : Bool = false,
             &on_click : ->) : Nil
      ui = @ui.not_nil!
      node_id = @path_prefix.child(Id.from(text).value)

      line_h = {ui.style.font_size * Fonts::LINE_H_FACTOR,
        ui.style.spacing.interact_size.y}.max
      indent = @depth * ui.style.spacing.indent
      rect = ui.allocate_at_least(
        Vec2.new(ui.max_rect.width - indent, line_h))
      row = Rect.from_min_size(Pos2.new(rect.left + indent, rect.top),
        Vec2.new({rect.width - indent, 0.0}.max, line_h))
      response = ui.interact(row, node_id, Sense.click)

      paint_row(ui, row, text, @depth, nil, selected, response)
      on_click.call if response.clicked?
    end

    # :nodoc: entry point for nested children (binds the parent Ui).
    def show_indented(ui : Ui) : Nil
      @ui = ui
      @path_prefix = @base_id
    end

    @ui : Ui?
    @path_prefix : Id = Id.from("tree")

    private def paint_row(ui : Ui, row : Rect, text : String, depth : Int32,
                          open : Bool?, selected : Bool, response : Response) : Nil
      v = ui.style.visuals
      font_size = ui.style.font_size

      if selected
        ui.painter.rect(row, 3.0, v.selection_fill)
      elsif response.hovered?
        ui.painter.rect(row, 3.0, v.fade_color(v.selection_fill, 0.4))
      end

      # Toggle arrow (or a dot for leaves), then the label.
      arrow = open.nil? ? "•" : (open ? "▾" : "▸")
      ui.painter.text(Pos2.new(row.left + 2.0, row.center.y),
        arrow, font_size, v.text_color)
      ui.painter.text(Pos2.new(row.left + 20.0, row.center.y),
        text, font_size, v.text_color)
    end
  end
end
