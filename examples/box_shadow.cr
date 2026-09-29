# box-shadow demo — a replica of the Bootstrap 2.0.4 buttons and
# dropdowns (bootstrapdocs.com/v2.0.4/docs/components.html), built on
# `Painter#box_shadow` (a CSS box-shadow: outset AND inset):
#
#   .btn    { box-shadow: inset 0 1px 0 rgba(255,255,255,.2),
#                       0 1px 2px rgba(0,0,0,.05); }
#   .btn:active { box-shadow: inset 0 3px 5px rgba(0,0,0,.125); }
#   .dropdown-menu { box-shadow: 0 5px 10px rgba(0,0,0,.2); }
#
# The last section shows the same feature through the stylesheet
# cascade — `shadow.*` class keys on the standard `Button` widget
# (`button:active { shadow.inset }` is the pressed look, no custom
# painting involved).

require "../src/egui"
require "../src/egui/backend/sokol"

# Bootstrap 2.0.4 button palette: gradient stops (top/bottom) plus the
# label color. Hover darkens the stops ~7%, active ~18% (the v2
# background-position shift), with the shadows above.
module Bs
  WHITE        = Egui::Color32.rgb(255, 255, 255)
  TEXT_DARK    = Egui::Color32.rgb(0x33, 0x33, 0x33)
  LINK_BLUE    = Egui::Color32.rgb(0x00, 0x88, 0xcc)
  HOVER_BLUE   = Egui::Color32.rgb(0x00, 0x81, 0xcc)
  SHEEN        = Egui::Color32.rgba(255, 255, 255, 51)   # .2
  OUTER        = Egui::Color32.rgba(0, 0, 0, 13)         # .05
  PRESSED      = Egui::Color32.rgba(0, 0, 0, 32)         # .125
  MENU_SHADOW  = Egui::Color32.rgba(0, 0, 0, 51)         # .2
  BORDER_DARK  = Egui::Color32.rgba(0, 0, 0, 38)         # .15
  DIVIDER      = Egui::Color32.rgb(0xe5, 0xe5, 0xe5)

  # variant name => {gradient top, gradient bottom, label color}
  VARIANTS = {
    "default" => {Egui::Color32.rgb(0xf5, 0xf5, 0xf5), Egui::Color32.rgb(0xe6, 0xe6, 0xe6), TEXT_DARK},
    "primary" => {Egui::Color32.rgb(0x00, 0x88, 0xcc), Egui::Color32.rgb(0x00, 0x44, 0xcc), WHITE},
    "info"    => {Egui::Color32.rgb(0x5b, 0xc0, 0xde), Egui::Color32.rgb(0x2f, 0x96, 0xb4), WHITE},
    "success" => {Egui::Color32.rgb(0x62, 0xc4, 0x62), Egui::Color32.rgb(0x51, 0xa3, 0x51), WHITE},
    "warning" => {Egui::Color32.rgb(0xfb, 0xb4, 0x50), Egui::Color32.rgb(0xf8, 0x94, 0x06), WHITE},
    "danger"  => {Egui::Color32.rgb(0xee, 0x5f, 0x5b), Egui::Color32.rgb(0xbd, 0x36, 0x2f), WHITE},
    "inverse" => {Egui::Color32.rgb(0x44, 0x44, 0x44), Egui::Color32.rgb(0x22, 0x22, 0x22), WHITE},
  } of String => {Egui::Color32, Egui::Color32, Egui::Color32}

  ROUNDING = 4.0

  # The .btn paint recipe shared by plain, dropdown and split buttons:
  # outset shadow under, gradient fill, inset sheen (or the pressed
  # inset when active), 1px border over.
  def self.paint_button(painter : Egui::Painter, rect : Egui::Rect,
                        top : Egui::Color32, bottom : Egui::Color32,
                        label : Egui::Color32, hovered : Bool,
                        active : Bool) : Nil
    f = active ? 0.80 : hovered ? 0.92 : 1.0
    top = top.mul_color(f)
    bottom = bottom.mul_color(f)

    painter.box_shadow(rect, OUTER, blur: 2.0, rounding: ROUNDING,
      offset: Egui::Vec2.new(0.0, 1.0))
    painter.rect_gradient(rect, ROUNDING, top, bottom)
    if active
      painter.box_shadow(rect, PRESSED, blur: 5.0, rounding: ROUNDING,
        offset: Egui::Vec2.new(0.0, 3.0), inset: true)
    else
      painter.box_shadow(rect, SHEEN, blur: 0.0, rounding: ROUNDING,
        offset: Egui::Vec2.new(0.0, 1.0), inset: true)
    end
    painter.rect(rect, ROUNDING, nil, BORDER_DARK, 1.0)
  end

  # The .caret: a small solid triangle stacked from 1px rows.
  def self.caret(painter : Egui::Painter, cx : Float64, cy : Float64,
                 color : Egui::Color32) : Nil
    4.times do |i|
      w = 8.0 - 2.0 * i
      painter.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(cx - w / 2.0, cy + i), Egui::Vec2.new(w, 1.0)), 0.0, color)
    end
  end

  # A bootstrap .dropdown-menu: white frame (the popup system's window
  # visuals are themed white), link-blue rows with a solid hover fill,
  # 1px dividers, and the menu's drop shadow painted UNDER the frame
  # from the popup rect the previous frame measured. Returns the chosen
  # item (clicks close the menu; a click outside closes it too).
  def self.dropdown_menu(ctx : Egui::Context, key : String, anchor_rect : Egui::Rect,
                         items : Array(String)) : String?
    chosen = nil
    return chosen unless ctx.popup_open?(key)

    # Shadow first so it lands under the frame the popup paints next.
    if (prev = ctx.memory.popup_rects[Egui::Id.from("popup/#{key}")]?)
      ctx.painter.layer = Egui::Order::Foreground
      ctx.painter.box_shadow(prev, MENU_SHADOW, blur: 10.0, rounding: ROUNDING,
        offset: Egui::Vec2.new(0.0, 5.0))
    end

    # Menu rows are flush — no item spacing inside the popup.
    sp = ctx.style.spacing.item_spacing
    ctx.style.spacing.item_spacing = Egui::Vec2.new(sp.x, 0.0)
    ctx.popup(key, ctx.dropdown_anchor(key, anchor_rect),
      width: 200.0, pad: Egui::Vec2.new(0.0, 5.0)) do |menu|
      items.each do |item|
        if item == "-"
          rect = menu.allocate_at_least(Egui::Vec2.new(menu.available_width, 9.0))
          menu.painter.rect(Egui::Rect.from_min_size(
            Egui::Pos2.new(rect.min.x + 1.0, rect.min.y + 4.0),
            Egui::Vec2.new({rect.width - 2.0, 1.0}.max, 1.0)), 0.0, DIVIDER)
        else
          font = menu.style.font_size
          ts = ctx.fonts.measure(item, font)
          rect = menu.allocate_at_least(
            Egui::Vec2.new(menu.available_width, ts.y + 14.0))
          response = menu.interact(rect, menu.next_widget_id, Egui::Sense.click)
          if response.hovered? || response.active?
            menu.painter.rect(rect, 0.0, HOVER_BLUE)
            color = WHITE
          else
            color = LINK_BLUE
          end
          menu.painter.text(
            Egui::Pos2.new(rect.left + 20.0, rect.center.y), item, font, color)
          chosen = item if response.clicked?
        end
      end
    end
    ctx.style.spacing.item_spacing = sp
    ctx.close_popup(key) if chosen
    chosen
  end

  # The bootstrap light page theme: white surfaces, #333 text, 14px
  # font, and a white 1px-stroked popup frame for the dropdown menus.
  def self.theme : Egui::Theme
    Egui::DefaultTheme.build("bootstrap204", dark: false) do |v|
      v.window_fill = WHITE
      v.window_stroke = Egui::Color32.rgba(0, 0, 0, 51)
      v.title_bar_fill = WHITE
      v.panel_fill = WHITE
      v.text_color = TEXT_DARK
      v.title_color = TEXT_DARK
      v.selection_fill = LINK_BLUE
      v.button_weak = Egui::Color32.rgb(0xe6, 0xe6, 0xe6)
      v.button_hovered = Egui::Color32.rgb(0xd8, 0xd8, 0xd8)
      v.button_active = Egui::Color32.rgb(0xc4, 0xc4, 0xc4)
      v.button_stroke = Egui::Color32.rgb(0xcc, 0xcc, 0xcc)
    end.tap { |t| t.style.font_size = 14.0 }
  end

  # The stylesheet section of the demo: the standard `Button` picks up
  # box-shadows from plain `shadow.*` class keys — no custom painting.
  def self.style_rules(ctx : Egui::Context) : Nil
    sheet = ctx.stylesheet
    sheet.rule("button", Egui::StyleVars{
      "rounding"     => 4.0,
      "shadow.color" => Egui::Color32.rgba(0, 0, 0, 70),
      "shadow.blur"  => 6.0,
      "shadow.y"     => 2.0,
    })
    sheet.rule("button:active", Egui::StyleVars{
      "shadow.inset"  => true,
      "shadow.color"  => Egui::Color32.rgba(0, 0, 0, 64),
      "shadow.blur"   => 5.0,
      "shadow.y"      => 3.0,
    })
  end
