# egui-cr Windows XP Paint demo — bin/paint.
#
# A 1:1-arranged clone of MS Paint (XP era, tool set and button icons
# taken from jspaint's classic theme, see assets/paint/README.md):
# the 16-tool toolbox with per-tool option strips, the menu bar, the
# 28-color palette with the overlapped fg/bg swatch, the status bar
# with live cursor coordinates, and a real pixel canvas driven by the
# new Egui::Canvas widget (nearest-sampled stream texture).
#
# Color styling is deliberately NOT 1:1 (Luna-ish silver instead of
# exact XP bitmaps) — only the buttons and layout are.
#
# File I/O goes through the SystemPorts dialogs (zenity/kdialog on
# Linux, osascript on macOS, WinForms/Win32 on Windows) and a pure
# stdlib PNG codec (examples/paint/png.cr) — fully cross-platform.

require "../src/egui"
require "../src/egui/backend/sokol"
require "./paint/dialog"
require "./paint/png"
require "./paint/text"

module PaintXp
  # Luna-ish face color (close enough; deliberately not exact XP).
  FACE      = Egui::Color32.rgb(236, 233, 216)
  WORKSPACE = Egui::Color32.rgb(124, 124, 124)
  WHITE     = Egui::Color32.rgb(255, 255, 255)
  BLACK     = Egui::Color32.rgb(0, 0, 0)
  BEVEL_DK  = Egui::Color32.rgb(128, 128, 128)
  NAVY      = Egui::Color32.rgb(10, 36, 106)
  SEL_BG    = Egui::Color32.rgb(182, 186, 199)

  # The 16 classic tools, in MS Paint / jspaint toolbox order. The icon
  # index is the position in assets/paint/tools.png (16×16 cells).
  TOOLS = {
    {:free_select, "Free-Form Select", 0,
     "Selects a free-form part of the picture."},
    {:select, "Select", 1,
     "Selects a rectangular part of the picture."},
    {:eraser, "Eraser/Color Eraser", 2,
     "Erases a portion of the picture."},
    {:fill, "Fill With Color", 3,
     "Fills an area with the current drawing color."},
    {:picker, "Pick Color", 4,
     "Picks up a color from the picture for drawing."},
    {:magnifier, "Magnifier", 5,
     "Changes the magnification."},
    {:pencil, "Pencil", 6,
     "Draws a free-form line one pixel wide."},
    {:brush, "Brush", 7,
     "Draws using a brush with the selected tip shape."},
    {:airbrush, "Airbrush", 8,
     "Draws using an airbrush."},
    {:text, "Text", 9,
     "Inserts text into the picture."},
    {:line, "Line", 10,
     "Draws a straight line."},
    {:curve, "Curve", 11,
     "Draws a curved line."},
    {:rect, "Rectangle", 12,
     "Draws a rectangle."},
    {:polygon, "Polygon", 13,
     "Draws a polygon."},
    {:ellipse, "Ellipse", 14,
     "Draws an ellipse."},
    {:round_rect, "Rounded Rectangle", 15,
     "Draws a rounded rectangle."},
  }

  # 28 swatches, 2 rows × 14 (the classic arrangement; hues are our own
  # tuning, per the "colors not 1:1" brief).
  PALETTE = [
    Egui::Color32.rgb(0, 0, 0), Egui::Color32.rgb(128, 128, 128),
    Egui::Color32.rgb(132, 26, 21), Egui::Color32.rgb(138, 108, 31),
    Egui::Color32.rgb(41, 105, 40), Egui::Color32.rgb(28, 93, 111),
    Egui::Color32.rgb(24, 40, 115), Egui::Color32.rgb(89, 37, 117),
    Egui::Color32.rgb(160, 160, 160), Egui::Color32.rgb(224, 224, 224),
    Egui::Color32.rgb(219, 91, 74), Egui::Color32.rgb(229, 193, 99),
    Egui::Color32.rgb(125, 205, 112), Egui::Color32.rgb(99, 197, 213),
    Egui::Color32.rgb(255, 255, 255), Egui::Color32.rgb(196, 196, 196),
    Egui::Color32.rgb(181, 30, 45), Egui::Color32.rgb(219, 158, 19),
    Egui::Color32.rgb(79, 175, 61), Egui::Color32.rgb(60, 171, 191),
    Egui::Color32.rgb(46, 84, 187), Egui::Color32.rgb(150, 60, 181),
    Egui::Color32.rgb(120, 120, 120), Egui::Color32.rgb(64, 64, 64),
    Egui::Color32.rgb(124, 18, 32), Egui::Color32.rgb(144, 90, 18),
    Egui::Color32.rgb(38, 88, 34), Egui::Color32.rgb(24, 70, 88),
    Egui::Color32.rgb(14, 26, 84), Egui::Color32.rgb(60, 22, 84),
  ]

  DEFAULT_W = 640
  DEFAULT_H = 480

  # PNG magic number — cheap "is this really a PNG" check for clipboard
  # bytes coming from external tools.
  PNG_SIG = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

  def self.theme : Egui::Theme
    theme = Egui::DefaultTheme.build("paint-xp", dark: false)
    v = theme.style.visuals
    v.window_fill = FACE
    v.window_stroke = BLACK
    v.window_rounding = 0.0
    v.panel_fill = FACE
    v.text_color = BLACK
    v.button_weak = FACE
    v.button_hovered = FACE
    v.button_active = FACE
    # Native menu selection: a navy band with white text. The button
    # colors stay FACE on purpose — the toolbox draws its own bevel
    # cells — so menus get a dedicated highlight instead.
    v.menu_highlight_fill = NAVY
    v.menu_highlight_text = WHITE
    # Classic scrollbars: Luna-blue thumb and arrow buttons (#b8c7e6)
    # with slate arrows (#6b7596) on a white track.
    v.scrollbar_fill = Egui::Color32.rgb(0xb8, 0xc7, 0xe6)
    v.scrollbar_arrow = Egui::Color32.rgb(0x6b, 0x75, 0x96)
    v.scrollbar_track = WHITE
    v.selection_fill = NAVY
    v.separator_color = BEVEL_DK
    theme
  end
end

# Floating selection state: the extracted pixels, where they currently
# sit, and — once the user drags — the post-erase base every frame of
# the drag restores before re-blitting the float at its new spot.
class SelState
  property x : Int32
  property y : Int32
  property w : Int32
  property h : Int32
  property img : Bytes
  property? dragging = false
  property grab_dx = 0
  property grab_dy = 0
  # Snapshot taken right after the source region was erased; nil until
  # the float has been moved at least once.
  property move_base : Bytes? = nil

  def initialize(@x, @y, @w, @h, @img)
  end

  def contains?(px : Int32, py : Int32) : Bool
    px >= @x && py >= @y && px < @x + @w && py < @y + @h
  end
end

# An in-progress text session: clicks place the anchor, typing renders
# over a snapshot of the canvas taken when the session opened.
class TextState
  property x : Int32
  property y : Int32
  property buf = ""
  property base : Bytes
  # What was last rendered (buffer + size), to skip redundant redraws.
  property rendered = ""
  property rendered_size = 0

  def initialize(@x, @y, @base)
  end
end

class CurveState
  property p0 : {Int32, Int32}
  property p1 : {Int32, Int32}
  property c1 : {Int32, Int32}? = nil
  property c2 : {Int32, Int32}? = nil
  # 1 = first bend pending, 2 = second bend pending, 3 = done
  property stage = 1

  def initialize(@p0, @p1)
  end

  # Subdivided polyline for the current control points.
  def points : Array({Int32, Int32})
    n = 60
    pts = Array({Int32, Int32}).new(n + 1)
    (0..n).each do |i|
      t = i.to_f64 / n
      x, y = bezier_pt(t)
      pts << {x.round.to_i, y.round.to_i}
    end
    pts
  end

  private def bezier_pt(t : Float64) : {Float64, Float64}
    p0x = @p0[0].to_f64
    p0y = @p0[1].to_f64
    p1x = @p1[0].to_f64
    p1y = @p1[1].to_f64
    mx = (p0x + p1x) / 2.0
    my = (p0y + p1y) / 2.0
    c1 = @c1 || {mx, my}
    c2 = @c2 || {c1[0].to_f64, c1[1].to_f64}
    u = 1.0 - t
    x = u * u * u * p0x + 3 * u * u * t * c1[0] +
        3 * u * t * t * c2[0] + t * t * t * p1x
    y = u * u * u * p0y + 3 * u * u * t * c1[1] +
        3 * u * t * t * c2[1] + t * t * t * p1y
    {x, y}
  end
end