end

# A .btn: gradient fill + box-shadows, bootstrap padding (4px 14px).
class BsButton
  def initialize(@label : String,
                 @top : Egui::Color32, @bottom : Egui::Color32,
                 @label_color : Egui::Color32)
  end

  def self.new(ui : Egui::Ui, label : String, variant : String)
    top, bottom, color = Bs::VARIANTS[variant]
    new(label, top, bottom, color)
  end

  def ui(ui : Egui::Ui) : Egui::Response
    font = ui.style.font_size
    ts = ui.ctx.fonts.measure(@label, font)
    rect = ui.allocate_at_least(
      Egui::Vec2.new(ts.x + 28.0, {ts.y + 8.0, 28.0}.max))
    response = ui.interact(rect, ui.next_widget_id,
      Egui::Sense.click | Egui::Sense::Focusable)
    Bs.paint_button(ui.painter, rect, @top, @bottom, @label_color,
      response.hovered?, response.active?)
    pos = Egui::Pos2.new(rect.left + (rect.width - ts.x) / 2.0, rect.center.y)
    ui.painter.text(pos, @label, font, @label_color)
    response
  end
end

# A single-button .dropdown-toggle: the whole button toggles the menu.
class BsDropdown
  @top : Egui::Color32
  @bottom : Egui::Color32
  @label_color : Egui::Color32
  @selected : String? = nil

  def initialize(@label : String, variant : String, @key : String,
                 @items : Array(String))
    top, bottom, color = Bs::VARIANTS[variant]
    @top = top
    @bottom = bottom
    @label_color = color
  end

  getter selected : String?

  def ui(ui : Egui::Ui) : Egui::Response
    font = ui.style.font_size
    label = @selected || @label
    ts = ui.ctx.fonts.measure(label, font)
    rect = ui.allocate_at_least(
      Egui::Vec2.new(ts.x + 28.0 + 18.0, {ts.y + 8.0, 28.0}.max))
    response = ui.interact(rect, ui.next_widget_id,
      Egui::Sense.click | Egui::Sense::Focusable)

    open = ui.ctx.popup_open?(@key)
    Bs.paint_button(ui.painter, rect, @top, @bottom, @label_color,
      response.hovered? || open, response.active? || open)
    ui.painter.text(
      Egui::Pos2.new(rect.left + 14.0, rect.center.y), label, font, @label_color)
    Bs.caret(ui.painter, rect.right - 14.0, rect.center.y - 2.0, @label_color)

    ui.ctx.close_popup(@key) if response.clicked? && open
    ui.ctx.open_popup(@key) if response.clicked? && !open
    if (pick = Bs.dropdown_menu(ui.ctx, @key, rect, @items))
      @selected = pick
    end
    response
  end
end

# A split .btn-group: the action part fires like a plain button, the
# caret part toggles the menu; a 1px divider and per-part hover/active
# tints (a clipped translucent overlay) separate them.
class BsSplitDropdown
  CARET_W = 26.0

  @top : Egui::Color32
  @bottom : Egui::Color32
  @label_color : Egui::Color32
  @selected : String? = nil
  @clicks = 0

  def initialize(@label : String, variant : String, @key : String,
                 @items : Array(String))
    top, bottom, color = Bs::VARIANTS[variant]
    @top = top
    @bottom = bottom
    @label_color = color
  end

  getter selected : String?
  getter clicks : Int32

  def ui(ui : Egui::Ui) : Egui::Response
    font = ui.style.font_size
    label = @selected || @label
    ts = ui.ctx.fonts.measure(label, font)
    rect = ui.allocate_at_least(
      Egui::Vec2.new(ts.x + 28.0 + CARET_W, {ts.y + 8.0, 28.0}.max))
    main = Egui::Rect.from_min_size(rect.min,
      Egui::Vec2.new(rect.width - CARET_W, rect.height))
    caret_r = Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.max.x - CARET_W, rect.min.y),
      Egui::Vec2.new(CARET_W, rect.height))
    r_main = ui.interact(main, ui.next_widget_id, Egui::Sense.click)
    r_caret = ui.interact(caret_r, ui.next_widget_id, Egui::Sense.click)

    open = ui.ctx.popup_open?(@key)
    Bs.paint_button(ui.painter, rect, @top, @bottom, @label_color,
      r_main.hovered? || r_caret.hovered? || open,
      r_main.active? || r_caret.active? || open)
    ui.painter.text(
      Egui::Pos2.new(rect.left + 14.0, rect.center.y), label, font, @label_color)
    Bs.caret(ui.painter, caret_r.center.x, caret_r.center.y - 2.0, @label_color)

    # The v2 split divider: a 1px dark seam plus a soft inset shade on
    # the caret side (inset x pushes the band to the LEFT edge).
    ui.painter.line(
      Egui::Pos2.new(caret_r.min.x + 0.5, rect.min.y + 1.0),
      Egui::Pos2.new(caret_r.min.x + 0.5, rect.max.y - 1.0), 1.0, Bs::BORDER_DARK)
    ui.painter.box_shadow(caret_r, Bs::SHEEN, blur: 0.0, rounding: Bs::ROUNDING,
      offset: Egui::Vec2.new(1.0, 0.0), inset: true)

    # Per-part hover/active tint, clipped to the part's half so the
    # rounded corners stay intact.
    prev_clip = ui.painter.clip
    parts = [{main, r_main}, {caret_r, r_caret}]
    parts.each do |part, r|
      next unless r.hovered? || r.active? || (open && part == caret_r)
      ui.painter.clip = part
      ui.painter.rect(rect, Bs::ROUNDING,
        fill: Egui::Color32.rgba(0, 0, 0, r.active? ? 40 : 18))
    end
    ui.painter.clip = prev_clip

    ui.ctx.close_popup(@key) if r_caret.clicked? && open
    ui.ctx.open_popup(@key) if r_caret.clicked? && !open
    @clicks += 1 if r_main.clicked?
    if (pick = Bs.dropdown_menu(ui.ctx, @key, rect, @items))
      @selected = pick
    end
    r_main
  end