class PaintApp < Egui::App
  ACTION_NEW     = Egui::HotkeyAction.new("paint.new")
  ACTION_OPEN    = Egui::HotkeyAction.new("paint.open")
  ACTION_SAVE    = Egui::HotkeyAction.new("paint.save")
  ACTION_SAVE_AS = Egui::HotkeyAction.new("paint.save_as")
  ACTION_EXIT    = Egui::HotkeyAction.new("paint.exit")
  ACTION_UNDO    = Egui::HotkeyAction.new("paint.undo")
  ACTION_REDO    = Egui::HotkeyAction.new("paint.redo")
  ACTION_PASTE   = Egui::HotkeyAction.new("paint.paste")
  ACTION_SEL_ALL = Egui::HotkeyAction.new("paint.select_all")
  ACTION_DESEL   = Egui::HotkeyAction.new("paint.deselect")
  ACTION_DELETE  = Egui::HotkeyAction.new("paint.delete_sel")
  ACTION_INVERT  = Egui::HotkeyAction.new("paint.invert")
  ACTION_CLEAR   = Egui::HotkeyAction.new("paint.clear_image")

  BINDINGS = {
    ACTION_NEW     => "Ctrl+N",
    ACTION_OPEN    => "Ctrl+O",
    ACTION_SAVE    => "Ctrl+S",
    ACTION_SAVE_AS => "Ctrl+Shift+S",
    ACTION_UNDO    => "Ctrl+Z",
    ACTION_REDO    => "Ctrl+Y",
    ACTION_PASTE   => "Ctrl+V",
    ACTION_SEL_ALL => "Ctrl+A",
    ACTION_DESEL   => "Escape",
    ACTION_DELETE  => "Delete",
    ACTION_INVERT  => "Ctrl+I",
    ACTION_CLEAR   => "Ctrl+Shift+N",
  }

  DEFAULT_HINT = "For Help, click Help Topics on the Help Menu."

  # Undo entries carry their canvas size (Open/Attributes can resize).
  record Snap, w : Int32, h : Int32, data : Bytes

  @path : String?
  @cursor_px : {Int32, Int32}?
  @drag_size : {Int32, Int32}?
  @dialog : Symbol?
  @free_button : Symbol?
  @last_pt : {Int32, Int32}?
  @shape_start : {Int32, Int32}?
  @curve : CurveState?
  @sel : SelState?
  @text : TextState?
  @palette : Array(Egui::Color32)

  @canvas : Egui::Canvas
  getter canvas
  # The backend Quit port captured before GuardedQuit replaced it.
  @orig_quit : Egui::SystemPorts::Quit::Implementation?
  @text_raster = PaintText.new
  @tools_tex = 0_u64
  # The fill tool's bitmap cursor (the tools.png bucket cell, 2x
  # nearest-upscaled): MS Paint pours from the spout at the bucket's
  # lower left, so the hotspot sits there. Built once, lazily.
  @fill_cursor : Egui::CustomCursorImage?

  def initialize
    super
    @canvas = Egui::Canvas.new("paint", PaintXp::DEFAULT_W, PaintXp::DEFAULT_H)
    @fg = PaintXp::BLACK
    @bg = PaintXp::WHITE
    @tool = 6 # pencil
    @zoom = 1
    @line_width = 1
    @brush_shape = :circle
    @brush_size = 7
    @eraser_size = 8
    @airbrush_r = 10
    @fill_style = :outline
    @opaque = true
    @text_size = 12
    @undo = [] of Snap
    @redo = [] of Snap
    @palette = PaintXp::PALETTE.dup
    @doc_dirty = false
    @status = DEFAULT_HINT
    @show_toolbox = true
    @show_status = true
    @edit_slot = 0
    @edit_orig = PaintXp::PALETTE.first # color before Edit Colors opened
    # Attributes / Stretch dialog fields
    @attr_w = PaintXp::DEFAULT_W
    @attr_h = PaintXp::DEFAULT_H
    @st_h = 100
    @st_v = 100
    @sk_h = 0
    @sk_v = 0
    # transient tool state
    @poly = [] of {Int32, Int32}
    @lasso = [] of {Int32, Int32}
    @themed = false
    @hotkeys_ready = false
    # Exit confirmation: the backend Quit port (wrapped on the first
    # frame, once Sokol.run has installed it) so the window ✕ asks to
    # save too, exactly like File → Exit.
    @exiting = false
    @orig_quit = nil
  end

  def update(ctx : Egui::Context) : Nil
    ctx.theme = PaintXp.theme unless @themed
    @themed = true

    unless @hotkeys_ready
      BINDINGS.each { |action, combo| ctx.hotkeys.bind(combo, action) }
      @hotkeys_ready = true
    end

    if @orig_quit.nil?
      @orig_quit = Egui::SystemPorts::Quit.implementation
      Egui::SystemPorts::Quit.use(GuardedQuit.new(self))
    end

    if @tools_tex.zero?
      @tools_tex = ctx.load_image(
        File.join({{ __DIR__ }}, "../assets/paint/tools.png"))
    end
    @fill_cursor ||= build_fill_cursor

    @canvas.scale = @zoom

    draw_menu_bar(ctx)

    if @show_toolbox
      ctx.side_panel(:left, "toolbox", width: 80.0,
        fill: PaintXp::FACE) { |ui| draw_toolbox(ui) }
    end
    ctx.bottom_panel("palette", height: 50.0,
      fill: PaintXp::FACE) { |ui| draw_palette(ui) }
    if @show_status
      ctx.bottom_panel("status", height: 21.0,
        fill: PaintXp::FACE) { |ui| draw_status(ui) }
    end
    ctx.central_panel(fill: PaintXp::WORKSPACE) { |ui| draw_workspace(ctx, ui) }

    draw_dialogs(ctx)
    dispatch_actions(ctx)

    if @canvas.dirty?
      @canvas.flush(ctx)
      ctx.request_repaint
    end
  end

  private def draw_menu_bar(ctx : Egui::Context) : Nil
    ctx.menu_bar do |bar|
      bar.menu_button("File") do |m|
        m.menu_item("New", ACTION_NEW)
        m.menu_item("Open…", ACTION_OPEN)
        m.menu_item("Save", ACTION_SAVE)
        m.menu_item("Save As…", ACTION_SAVE_AS)
        m.menu_item("Exit", ACTION_EXIT)
      end
      bar.menu_button("Edit") do |m|
        m.menu_item("Undo", ACTION_UNDO)
        m.menu_item("Repeat", ACTION_REDO)
        m.menu_item("Paste", ACTION_PASTE)
        m.menu_item("Clear Selection", ACTION_DESEL)
        m.menu_item("Select All", ACTION_SEL_ALL)
        m.menu_item("Delete Selection", ACTION_DELETE)
      end
      bar.menu_button("View") do |m|
        m.menu_item("#{@show_toolbox ? "✓ " : ""}Tool Box") do
          @show_toolbox = !@show_toolbox
        end
        m.menu_item("#{@show_status ? "✓ " : ""}Status Bar") do
          @show_status = !@show_status
        end
        m.menu_button("Zoom") do |z|
          z.menu_item("Normal Size (1×)") { set_zoom(1) }
          z.menu_item("Large Size (2×)") { set_zoom(2) }
          z.menu_item("Custom 4×") { set_zoom(4) }
          z.menu_item("Custom 8×") { set_zoom(8) }
        end
      end
      bar.menu_button("Image") do |m|
        m.menu_item("Flip Horizontal") { transform_flip(true) }
        m.menu_item("Flip Vertical") { transform_flip(false) }
        m.menu_item("Rotate 90° Clockwise") { transform_rotate(90) }
        m.menu_item("Rotate 90° Counter Clockwise") { transform_rotate(270) }
        m.menu_item("Rotate 180°") { transform_rotate(180) }
        m.menu_item("Stretch/Skew…") { @dialog = :stretch }
        m.menu_item("Invert Colors", ACTION_INVERT)
        m.menu_item("Attributes…") do
          @attr_w = @canvas.width
          @attr_h = @canvas.height
          @dialog = :attributes
        end
        m.menu_item("Clear Image", ACTION_CLEAR)
      end
      bar.menu_button("Colors") do |m|
        m.menu_item("Edit Colors…") { @dialog = :edit_color }
      end
      bar.menu_button("Help") do |m|
        m.menu_item("About Paint…") { @dialog = :about }
      end
    end
  end

  # --- toolbox ---------------------------------------------------------

  CELL = 25.0

  private def draw_toolbox(ui : Egui::Ui) : Nil
    p = ui.painter
    # Panel-content origin: painter coordinates are screen-absolute,
    # so every cell is placed from the panel cursor, not (0, 0).
    ox = ui.cursor.x
    oy = ui.cursor.y
    PaintXp::TOOLS.each_with_index do |(sym, name, icon, hint), i|
      col = i % 2
      row = i // 2
      rect = Egui::Rect.from_min_size(
        Egui::Pos2.new(ox + 3.0 + col * (CELL + 1.0), oy + 3.0 + row * (CELL + 1.0)),
        Egui::Vec2.new(CELL, CELL))
      resp = ui.interact(rect, ui.named_id("tool#{i}"), Egui::Sense::Click)
      selected = @tool == i
      resp.on_hover_text(name)
      resp.on_hover_cursor(Egui::CursorIcon::Pointer)
      if resp.hovered?
        @status = hint
      elsif @status == hint
        @status = DEFAULT_HINT
      end
      paint_bevel_cell(p, rect, selected, resp.hovered? || selected)
      # icon (16×16 cell i of the 256×16 sprite)
      icon_rect = Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.min.x + 4.0, rect.min.y + 4.0),
        Egui::Vec2.new(16.0, 16.0))
      uv = Egui::Rect.new(
        Egui::Pos2.new(icon.to_f64 / 16.0, 0.0),
        Egui::Pos2.new((icon + 1).to_f64 / 16.0, 1.0))
      p.image(icon_rect, @tools_tex, uv, nearest: true) unless @tools_tex.zero?
      if resp.clicked?
        select_tool(i)
        @status = hint
      end
    end
    # Reserve the (manually placed) grid in the layout flow so the
    # options strip below starts from the framework cursor.
    grid_bottom = 3.0 + 8 * (CELL + 1.0)
    ui.allocate_at_least(Egui::Vec2.new(ui.available_width, grid_bottom))
    # The tool options strip under the grid (sunken box), laid out by
    # the framework.
    draw_tool_options(ui)
  end

  # Raised/sunken 1px bevel cell with the XP selected-tool look.
  private def paint_bevel_cell(p : Egui::Painter, rect : Egui::Rect,
                               sunken : Bool, highlight : Bool) : Nil
    fill = sunken && highlight ? PaintXp::SEL_BG : PaintXp::FACE
    p.rect(rect, 0.0, fill)
    lo, hi = sunken ? {PaintXp::BEVEL_DK, PaintXp::WHITE}
                    : {PaintXp::WHITE, PaintXp::BEVEL_DK}
    p.line(rect.min + Egui::Vec2.new(0.0, 0.5),
      Egui::Pos2.new(rect.max.x - 0.5, rect.min.y + 0.5), 1.0, lo)
    p.line(rect.min + Egui::Vec2.new(0.5, 0.0),
      Egui::Pos2.new(rect.min.x + 0.5, rect.max.y - 0.5), 1.0, lo)
    p.line(Egui::Pos2.new(rect.min.x + 0.5, rect.max.y - 0.5),
      Egui::Pos2.new(rect.max.x - 0.5, rect.max.y - 0.5), 1.0, hi)
    p.line(Egui::Pos2.new(rect.max.x - 0.5, rect.min.y + 0.5),
      Egui::Pos2.new(rect.max.x - 0.5, rect.max.y - 0.5), 1.0, hi)
  end