end

class BoxShadowApp < Egui::App
  @themed = false
  @plain_last : String? = nil
  @single : BsDropdown? = nil
  @split : BsSplitDropdown? = nil

  ITEMS = ["Action", "Another action", "Something else here",
           "-", "Separated link"]

  def update(ctx : Egui::Context) : Nil
    unless @themed
      ctx.theme = Bs.theme
      Bs.style_rules(ctx)
      @themed = true
    end

    ctx.central_panel do |ui|
      ui.heading("Buttons")
      ui.label("Bootstrap 2.0.4 — gradient fills, inset sheen, pressed inset shadow")
      ui.horizontal do |row|
        if (r = BsButton.new(row, "Button", "default").ui(row)).clicked?
          @plain_last = "default"
        end
        {"primary", "info", "success", "warning", "danger", "inverse"}.each do |name|
          if (r = BsButton.new(row, name.capitalize, name).ui(row)).clicked?
            @plain_last = name
          end
        end
      end
      ui.label("last clicked: #{@plain_last || "—"}")

      ui.separator
      ui.heading("Button dropdowns")
      ui.horizontal do |row|
        single = (@single ||= BsDropdown.new("Action", "danger", "bs_single", ITEMS))
        single.ui(row)
        split = (@split ||= BsSplitDropdown.new("Action", "primary", "bs_split", ITEMS))
        split.ui(row)
        ui.label("   ") # breathing room between the two controls
      end
      s = @single
      p = @split
      ui.label("single: #{s.try(&.selected) || "—"}   " \
               "split action: #{p.try(&.selected) || "—"} " \
               "(#{p.try(&.clicks) || 0} action clicks)")

      ui.separator
      ui.heading("Stylesheet shadows (standard Button)")
      ui.label("ui.button reads shadow.* class keys — button:active flips to inset")
      ui.horizontal do |row|
        row.button("One").clicked?
        row.button("Two").clicked?
        row.button("Three").clicked?
      end
    end
  end
end

Egui::Backend::Sokol.run(BoxShadowApp.new,
  title: "egui.cr — box-shadow (bootstrap 2.0.4)", inspector: :hidden)