end

  # Tool option strips (inside the sunken box below the toolbox grid).
  # Laid out through the framework: each strip is a `Ui#horizontal` row
  # in the panel's vertical flow, every cell takes its rect from the
  # layout cursor, and rows wrap at the available width — no strip can
  # overflow the narrow panel.
class PaintApp
  private def option_cell(ui : Egui::Ui, p : Egui::Painter, id : String,
                          w : Float64, h : Float64, selected : Bool,
                          &glyph : Egui::Rect -> Nil) : Bool
    rect = ui.allocate_at_least(Egui::Vec2.new(w, h))
    resp = ui.interact(rect, ui.named_id(id), Egui::Sense::Click)
    paint_bevel_cell(p, rect, selected, resp.hovered? || selected)
    glyph.call(rect)
    resp.clicked?
  end

  # A wrapping row of same-sized cells: as many per row as fit the
  # region's width. `items` are (id, selected, glyph) tuples. Returns
  # the index of the clicked cell, if any.
  private def option_strip(ui : Egui::Ui, p : Egui::Painter,
                           cell_w : Float64, cell_h : Float64,
                           items : Array(Tuple(String, Bool, Proc(Egui::Rect, Nil)))) : Int32?
    pitch = cell_w + ui.style.spacing.item_spacing.x
    per_row = {((ui.available_width + ui.style.spacing.item_spacing.x) /
      pitch).floor.to_i, 1}.max
    clicked = nil
    items.each_with_index.each_slice(per_row).each do |slice|
      ui.horizontal do |row|
        slice.each do |(item, i)|
          id, selected, glyph = item
          clicked = i if option_cell(row, p, id, cell_w, cell_h,
            selected, &glyph)
        end
      end
    end
    clicked
  end

  private def draw_tool_options(ui : Egui::Ui) : Nil
    p = ui.painter
    # Compact pitch inside the strips. The style object is shared with
    # the whole context, so restore it afterwards.
    saved = ui.style.spacing.item_spacing
    ui.style.spacing.item_spacing = Egui::Vec2.new(1.0, 3.0)
    begin
      box = ui.frame(fill: PaintXp::WHITE, rounding: 0.0,
        margin: Egui::Vec2.new(3.0, 3.0)) do |inner|
        case PaintXp::TOOLS[@tool][0]
        when :select, :free_select
          # Opaque / transparent floating selection.
          i = option_strip(inner, p, 24.0, 18.0, [
            {"selopt0", @opaque,
             ->(r : Egui::Rect) { draw_selection_mode_glyph(p, r, false) }},
            {"selopt1", !@opaque,
             ->(r : Egui::Rect) { draw_selection_mode_glyph(p, r, true) }},
          ])
          @opaque = (i == 0) unless i.nil?
        when :eraser
          sizes = [8, 6, 4, 2]
          i = option_strip(inner, p, 22.0, 18.0,
            sizes.map_with_index do |size, k|
              {
                "er#{k}", @eraser_size == size,
                ->(r : Egui::Rect) do
                  s = size.to_f64
                  sq = Egui::Rect.from_min_size(
                    Egui::Pos2.new(r.center.x - s / 2, r.center.y - s / 2),
                    Egui::Vec2.new(s, s))
                  p.rect(sq, 0.0, PaintXp::BLACK)
                end,
              }
            end)
          @eraser_size = sizes[i] unless i.nil?
        when :airbrush
          radii = [10, 6, 3]
          i = option_strip(inner, p, 22.0, 18.0,
            radii.map_with_index do |r0, k|
              {
                "air#{k}", @airbrush_r == r0,
                # a spray of dots
                ->(r : Egui::Rect) do
                  24.times do |t|
                    ang = t.to_f64 * Math::TAU / 24.0
                    rr = r0.to_f64 * (0.4 + 0.6 * ((t * 37) % 10) / 10.0)
                    dot = Egui::Pos2.new(r.center.x + rr * Math.cos(ang),
                      r.center.y + rr * Math.sin(ang))
                    p.rect(Egui::Rect.from_min_size(dot,
                      Egui::Vec2.new(1.5, 1.5)), 0.0, PaintXp::BLACK)
                  end
                end,
              }
            end)
          @airbrush_r = radii[i] unless i.nil?
        when :line, :curve, :rect, :polygon, :ellipse, :round_rect
          # five stroke widths, then fill styles below
          i = option_strip(inner, p, 10.0, 18.0,
            (1..5).map_with_index do |width, k|
              {
                "lw#{k}", @line_width == width,
                ->(r : Egui::Rect) do
                  p.line(Egui::Pos2.new(r.min.x + 1.0, r.center.y),
                    Egui::Pos2.new(r.max.x - 1.0, r.center.y),
                    width.to_f64, PaintXp::BLACK)
                end,
              }
            end)
          @line_width = i + 1 unless i.nil?
          styles = [:outline, :filled, :both]
          i = option_strip(inner, p, 15.0, 18.0,
            styles.map_with_index do |style, k|
              {
                "fs#{k}", @fill_style == style,
                ->(r : Egui::Rect) { draw_fill_style_glyph(p, r, style) },
              }
            end)
          @fill_style = styles[i] unless i.nil?
        when :brush
          shapes = {:circle, :square, :fslash, :bslash}
          sizes = {9, 5, 3}
          sizes.each_with_index do |size, zi|
            clicked = option_strip(inner, p, 12.0, 13.0,
              shapes.to_a.map_with_index do |shape, si|
                {
                  "br#{si}#{zi}",
                  @brush_shape == shape && @brush_size == size,
                  ->(r : Egui::Rect) { draw_brush_glyph(p, r, shape, size) },
                }
              end)
            if clicked
              @brush_shape = shapes[clicked]
              @brush_size = size
            end
          end
        when :magnifier
          zooms = [1, 2, 4, 8]
          i = option_strip(inner, p, 12.0, 18.0,
            zooms.map_with_index do |z, k|
              {
                "zoom#{k}", @zoom == z,
                ->(r : Egui::Rect) do
                  p.text(Egui::Pos2.new(r.center.x - 5.0, r.center.y),
                    "#{z}×", 9.0, PaintXp::BLACK)
                end,
              }
            end)
          set_zoom(zooms[i]) unless i.nil?
        when :text
          tsizes = [10, 14, 18, 24, 36]
          i = option_strip(inner, p, 10.0, 18.0,
            tsizes.map_with_index do |s, k|
              {
                "tsz#{k}", @text_size == s,
                ->(r : Egui::Rect) do
                  p.text(Egui::Pos2.new(r.min.x + 1.0, r.center.y), "#{s}",
                    {s.to_f64 / 3, 9.0}.min, PaintXp::BLACK)
                end,
              }
            end)
          @text_size = tsizes[i] unless i.nil?
        end
      end
    ensure
      ui.style.spacing.item_spacing = saved
    end
    # Sunken bevel: dark bottom/right edges over the frame fill.
    p.line(Egui::Pos2.new(box.min.x, box.max.y - 0.5),
      Egui::Pos2.new(box.max.x - 0.5, box.max.y - 0.5), 1.0, PaintXp::BEVEL_DK)
    p.line(Egui::Pos2.new(box.max.x - 0.5, box.min.y),
      Egui::Pos2.new(box.max.x - 0.5, box.max.y - 0.5), 1.0, PaintXp::BEVEL_DK)
  end

  private def draw_selection_mode_glyph(p : Egui::Painter, r : Egui::Rect,
                                        transparent : Bool) : Nil
    inner = Egui::Rect.from_min_size(
      Egui::Pos2.new(r.center.x - 6.0, r.center.y - 5.0),
      Egui::Vec2.new(12.0, 10.0))
    p.rect(inner, 0.0, PaintXp::WHITE,
      PaintXp::BLACK, 1.0)
    if transparent
      # checkered holes
      2.times do |yy|
        3.times do |xx|
          next if (xx + yy).odd?
          p.rect(Egui::Rect.from_min_size(
            Egui::Pos2.new(inner.min.x + 1.0 + xx * 3.5,
              inner.min.y + 1.0 + yy * 3.0),
            Egui::Vec2.new(3.0, 2.5)), 0.0, PaintXp::FACE)
        end
      end
    else
      p.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(inner.min.x + 2.0, inner.min.y + 2.0),
        Egui::Vec2.new(8.0, 6.0)), 0.0, PaintXp::BLACK)
    end
  end

  private def draw_fill_style_glyph(p : Egui::Painter, r : Egui::Rect,
                                    style : Symbol) : Nil
    inner = Egui::Rect.from_min_size(
      Egui::Pos2.new(r.center.x - 5.0, r.center.y - 4.0),
      Egui::Vec2.new(10.0, 8.0))
    case style
    when :outline
      p.rect(inner, 0.0, nil, PaintXp::BLACK, 1.0)
    when :filled
      p.rect(inner, 0.0, PaintXp::BLACK)
    else
      p.rect(inner, 0.0, PaintXp::BLACK, PaintXp::BLACK, 1.0)
    end
  end

  private def draw_brush_glyph(p : Egui::Painter, r : Egui::Rect,
                               shape : Symbol, size : Int32) : Nil
    c = r.center
    case shape
    when :circle
      p.circle(c, size.to_f64 / 2.0, fill: PaintXp::BLACK)
    when :square
      p.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(c.x - size / 2, c.y - size / 2),
        Egui::Vec2.new(size.to_f64, size.to_f64)), 0.0, PaintXp::BLACK)
    when :fslash
      p.line(Egui::Pos2.new(c.x - size / 2, c.y - size / 2 + 1),
        Egui::Pos2.new(c.x + size / 2, c.y + size / 2 - 1),
        {size.to_f64 / 2, 2.0}.max, PaintXp::BLACK)
    when :bslash
      p.line(Egui::Pos2.new(c.x - size / 2, c.y + size / 2 - 1),
        Egui::Pos2.new(c.x + size / 2, c.y - size / 2 + 1),
        {size.to_f64 / 2, 2.0}.max, PaintXp::BLACK)
    end
  end

  # --- palette ---------------------------------------------------------

  SWATCH = 16.0

  private def draw_palette(ui : Egui::Ui) : Nil
    p = ui.painter
    rect = ui.allocate_at_least(ui.available_size)
    input = ui.ctx.input

    # overlapped fg/bg block
    bg_r = Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.min.x + 12.0, rect.min.y + 16.0),
      Egui::Vec2.new(16.0, 16.0))
    fg_r = Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.min.x + 7.0, rect.min.y + 11.0),
      Egui::Vec2.new(16.0, 16.0))
    block_resp = ui.interact(fg_r.union(bg_r), ui.named_id("fgbg"),
      Egui::Sense::Click)
    if block_resp.double_clicked?
      @edit_slot = -1 # -1 = edit fg directly
      @edit_orig = @fg
      @dialog = :edit_color
    end
    [bg_r, fg_r].each do |r|
      color = r == fg_r ? @fg : @bg
      p.rect(r, 0.0, color, PaintXp::BEVEL_DK, 1.0)
    end

    # 2×14 grid
    PaintXp::PALETTE.each_with_index do |color, i|
      col = i % 14
      row = i // 14
      r = Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.min.x + 40.0 + col * (SWATCH + 1.0),
          rect.min.y + 8.0 + row * (SWATCH + 1.0)),
        Egui::Vec2.new(SWATCH, SWATCH))
      resp = ui.interact(r, ui.named_id("swatch#{i}"), Egui::Sense::Click)
      resp.on_hover_cursor(Egui::CursorIcon::Pointer)
      p.rect(r, 0.0, color, PaintXp::BEVEL_DK, 1.0)
      if resp.clicked?
        @fg = color
        @edit_slot = i
      end
      # right-click sets the background color
      if input.secondary_pressed? && (sp = input.secondary_pos) &&
         r.contains?(sp)
        @bg = color
      end
      if resp.double_clicked?
        @edit_slot = i
        @edit_orig = color
        @dialog = :edit_color
      end
    end
  end

  # --- status bar ------------------------------------------------------

  private def draw_status(ui : Egui::Ui) : Nil
    p = ui.painter
    rect = ui.allocate_at_least(ui.available_size)
    p.line(Egui::Pos2.new(rect.min.x, rect.min.y + 0.5),
      Egui::Pos2.new(rect.max.x, rect.min.y + 0.5), 1.0, PaintXp::BEVEL_DK)
    text_color = PaintXp::BLACK
    font = 11.0

    hint_w = 300.0
    p.text(Egui::Pos2.new(rect.min.x + 6.0, rect.min.y + rect.height / 2),
      @status, font, text_color)

    # right-aligned sunken info cells: cursor coords, drag size, zoom
    cells = [] of Tuple(Float64, String)
    if (c = @cursor_px)
      cells << {70.0, "#{c[0]},#{c[1]}"}
    end
    if (d = @drag_size)
      cells << {84.0, "#{d[0]}×#{d[1]}"}
    end
    cells << {64.0, "#{@zoom}×"}
    x = rect.max.x - 6.0
    cells.each do |w0, label|
      x -= w0
      r = Egui::Rect.from_min_size(Egui::Pos2.new(x, rect.min.y + 3.0),
        Egui::Vec2.new(w0 - 2.0, rect.height - 5.0))
      p.rect(r, 0.0, PaintXp::FACE)
      p.line(r.min + Egui::Vec2.new(0.0, 0.5),
        Egui::Pos2.new(r.max.x - 0.5, r.min.y + 0.5), 1.0, PaintXp::BEVEL_DK)
      p.line(r.min + Egui::Vec2.new(0.5, 0.0),
        Egui::Pos2.new(r.min.x + 0.5, r.max.y - 0.5), 1.0, PaintXp::BEVEL_DK)
      p.line(Egui::Pos2.new(r.min.x + 0.5, r.max.y - 0.5),
        Egui::Pos2.new(r.max.x - 0.5, r.max.y - 0.5), 1.0, PaintXp::WHITE)
      p.line(Egui::Pos2.new(r.max.x - 0.5, r.min.y + 0.5),
        Egui::Pos2.new(r.max.x - 0.5, r.max.y - 0.5), 1.0, PaintXp::WHITE)
      tw = ui.ctx.fonts.measure(label, font).x
      p.text(Egui::Pos2.new(r.max.x - 4.0 - tw, r.center.y), label, font,
        text_color)
      x -= 2.0
    end
  end
end

# --- workspace + tool dispatch ----------------------------------------
class PaintApp
  private def draw_workspace(ctx : Egui::Context, ui : Egui::Ui) : Nil
    scroll = Egui::ScrollArea.new(nil, :classic, :right, :bottom)
    scroll.show(ui) do |inner|
      inner.allocate_space(Egui::Vec2.new(3.0, 3.0))
      ia = @canvas.show(inner)
      rect = ia.response.rect
      if PaintXp::TOOLS[@tool][0] == :fill && (cursor = @fill_cursor)
        ia.response.on_hover_cursor_image(cursor)
      else
        ia.response.on_hover_cursor(cursor_for_tool)
      end
      handle_tools(ctx, ia, rect)
      handle_canvas_resize(ctx, inner, rect)
      draw_overlays(ctx, ia, rect)
    end
    @canvas.flush(ctx) if @canvas.dirty?
    ctx.request_repaint if @canvas.dirty?
  end

  # The fill tool's bitmap cursor: cell 3 ("Fill With Color") of the
  # 256×16 tools sprite, cropped CPU-side and 2x nearest-upscaled to
  # 32×32. The hotspot is the pouring spout (lower left of the bucket).
  private def build_fill_cursor : Egui::CustomCursorImage?
    decoded = Egui::Backend::Sokol.load_rgba(
      File.join({{ __DIR__ }}, "../assets/paint/tools.png"))
    return nil unless decoded
    rgba = decoded[:rgba]
    width = decoded[:width]
    height = decoded[:height]
    return nil unless width == 256 && height == 16

    cell = 3
    scale = 2
    out_size = 16 * scale
    pixels = Bytes.new(out_size * out_size * 4)
    out_size.times do |y|
      out_size.times do |x|
        sx = cell * 16 + x // scale
        sy = y // scale
        s = (sy * width + sx) * 4
        d = (y * out_size + x) * 4
        pixels[d, 4].copy_from(rgba.to_unsafe + s, 4)
      end
    end
    Egui::CustomCursorImage.new(pixels, out_size, out_size, 3 * scale, 12 * scale)
  end

  private def cursor_for_tool : Egui::CursorIcon
    case PaintXp::TOOLS[@tool][0]
    when :text then
       Egui::CursorIcon::Text
    when :magnifier then
       Egui::CursorIcon::ZoomIn
    when :picker, :fill then
       Egui::CursorIcon::Pointer
    else                      Egui::CursorIcon::Crosshair
    end
  end

  # --- canvas resize handles --------------------------------------------
  #
  # jspaint-style: grips on the right edge, the bottom edge and the
  # bottom-right corner of the white canvas drag the image size (content
  # anchored top-left, new area in the background color). The grab strips
  # sit OUTSIDE the canvas, in the gray workspace (1 px overlap so they
  # still catch the pointer when the canvas fills the viewport), and are
  # interacted AFTER the canvas widget — hit-testing is topmost-last, so
  # they claim the pointer over the canvas itself. The outside placement
  # also keeps them grabbable when a press is batched with the first
  # motion event, and leaves the canvas free for drawing.

  RESIZE_GRIP = 14.0

  private def handle_canvas_resize(ctx : Egui::Context, ui : Egui::Ui,
                                   rect : Egui::Rect) : Nil
    g = RESIZE_GRIP
    right = Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.max.x - 1, rect.min.y),
      Egui::Vec2.new(g, rect.height))
    bottom = Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.min.x, rect.max.y - 1),
      Egui::Vec2.new(rect.width, g))
    corner = Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.max.x - 1, rect.max.y - 1),
      Egui::Vec2.new(g, g))

    modes = {
      right:  {right, Egui::CursorIcon::EwResize},
      bottom: {bottom, Egui::CursorIcon::NsResize},
      corner: {corner, Egui::CursorIcon::NwseResize},
    }
    modes.each do |mode, (hrect, cursor)|
      # The strips reach past the scroll viewport's edge (the classic
      # scrollbar reserves 16px there), so interact with a clip widened
      # by the strip itself — the same trick the overlay scrollbar uses
      # for its margin-side track.
      resp = ctx.interact(ui.named_id("cresize_#{mode}"), hrect,
        Egui::Sense.click_and_drag, ui.layer, ui.clip.union(hrect))
      resp.on_hover_and_drag_cursor(cursor)
      @status = "Drag to resize the image" if resp.hovered?
      next unless resp.dragged? || resp.drag_stopped?
      push_undo if resp.drag_started?
      if (p = ctx.input.pointer_pos)
        nw = ((p.x - rect.min.x) / @zoom).round.to_i.clamp(1, 16384)
        nh = ((p.y - rect.min.y) / @zoom).round.to_i.clamp(1, 16384)
        case mode
        when :right  then resize_canvas(nw, @canvas.height, record: false)
        when :bottom then resize_canvas(@canvas.width, nh, record: false)
        else              resize_canvas(nw, nh, record: false)
        end
        @drag_size = {@canvas.width, @canvas.height}
        ctx.request_repaint
      end
      if resp.drag_stopped?
        @drag_size = nil
        @status = "Resized to #{@canvas.width}×#{@canvas.height}"
      end
    end

    # Visible affordance: grip squares centered ON the canvas border
    # (half in, half out, MSPaint-style) at the middle of the right and
    # bottom edges and at the corner. Screen overlay, not canvas
    # pixels. The clip is widened past the scroll viewport's
    # classic-scrollbar reservation so the outer half survives.
    p = ui.painter
    old_clip = p.clip
    centers = {
      Egui::Pos2.new(rect.max.x, rect.center.y),
      Egui::Pos2.new(rect.center.x, rect.max.y),
      Egui::Pos2.new(rect.max.x, rect.max.y),
    }
    centers.each do |c|
      r = grip_rect(c)
      p.clip = old_clip.union(r)
      p.rect(r, 0.0, PaintXp::FACE, PaintXp::BEVEL_DK, 1.0)
    end
    p.clip = old_clip
  end

  private def grip_rect(c : Egui::Pos2) : Egui::Rect
    Egui::Rect.from_min_size(
      Egui::Pos2.new(c.x - RESIZE_GRIP / 2, c.y - RESIZE_GRIP / 2),
      Egui::Vec2.new(RESIZE_GRIP, RESIZE_GRIP))
  end

  private def pt(p : Egui::Pos2) : {Int32, Int32}
    {p.x.round.to_i, p.y.round.to_i}
  end

  private def handle_tools(ctx : Egui::Context,
                           ia : Egui::Canvas::Interaction,
                           rect : Egui::Rect) : Nil
    @cursor_px = ia.pointer_px.try { |p| pt(p) }
    @drag_size = nil if ia.drag_stopped? || !ia.dragging?

    case PaintXp::TOOLS[@tool][0]
    when :pencil, :brush, :eraser, :airbrush
      handle_freehand(ctx, ia)
    when :line, :rect, :ellipse, :round_rect
      handle_shape(ctx, ia)
    when :curve then
       handle_curve(ctx, ia)
    when :polygon then
       handle_polygon(ctx, ia)
    when :fill then
       handle_fill(ia)
    when :picker then
       handle_picker(ia)
    when :magnifier then
       handle_magnifier(ia)
    when :text then
       handle_text_tool(ctx, ia)
    when :select, :free_select then
       handle_select(ctx, ia)
    end
  end

  # --- freehand: pencil / brush / eraser / airbrush ---------------------

  private def handle_freehand(ctx : Egui::Context,
                              ia : Egui::Canvas::Interaction) : Nil
    if ia.drag_started? && (c = ia.pointer_px)
      push_undo
      @free_button = ia.drag_button
      @last_pt = pt(c)
      freehand_dab(pt(c))
    end
    if ia.dragging? && @free_button && (c = ia.pointer_px)
      cur = pt(c)
      freehand_segment(@last_pt.not_nil!, cur)
      @last_pt = cur
      ctx.request_repaint if (PaintXp::TOOLS[@tool][0] == :airbrush)
    end
    if ia.drag_stopped?
      @free_button = nil
      @last_pt = nil
    end
  end

  private def draw_color(button : Symbol?) : Egui::Color32
    button == :secondary ? @bg : @fg
  end

  private def freehand_dab(at : {Int32, Int32}) : Nil
    case PaintXp::TOOLS[@tool][0]
    when :pencil then
       @canvas[at[0], at[1]] = draw_color(@free_button)
    when :brush then
       @canvas.stamp(at[0], at[1], @brush_size, @brush_shape, draw_color(@free_button))
    when :eraser then
       erase_dab(at)
    when :airbrush then
       spray(at)
    end
  end

  private def freehand_segment(from : {Int32, Int32}, to : {Int32, Int32}) : Nil
    color = draw_color(@free_button)
    case PaintXp::TOOLS[@tool][0]
    when :pencil then
       @canvas.line(from[0], from[1], to[0], to[1], color, 1)
    when :brush then
       @canvas.brush_line(from[0], from[1], to[0], to[1], @brush_size, @brush_shape, color)
    when :eraser then
       erase_segment(from, to)
    when :airbrush then
       spray(to)
    end
  end

  private def erase_dab(at : {Int32, Int32}) : Nil
    r = @eraser_size // 2
    color_eraser = @free_button == :secondary
    (-r..r).each do |dy|
      (-r..r).each do |dx|
        x, y = at[0] + dx, at[1] + dy
        next unless @canvas.inside?(x, y)
        if color_eraser
          @canvas[x, y] = @bg if @canvas[x, y] == @fg
        else
          @canvas[x, y] = @bg
        end
      end
    end
    @canvas.mark_dirty
  end

  private def erase_segment(from : {Int32, Int32}, to : {Int32, Int32}) : Nil
    dx = (to[0] - from[0]).abs
    dy = (to[1] - from[1]).abs
    steps = {dx + dy, 1}.max
    (0..steps).each do |i|
      t = i.to_f64 / steps
      erase_dab({(from[0] + (to[0] - from[0]) * t).round.to_i,
        (from[1] + (to[1] - from[1]) * t).round.to_i})
    end
  end

  private def spray(at : {Int32, Int32}) : Nil
    color = draw_color(@free_button)
    dots = @airbrush_r * 2 // 3
    dots.times do
      ang = rand * Math::TAU
      rr = @airbrush_r.to_f64 * Math.sqrt(rand)
      @canvas[(at[0] + rr * Math.cos(ang)).round.to_i,
        (at[1] + rr * Math.sin(ang)).round.to_i] = color
    end
  end

  # --- shapes: line / rect / ellipse / rounded rect ---------------------

  private def handle_shape(ctx : Egui::Context,
                           ia : Egui::Canvas::Interaction) : Nil
    if ia.drag_started? && (sp = ia.drag_start_px)
      @shape_start = pt(sp)
    end
    if ia.dragging? && (c = ia.pointer_px) && (s = @shape_start)
      cur = pt(c)
      @drag_size = {(cur[0] - s[0]).abs + 1, (cur[1] - s[1]).abs + 1}
    end
    if ia.drag_stopped? && (c = ia.pointer_px) && (s = @shape_start)
      commit_shape(s0: s, s1: pt(c), button: ia.drag_button)
      @shape_start = nil
      @drag_size = nil
    end
  end

  private def commit_shape(s0 : {Int32, Int32}, s1 : {Int32, Int32},
                           button : Symbol?) : Nil
    push_undo
    outline = draw_color(button)
    fill = draw_color(button == :primary ? :secondary : :primary)
    x0, y0 = s0
    x1, y1 = s1
    case PaintXp::TOOLS[@tool][0]
    when :line
      @canvas.line(x0, y0, x1, y1, outline, @line_width)
    when :rect
      x, y = {x0, x1}.min, {y0, y1}.min
      w, h = (x1 - x0).abs + 1, (y1 - y0).abs + 1
      style_shape(x, y, w, h, outline, fill) do |o, f|
        @canvas.rect_outline(x, y, w, h, o, @line_width) if o
        @canvas.rect_fill(x, y, w, h, f) if f
      end
    when :ellipse
      x, y = {x0, x1}.min, {y0, y1}.min
      w, h = (x1 - x0).abs + 1, (y1 - y0).abs + 1
      style_shape(x, y, w, h, outline, fill) do |o, f|
        @canvas.ellipse_fill(x, y, w, h, f) if f
        @canvas.ellipse_outline(x, y, w, h, o, @line_width) if o
      end
    when :round_rect
      x, y = {x0, x1}.min, {y0, y1}.min
      w, h = (x1 - x0).abs + 1, (y1 - y0).abs + 1
      style_shape(x, y, w, h, outline, fill) do |o, f|
        draw_round_rect(x, y, w, h, o, f)
      end
    end
  end

  # Runs the block with outline/fill colors set per the fill style.
  private def style_shape(x, y, w, h, outline, fill,
                          & : Egui::Color32?, Egui::Color32? ->)
    case @fill_style
    when :outline then yield outline, nil
    when :filled  then yield nil, fill
    when :both    then yield outline, fill
    end
  end

  # Rounded rectangle from spans (corner radius = min(w,h)/4, capped).
  private def draw_round_rect(x : Int32, y : Int32, w : Int32, h : Int32,
                              outline : Egui::Color32?, fill : Egui::Color32?) : Nil
    r = ({w, h}.min // 4).clamp(1, 24)
    inset = uninitialized Int32 -> Int32
    spans = [] of Tuple(Int32, Int32, Int32) # y, x_from, x_to
    h.times do |yy|
      ins = 0
      if yy < r
        dy = r - yy
        ins = r - Math.sqrt(r * r - dy * dy).round.to_i
      elsif yy >= h - r
        dy = yy - (h - 1 - r)
        ins = r - Math.sqrt(r * r - dy * dy).round.to_i
      end
      spans << {y + yy, x + ins, x + w - 1 - ins}
    end
    if fill
      spans.each { |sy, xa, xb| @canvas.span(xa, xb, sy, fill) }
    end
    if outline
      r2 = @line_width == 1 ? 0 : @line_width // 2
      spans.each_with_index do |(sy, xa, xb), i|
        if i == 0 || i == h - 1
          @canvas.span(xa, xb, sy, outline)
          (@line_width - 1).times do |k|
            @canvas.span(xa, xb, sy + (i == 0 ? 1 + k : -1 - k), outline)
          end
        end
        (-r2..r2).each do |k|
          @canvas[xa, sy + k] = outline
          @canvas[xb, sy + k] = outline
        end
      end
    end
  end

  # --- curve -----------------------------------------------------------

  private def handle_curve(ctx : Egui::Context,
                           ia : Egui::Canvas::Interaction) : Nil
    if (cs = @curve).nil?
      # stage 0: straight-line drag, exactly like the Line tool
      if ia.drag_started? && (sp = ia.drag_start_px)
        @shape_start = pt(sp)
      end
      if ia.dragging? && (c = ia.pointer_px) && (s = @shape_start)
        @drag_size = {(pt(c)[0] - s[0]).abs + 1, (pt(c)[1] - s[1]).abs + 1}
      end
      if ia.drag_stopped? && (c = ia.pointer_px) && (s = @shape_start)
        @curve = CurveState.new(s, pt(c))
        @shape_start = nil
        @drag_size = nil
      end
    else
      # bending stages
      if ia.drag_started? && (c = ia.pointer_px)
        @shape_start = pt(c)
      end
      if ia.dragging? && (c = ia.pointer_px)
        case cs.stage
        when 1 then cs.c1 = pt(c)
        when 2 then cs.c2 = pt(c)
        end
        ctx.request_repaint
      end
      if ia.drag_stopped?
        cs.stage += 1
        if cs.stage > 2
          commit_curve
        end
      end
      # a plain click (no drag) finishes the curve as-is
      if ia.click_px && !ia.dragging?
        commit_curve
      end
    end
  end

  private def commit_curve : Nil
    if (cs = @curve)
      push_undo
      pts = cs.points
      pts.each_cons(2) do |pair|
        a, b = pair
        @canvas.line(a[0], a[1], b[0], b[1], @fg, @line_width)
      end
    end
    @curve = nil
  end

  # --- polygon ---------------------------------------------------------

  private def handle_polygon(ctx : Egui::Context,
                             ia : Egui::Canvas::Interaction) : Nil
    ctx.request_repaint unless @poly.empty?
    if (c = ia.double_click_px)
      @poly << pt(c) # the second click of the double-click
      commit_polygon if @poly.size >= 3
      return
    end
    if (c = ia.click_px)
      p = pt(c)
      if !@poly.empty? &&
         (@poly[0][0] - p[0]).abs <= 3 && (@poly[0][1] - p[1]).abs <= 3
        commit_polygon if @poly.size >= 3
      else
        @poly << p
      end
    end
    if ia.drag_started? || ia.dragging?
      # dragging is not the polygon gesture; ignore
    end
  end

  private def commit_polygon : Nil
    push_undo
    outline = @fg
    fill = @bg
    if @fill_style != :outline
      polygon_fill(@poly, fill)
    end
    if @fill_style != :filled
      @poly.each_cons(2) do |pair|
      a, b = pair
        @canvas.line(a[0], a[1], b[0], b[1], outline, @line_width)
      end
      a0 = @poly.first
      a1 = @poly.last
      @canvas.line(a1[0], a1[1], a0[0], a0[1], outline, @line_width)
    end
    @poly.clear
  end

  # Even-odd scanline polygon fill.
  private def polygon_fill(vertices : Array({Int32, Int32}),
                           color : Egui::Color32) : Nil
    return if vertices.size < 3
    ys = vertices.map(&.[1])
    y_min, y_max = ys.min, ys.max
    (y_min..y_max).each do |y|
      xs = [] of Int32
      vertices.each_index do |i|
        a = vertices[i]
        b = vertices[(i + 1) % vertices.size]
        next unless (a[1] <= y && b[1] > y) || (b[1] <= y && a[1] > y)
        xs << (a[0] + (y - a[1]).to_f64 / (b[1] - a[1]) *
          (b[0] - a[0])).round.to_i
      end
      xs.sort!
      (0...xs.size).step(2) do |k|
        break if k + 1 >= xs.size
        @canvas.span(xs[k], xs[k + 1], y, color)
      end
    end
  end

  # --- click tools: fill / picker / magnifier ---------------------------

  private def handle_fill(ia : Egui::Canvas::Interaction) : Nil
    if (c = ia.click_px)
      push_undo
      @canvas.flood_fill(c.x.to_i, c.y.to_i, @fg)
    end
    if (c = ia.secondary_click_px)
      push_undo
      @canvas.flood_fill(c.x.to_i, c.y.to_i, @bg)
    end
  end

  private def handle_picker(ia : Egui::Canvas::Interaction) : Nil
    if (c = ia.click_px)
      @fg = @canvas[c.x.to_i, c.y.to_i]
    end
    if (c = ia.secondary_click_px)
      @bg = @canvas[c.x.to_i, c.y.to_i]
    end
  end

  private def handle_magnifier(ia : Egui::Canvas::Interaction) : Nil
    if ia.click_px
      set_zoom(@zoom >= 8 ? 1 : @zoom * 2)
    elsif ia.secondary_click_px
      set_zoom(@zoom <= 1 ? 8 : @zoom // 2)
    end
  end

  private def set_zoom(z : Int32) : Nil
    @zoom = z.clamp(1, 8)
  end
end

# --- text tool ---------------------------------------------------------
class PaintApp
  private def handle_text_tool(ctx : Egui::Context,
                               ia : Egui::Canvas::Interaction) : Nil
    if (t = @text).nil?
      if (c = ia.click_px) || (c = ia.secondary_click_px)
        p0 = pt(c.not_nil!)
        push_undo
        @text = TextState.new(p0[0], p0[1], @canvas.snapshot)
        ctx.request_repaint
      end
      return
    end

    # typing
    changed = false
    unless ctx.input.text.empty?
      t.buf += ctx.input.text
      changed = true
    end
    if ctx.input.consume_key(Egui::KeyCode::Backspace) && !t.buf.empty?
      # remove the last CHARACTER (UTF-8 aware)
      t.buf = t.buf[0...t.buf.char_index_to_byte_index(t.buf.chars.size - 1)]
      changed = true
    end
    if ctx.input.consume_key(Egui::KeyCode::Enter)
      finish_text
      return
    end
    if ctx.input.consume_key(Egui::KeyCode::Escape)
      cancel_text
      return
    end
    changed = true if t.rendered_size != @text_size

    # click elsewhere commits the session
    if (c = ia.click_px) || (c = ia.secondary_click_px)
      p0 = pt(c.not_nil!)
      size = @text_raster.measure(t.buf, @text_size)
      inside = p0[0] >= t.x - 2 && p0[1] >= t.y - 2 &&
               p0[0] <= t.x + size.x + 2 && p0[1] <= t.y + size.y + 2
      finish_text unless inside
      return
    end

    if changed || t.rendered != t.buf
      @canvas.restore(t.base)
      @text_raster.draw(@canvas, t.x, t.y, t.buf, @text_size, @fg)
      t.rendered = t.buf
      t.rendered_size = @text_size
      ctx.request_repaint
    end
  end

  # Commit the floating text (it is already painted into the canvas).
  private def finish_text : Nil
    if (t = @text) && t.buf.empty?
      cancel_text
    else
      @text = nil
    end
  end

  private def cancel_text : Nil
    if (t = @text)
      @canvas.restore(t.base)
      @undo.pop
    end
    @text = nil
  end

  # --- selection tools ---------------------------------------------------

  private def handle_select(ctx : Egui::Context,
                            ia : Egui::Canvas::Interaction) : Nil
    free_form = (PaintXp::TOOLS[@tool][0] == :free_select)

    if (sel = @sel) && sel.dragging?
      # Move drag: each frame re-blit the float at the pointer offset.
      if (c = ia.pointer_px)
        p0 = pt(c)
        sel.x = p0[0] - sel.grab_dx
        sel.y = p0[1] - sel.grab_dy
        if (base = sel.move_base)
          @canvas.restore(base)
          @canvas.blit(sel.x, sel.y, sel.img, sel.w, sel.h,
            @opaque ? nil : @bg)
          ctx.request_repaint
        end
      end
      if ia.drag_stopped?
        sel.dragging = false
      end
      return
    end

    if ia.drag_started? && (sp = ia.drag_start_px)
      p0 = pt(sp)
      if (sel = @sel) && sel.contains?(p0[0], p0[1])
        # begin moving the existing float
        sel.dragging = true
        sel.grab_dx = p0[0] - sel.x
        sel.grab_dy = p0[1] - sel.y
        unless (base = sel.move_base)
          push_undo
          sel.img = @canvas.region(sel.x, sel.y, sel.w, sel.h)
          @canvas.erase_region(sel.x, sel.y, sel.w, sel.h, @bg)
          sel.move_base = @canvas.snapshot
        end
        return
      end
      # a fresh marquee: any existing float is already committed in the
      # pixels — just drop it
      @sel = nil
      @shape_start = p0
      @lasso = [p0] if free_form
    end

    if ia.dragging? && (c = ia.pointer_px) && (s = @shape_start)
      p1 = pt(c)
      @drag_size = {(p1[0] - s[0]).abs + 1, (p1[1] - s[1]).abs + 1}
      @lasso << p1 if free_form && @lasso.last != p1
    end

    if ia.drag_stopped? && (c = ia.pointer_px) && (s = @shape_start)
      p1 = pt(c)
      @shape_start = nil
      @drag_size = nil
      if free_form
        finish_lasso
      else
        x, y = {s[0], p1[0]}.min, {s[1], p1[1]}.min
        w, h = (p1[0] - s[0]).abs + 1, (p1[1] - s[1]).abs + 1
        make_selection(x, y, w, h)
      end
    end

    # a plain click outside the float deselects (float stays painted)
    if (c = ia.click_px) && @sel
      p0 = pt(c)
      @sel = nil unless @sel.not_nil!.contains?(p0[0], p0[1])
    end
  end

  private def finish_lasso : Nil
    return if @lasso.empty?
    xs = @lasso.map(&.[0])
    ys = @lasso.map(&.[1])
    x, y = xs.min, ys.min
    w, h = xs.max - x + 1, ys.max - y + 1
    @lasso.clear
    make_selection(x, y, w, h)
  end

  private def make_selection(x : Int32, y : Int32, w : Int32, h : Int32) : Nil
    return if w < 2 || h < 2 # a bare click deselects
    x = x.clamp(0, @canvas.width - 1)
    y = y.clamp(0, @canvas.height - 1)
    w = {w, @canvas.width - x}.min
    h = {h, @canvas.height - y}.min
    @sel = SelState.new(x, y, w, h, @canvas.region(x, y, w, h))
  end

  private def delete_selection : Nil
    return unless (sel = @sel)
    push_undo
    @canvas.erase_region(sel.x, sel.y, sel.w, sel.h, @bg)
    @sel = nil
  end

  private def select_all : Nil
    @sel = SelState.new(0, 0, @canvas.width, @canvas.height,
      @canvas.region(0, 0, @canvas.width, @canvas.height))
  end

  # --- overlays (shape previews, marching-ants selection) ---------------

  private def draw_overlays(ctx : Egui::Context,
                            ia : Egui::Canvas::Interaction,
                            rect : Egui::Rect) : Nil
    p = ctx.painter
    outer = p.clip
    p.clip = Egui::Rect.new(
      Egui::Pos2.new({outer.min.x, rect.min.x}.max, {outer.min.y, rect.min.y}.max),
      Egui::Pos2.new({outer.max.x, rect.max.x}.min, {outer.max.y, rect.max.y}.min))
    s = @zoom.to_f64
    to_screen = ->(px : {Int32, Int32}) do
      Egui::Pos2.new(rect.min.x + px[0] * s, rect.min.y + px[1] * s)
    end

    shape_dragging = ia.dragging? && @shape_start &&
                     !(PaintXp::TOOLS[@tool][0] == :select) &&
                     !(PaintXp::TOOLS[@tool][0] == :free_select)

    if shape_dragging && (c = ia.pointer_px) && (st = @shape_start)
      a = to_screen.call(st)
      b = to_screen.call(pt(c))
      color = draw_color(ia.drag_button)
      w = @line_width.to_f64 * s
      case PaintXp::TOOLS[@tool][0]
      when :line, :curve
        p.line(a, b, {w, s}.max, color)
      when :rect, :round_rect
        r = Egui::Rect.new(a, b)
        p.rect(Egui::Rect.from_min_size(r.min, r.size), 0.0, nil, color, w)
      when :ellipse
        p.circle(Egui::Pos2.new((a.x + b.x) / 2, (a.y + b.y) / 2),
          {(b.x - a.x).abs / 2, (b.y - a.y).abs / 2}.min,
          stroke: color, stroke_width: w)
      end
    end

    # curve stage 0 straight preview / bending preview
    if (cs = @curve)
      pts = cs.points
      pts.each_cons(2) do |pair|
        u, v = pair
        p.line(to_screen.call(u), to_screen.call(v), @line_width.to_f64 * s, @fg)
      end
    end

    # polygon in progress
    unless @poly.empty?
      pts = @poly.map { |v| to_screen.call(v) }
      pts.each_cons(2) do |pair|
        a, b = pair
        p.line(a, b, @line_width.to_f64 * s, @fg)
      end
      if (c = ia.pointer_px)
        p.line(pts.last, to_screen.call(pt(c)), @line_width.to_f64 * s, @fg)
      end
    end

    # lasso polyline
    if @lasso.size > 1
      pts = @lasso.map { |v| to_screen.call(v) }
      pts.each_cons(2) do |pair|
        a, b = pair
        p.line(a, b, 1.0, PaintXp::BLACK)
      end
    end

    # marquee rectangle while dragging a selection
    if ia.dragging? && @shape_start &&
       ((PaintXp::TOOLS[@tool][0] == :select) || (PaintXp::TOOLS[@tool][0] == :free_select)) &&
       (c = ia.pointer_px)
      dash_rect(p, Egui::Rect.new(to_screen.call(@shape_start.not_nil!),
        to_screen.call(pt(c))))
    end

    # active selection: dashed border
    if (sel = @sel)
      dash_rect(p, Egui::Rect.from_min_size(
        to_screen.call({sel.x, sel.y}),
        Egui::Vec2.new(sel.w * s, sel.h * s)))
    end

    # text session anchor + caret
    if (t = @text)
      a = to_screen.call({t.x, t.y})
      size = @text_raster.measure(t.buf, @text_size)
      p.rect(Egui::Rect.from_min_size(a,
        Egui::Vec2.new(size.x * 1.0, size.y * 1.0)), 0.0, nil, PaintXp::BLACK, 1.0)
    end

    p.clip = outer
  end

  # 4-on 4-off black/white dashed border ("marching ants", static).
  private def dash_rect(p : Egui::Painter, r : Egui::Rect) : Nil
    dash_line(p, r.min, Egui::Pos2.new(r.max.x, r.min.y))
    dash_line(p, Egui::Pos2.new(r.min.x, r.max.y), r.max)
    dash_line(p, r.min, Egui::Pos2.new(r.min.x, r.max.y))
    dash_line(p, Egui::Pos2.new(r.max.x, r.min.y), r.max)
  end

  private def dash_line(p : Egui::Painter, a : Egui::Pos2, b : Egui::Pos2) : Nil
    len = (b - a).length
    return if len < 1.0
    n = (len / 4.0).ceil.to_i
    n.times do |i|
      t0 = i.to_f64 / n
      t1 = (i + 0.5).to_f64 / n
      p0 = a + (b - a) * t0
      p1 = a + (b - a) * t1
      p.line(p0, p1, 1.0, i.even? ? PaintXp::BLACK : PaintXp::WHITE)
    end
  end
end

# --- undo / redo --------------------------------------------------------
class PaintApp
  private def push_undo : Nil
    @undo << Snap.new(@canvas.width, @canvas.height, @canvas.snapshot)
    @undo.shift if @undo.size > 25
    @redo.clear
    @doc_dirty = true
  end

  private def do_undo : Nil
    return if @undo.empty?
    @redo << Snap.new(@canvas.width, @canvas.height, @canvas.snapshot)
    s = @undo.pop
    @canvas.restore_sized(s.w, s.h, s.data)
  end

  private def do_redo : Nil
    return if @redo.empty?
    @undo << Snap.new(@canvas.width, @canvas.height, @canvas.snapshot)
    s = @redo.pop
    @canvas.restore_sized(s.w, s.h, s.data)
  end

  # --- whole-image transforms -------------------------------------------

  # Generic resampling transform: push undo (unless `record` is false —
  # live drag resizing records one snapshot at drag start), then fill a
  # new_w×new_h buffer where each pixel comes from the block's source
  # coords (out of range → background color).
  private def xform(new_w : Int32, new_h : Int32, record : Bool = true,
                    &src : Int32, Int32 -> {Int32, Int32}) : Nil
    return if new_w < 1 || new_h < 1 || new_w > 16384 || new_h > 16384
    return if new_w == @canvas.width && new_h == @canvas.height
    push_undo if record
    ow, oh = @canvas.width, @canvas.height
    srcbuf = @canvas.snapshot
    dst = Bytes.new(new_w.to_i64 * new_h * 4)
    # prefill with bg
    i = 0
    while i < dst.size
      dst[i] = @bg.r
      dst[i + 1] = @bg.g
      dst[i + 2] = @bg.b
      dst[i + 3] = 255_u8
      i += 4
    end
    (0...new_h).each do |dy|
      (0...new_w).each do |dx|
        sx, sy = yield dx, dy
        next unless sx >= 0 && sy >= 0 && sx < ow && sy < oh
        si = (sy.to_i64 * ow + sx) * 4
        di = (dy.to_i64 * new_w + dx) * 4
        dst[di] = srcbuf[si]
        dst[di + 1] = srcbuf[si + 1]
        dst[di + 2] = srcbuf[si + 2]
        dst[di + 3] = srcbuf[si + 3]
      end
    end
    @canvas.resize(new_w, new_h)
    @canvas.replace_pixels(dst)
  end

  private def transform_flip(horizontal : Bool) : Nil
    ow, oh = @canvas.width, @canvas.height
    if horizontal
      xform(ow, oh) { |dx, dy| {ow - 1 - dx, dy} }
    else
      xform(ow, oh) { |dx, dy| {dx, oh - 1 - dy} }
    end
  end

  private def transform_rotate(deg : Int32) : Nil
    ow, oh = @canvas.width, @canvas.height
    case deg
    when 90  then xform(oh, ow) { |dx, dy| {dy, oh - 1 - dx} }
    when 180 then xform(ow, oh) { |dx, dy| {ow - 1 - dx, oh - 1 - dy} }
    when 270 then xform(oh, ow) { |dx, dy| {ow - 1 - dy, dx} }
    end
  end

  private def transform_stretch(pct_h : Int32, pct_v : Int32,
                                skew_h : Int32, skew_v : Int32) : Nil
    ow, oh = @canvas.width, @canvas.height
    nw = (ow * pct_h / 100).clamp(1, 16384).to_i
    nh = (oh * pct_v / 100).clamp(1, 16384).to_i
    th = Math.tan(skew_h * Math::PI / 180.0)
    tv = Math.tan(skew_v * Math::PI / 180.0)
    # stretch (inverse map) first, shear offsets in stretched space
    xform(nw, nh) do |dx, dy|
      sx = (dx.to_f64 * ow / nw).round.to_i
      sy = (dy.to_f64 * oh / nh).round.to_i
      sx -= (th * (dy - (nh - 1) / 2.0)).round.to_i
      sy -= (tv * (dx - (nw - 1) / 2.0)).round.to_i
      {sx, sy}
    end
  end

  private def resize_canvas(w : Int32, h : Int32, record : Bool = true) : Nil
    xform(w, h, record: record) { |dx, dy| {dx, dy} }
  end

  # --- file operations (all through the SystemPorts dialogs) ------------

  private def title_text : String
    "#{@path ? File.basename(@path.not_nil!) : "untitled"} - Paint"
  end

  private def refresh_title : Nil
    Egui::SystemPorts::Window.set_title(title_text)
  end

  private def new_doc : Nil
    commit_pending
    @canvas.resize(PaintXp::DEFAULT_W, PaintXp::DEFAULT_H)
    @undo.clear
    @redo.clear
    @path = nil
    @doc_dirty = false
    refresh_title
    @status = "New image (#{PaintXp::DEFAULT_W}×#{PaintXp::DEFAULT_H})"
  end

  private def open_doc : Nil
    Egui::SystemPorts::OpenFileDialog.show(
      title: "Open",
      filters: ["*.png"]
    ) do |path|
      next unless path
      begin
        img = PaintPng.decode_file(path)
        commit_pending
        @canvas.resize(img.width, img.height)
        @canvas.replace_pixels(img.rgba)
        @undo.clear
        @redo.clear
        @path = path
        @doc_dirty = false
        refresh_title
        @status = "Opened: #{path}"
      rescue e : PaintPng::PngError
        @status = "Cannot open: #{e.message}"
      end
    end
  end

  private def save_doc : Nil
    if (p = @path)
      write_file(p)
    else
      save_doc_as
    end
  end

  private def save_doc_as : Nil
    Egui::SystemPorts::SaveFileDialog.show(
      title: "Save As",
      filters: ["*.png"],
      default_name: "#{@path ? File.basename(@path.not_nil!, ".png") : "untitled"}.png"
    ) do |path|
      write_file(path) if path
    end
  end

  private def write_file(path : String) : Nil
    path = path.ends_with?(".png") ? path : "#{path}.png"
    begin
      File.write(path, PaintPng.encode(@canvas.pixels, @canvas.width,
        @canvas.height))
      @path = path
      @doc_dirty = false
      refresh_title
      @status = "Saved: #{path}"
    rescue e : IO::Error | File::Error
      @status = "Cannot save: #{e.message}"
    end
  end

  # --- clipboard paste ---------------------------------------------------

  # Edit → Paste: drop the clipboard image in as a floating selection at
  # the top-left corner (canvas grown to fit first), with the Select
  # tool active so the float can be dragged around — the same machinery
  # a moved selection uses (move_base snapshot + blit).
  private def paste_clipboard : Nil
    png = clipboard_png_bytes
    if png.nil?
      @status = "The clipboard contains no image."
      return
    end
    begin
      img = PaintPng.decode(png)
    rescue e : PaintPng::PngError
      @status = "Cannot paste: #{e.message}"
      return
    end
    commit_pending
    push_undo
    if img.width > @canvas.width || img.height > @canvas.height
      resize_canvas({img.width, @canvas.width}.max,
        {img.height, @canvas.height}.max, record: false)
    end
    select_tool(1) # Select
    sel = SelState.new(0, 0, img.width, img.height, img.rgba)
    sel.move_base = @canvas.snapshot
    @canvas.blit(0, 0, img.rgba, img.width, img.height)
    @sel = sel
    @status = "Pasted #{img.width}×#{img.height} (drag to move, Esc to drop)"
  end

  # PNG bytes from the system clipboard, or nil when it holds no image.
  # sokol_app only exposes the TEXT clipboard, so the image is fetched
  # from the platform's tool: wl-paste / xclip write PNG bytes to
  # stdout (Linux/BSD), pngpaste (macOS, Homebrew) and PowerShell's
  # Windows.Forms clipboard (Windows) save to a temp file instead.
  private def clipboard_png_bytes : Bytes?
    {% if flag?(:linux) || flag?(:bsd) %}
      if ENV["WAYLAND_DISPLAY"]? &&
         (png = run_stdout_png("wl-paste", ["-t", "image/png"]))
        return png
      end
      run_stdout_png("xclip", ["-selection", "clipboard", "-t", "image/png", "-o"])
    {% elsif flag?(:darwin) %}
      if command?("pngpaste")
        tmp = File.tempname("paint-clip", ".png")
        status = Process.run("pngpaste", [tmp],
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        return read_png_file(tmp) if status.success?
        File.delete?(tmp)
      end
      nil
    {% elsif flag?(:win32) %}
      tmp = File.tempname("paint-clip", ".png")
      script = "Add-Type -AssemblyName System.Windows.Forms; " \
               "$i=[System.Windows.Forms.Clipboard]::GetImage(); " \
               "if ($i) { $i.Save('#{tmp.gsub('\'', "''")}') }"
      Process.run("powershell", ["-NoProfile", "-STA", "-Command", script],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      read_png_file(tmp)
    {% else %}
      nil
    {% end %}
  end

  # Run cmd, return its stdout as PNG bytes when it exited 0 and wrote
  # what looks like a PNG; nil otherwise.
  private def run_stdout_png(cmd : String, args : Array(String)) : Bytes?
    return nil unless command?(cmd)
    sink = IO::Memory.new
    status = Process.run(cmd, args, output: sink,
      error: Process::Redirect::Close)
    return nil unless status.success?
    data = sink.to_slice
    data.size > 8 && data[0, 8] == PaintXp::PNG_SIG ? data.dup : nil
  end

  # Read (and delete) a PNG a clipboard tool saved to `path`; nil when
  # the file is missing or not a PNG.
  private def read_png_file(path : String) : Bytes?
    data = nil
    if File.exists?(path) && (size = File.size(path)) > 8
      buf = Bytes.new(size)
      File.open(path) { |f| f.read_fully(buf) }
      data = buf if buf[0, 8] == PaintXp::PNG_SIG
    end
    File.delete?(path)
    data
  rescue IO::Error
    nil
  end

  # Is `name` an executable on PATH? (Windows never reaches this — its
  # tools are looked up by the shell itself.)
  private def command?(name : String) : Bool
    {% if flag?(:win32) %}
      false
    {% else %}
      Process.run("which", [name], output: Process::Redirect::Close,
        error: Process::Redirect::Close).success?
    {% end %}
  end

  # Commit any pending multi-step interaction (text session, floating
  # selection, curve, polygon) — called on tool switch / new / open.
  private def commit_pending : Nil
    finish_text if @text
    @sel = nil
    @curve = nil
    @poly.clear
    @lasso.clear
    @shape_start = nil
  end

  private def select_tool(i : Int32) : Nil
    return if @tool == i
    commit_pending
    @tool = i
  end

  # --- exit flow --------------------------------------------------------
  #
  # Like MS Paint: quitting with unsaved changes asks "Save changes to
  # <name>?" — Yes saves (Save As first for an untitled image) and
  # quits, No quits, Cancel stays.

  # Every quit path (window ✕, ACTION_EXIT) lands here.
  def quit_requested : Nil
    if @exiting || !@doc_dirty
      do_quit
    else
      @dialog = :confirm_exit
    end
  end

  private def do_quit : Nil
    @exiting = true
    @orig_quit.not_nil!.quit
  end

  # --- dialogs ------------------------------------------------------------
  #
  # Luna-styled modal dialogs (PaintXp::Dialog): gradient caption with
  # the glossy close button, blue frame, XP push buttons bottom-right.
  # All of them are modal — everything below is blocked until dismissed.

  private def draw_dialogs(ctx : Egui::Context) : Nil
    case @dialog
    when :attributes
      clicked = PaintXp::Dialog.new(ctx, "attributes").show(
        "Attributes", 260.0, ["OK", "Cancel"]) do |ui|
        ui.label("Width:")
        ui.number_input(@attr_w, 1..16384) { |v| @attr_w = v }
        ui.label("Height:")
        ui.number_input(@attr_h, 1..16384) { |v| @attr_h = v }
        ui.label("Current size: #{@canvas.width}×#{@canvas.height} px")
      end
      if clicked
        resize_canvas(@attr_w, @attr_h) if clicked == "OK"
        @dialog = nil
      end
    when :stretch
      clicked = PaintXp::Dialog.new(ctx, "stretch").show(
        "Stretch and Skew", 280.0, ["OK", "Cancel"]) do |ui|
        ui.heading("Stretch")
        ui.label("Horizontal:")
        ui.number_input(@st_h, 1..800, suffix: "%") { |v| @st_h = v }
        ui.label("Vertical:")
        ui.number_input(@st_v, 1..800, suffix: "%") { |v| @st_v = v }
        ui.separator
        ui.heading("Skew")
        ui.label("Horizontal (degrees):")
        ui.number_input(@sk_h, -89..89, suffix: "°") { |v| @sk_h = v }
        ui.label("Vertical (degrees):")
        ui.number_input(@sk_v, -89..89, suffix: "°") { |v| @sk_v = v }
      end
      if clicked
        transform_stretch(@st_h, @st_v, @sk_h, @sk_v) if clicked == "OK"
        @dialog = nil
      end
    when :edit_color
      clicked = PaintXp::Dialog.new(ctx, "edit_color").show(
        "Edit Colors", 240.0, ["OK", "Cancel"]) do |ui|
        ui.color_edit32(@fg) do |c|
          @fg = c
          @palette[@edit_slot] = c if @edit_slot >= 0
        end
      end
      if clicked
        if clicked == "OK"
          @dialog = nil
        else # Cancel / ✕ reverts to the color the editor opened with
          @fg = @edit_orig
          @palette[@edit_slot] = @edit_orig if @edit_slot >= 0
          @dialog = nil
        end
      end
    when :confirm_exit
      name = @path ? File.basename(@path.not_nil!) : "untitled"
      clicked = PaintXp::Dialog.new(ctx, "confirm_exit").show(
        "Paint", 300.0, ["Yes", "No", "Cancel"]) do |ui|
        ui.label("Save changes to #{name}?")
      end
      case clicked
      when "Yes"
        @dialog = nil
        if (p = @path)
          write_file(p)
          do_quit unless @doc_dirty # save failed → stay (status says why)
        else
          Egui::SystemPorts::SaveFileDialog.show(
            title: "Save As",
            filters: ["*.png"],
            default_name: "untitled.png"
          ) do |path|
            if path
              write_file(path)
              do_quit unless @doc_dirty
            end
          end
        end
      when "No"
        @dialog = nil
        do_quit
      when "Cancel", PaintXp::Dialog::CLOSE
        @dialog = nil
      end
    when :about
      clicked = PaintXp::Dialog.new(ctx, "about").show(
        "About Paint", 300.0, ["OK"]) do |ui|
        ui.heading("egui.cr Paint")
        ui.label("A Windows XP Paint clone built on egui.cr.")
        ui.label("Tool icons: jspaint (MIT), 1j01.github.io/jspaint/")
      end
      @dialog = nil if clicked
    end
  end

  # --- action dispatch ------------------------------------------------------

  private def dispatch_actions(ctx : Egui::Context) : Nil
    new_doc if ctx.consume_action(ACTION_NEW)
    open_doc if ctx.consume_action(ACTION_OPEN)
    save_doc if ctx.consume_action(ACTION_SAVE)
    save_doc_as if ctx.consume_action(ACTION_SAVE_AS)
    quit_requested if ctx.consume_action(ACTION_EXIT)
    do_undo if ctx.consume_action(ACTION_UNDO)
    do_redo if ctx.consume_action(ACTION_REDO)
    paste_clipboard if ctx.consume_action(ACTION_PASTE)
    select_all if ctx.consume_action(ACTION_SEL_ALL)
    if ctx.consume_action(ACTION_DESEL)
      @sel = nil
      @poly.clear
      @curve = nil
    end
    delete_selection if ctx.consume_action(ACTION_DELETE)
    if ctx.consume_action(ACTION_INVERT)
      push_undo
      @canvas.invert
    end
    if ctx.consume_action(ACTION_CLEAR)
      push_undo
      @canvas.fill_with(@bg)
    end
  end
end

# The backend's Quit port, guarded by the app's exit confirmation:
# Quit.quit! from the window-frame ✕ (or anywhere else) routes through
# PaintApp#quit_requested instead of quitting on the spot; once the
# confirmation clears, PaintApp#do_quit calls the wrapped port itself.
class GuardedQuit < Egui::SystemPorts::Quit::Implementation
  def initialize(@app : PaintApp)
  end

  def quit : Nil
    @app.quit_requested
  end
end

Egui::Backend::Sokol.run(PaintApp.new,
  title: "untitled - Paint",
  # 692 tall so the default 640×480 canvas (plus chrome, toolbox,
  # palette, status bar and the classic-scrollbar reservations) fits
  # with slack to spare — the bottom resize grip and its marker must
  # stay visible even after a small corner-drag grow.
  width: 880, height: 692,
  decorations: false,
  chrome_style: Egui::WindowFrame::Style::WindowsXp,
  inspector: :hidden)
