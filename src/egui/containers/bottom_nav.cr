# Mobile bottom navigation bar (Material 3 `NavigationBar` / iOS tab
# bar) — plans/todo/mobile_widgets.md #4.
#
# The screen-scaffold contract: the bar occupies the BOTTOM slot of the
# screen (the app places it as the last row of a vertical layout; the
# body keeps the rest — the same split as sidebar/page). 3–5 items,
# each an icon over a label; the selected item gets the accent tint.
# Items are equally divided across the full width (a tap target of
# bar_width / items — the Material rule; big targets matter on touch).
#
# Selection follows the Checkbox/Tabs pattern — the app owns it, passes
# the current index in and reads the new one back through the
# `Ui#bottom_nav` block when it changed this frame (or through
# `Response#changed?` + the `selected` getter). Tapping the already
# selected item is a no-op (same contract as Tabs).
#
# Badges (plan #9) and the safe-area inset (plan #24) are NOT wired in
# v1: the bar sits flush at the bottom, the `margin`/`height` style
# keys are the manual knobs until the insets port lands.
#
# Styling goes through the global `StyleSheet` (CSS-like classes):
#   bottom_nav       — height (80), background, item_color (inactive
#                      icon+label tint), active_color (selected tint),
#                      icon_size (24), font_size, font_family +
#                      width/height/min_/max_ length keys via
#                      #styled_size
#   bottom_nav.item  — text_color (per-item override; :hover and
#                      :selected overlays), background (:selected pill
#                      behind the item when a rule sets it)
# The theme presets do NOT ship defaults for the class yet (the mobile
# theme catalog is a post-phase-2 decision) — the Visuals fallbacks
# above apply until a rule sets a key.

module Egui
  class BottomNav
    include Widget

    ROOT_CLASS = "bottom_nav"

    # Material guidance: 3 destinations minimum (two read as a toggle),
    # 5 maximum (readability of the labels).
    MIN_ITEMS = 3
    MAX_ITEMS = 5

    class Item
      getter icon : Symbol
      getter label : String

      def initialize(@icon : Symbol, @label : String)
        unless Icons::NAMES.includes?(@icon)
          raise ArgumentError.new("BottomNav::Item: unknown icon " \
                                  "#{@icon.inspect} — Icons::NAMES has " \
                                  "#{Icons::NAMES.inspect}")
        end
      end
    end

    # The StyledPart behind one item cell (see widgets/styled_part.cr):
    # inspector meta for the cell's interact + the `bottom_nav.item`
    # keys. The bare "item" name chains onto the live "bottom_nav"
    # scope; :hover/:selected overlays resolve per item id.
    class ItemPart < StyledPart
      def initialize(label : String)
        super("BottomNavItem", "item", [
          StyleProp.new("text_color", :color, states: true),
          StyleProp.new("background", :color, states: true),
        ], label)
      end
    end

    getter selected : Int32
    getter items : Array(Item)
    # The per-item ids of the LAST frame — exposed so apps can address
    # a cell (per-element inspector overrides) and so specs can assert
    # id stability across frames.
    getter item_ids : Array(Id)

    def initialize(items : Array(Item), selected : Int32 = 0,
                   id : String? = nil)
      unless items.size >= MIN_ITEMS && items.size <= MAX_ITEMS
        raise ArgumentError.new("BottomNav holds #{MIN_ITEMS}–#{MAX_ITEMS} " \
                                "items, got #{items.size}")
      end
      @items = items
      @id_name = id
      @selected = selected.clamp(0, items.size - 1)
      @item_ids = [] of Id
    end

    def style_class : String?
      ROOT_CLASS
    end

    # The root keys #ui reads. The per-item keys live on ItemPart.
    def style_properties : Array(StyleProp)
      [StyleProp.new("height", :number, min: 0.0),
       StyleProp.new("background", :color),
       StyleProp.new("item_color", :color),
       StyleProp.new("active_color", :color),
       StyleProp.new("icon_size", :number, min: 0.0),
       StyleProp.new("font_size", :number, min: 0.0),
       StyleProp.new("font_family", :string)]
    end

    def inspector_label : String?
      @items[@selected].label
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      visuals = style.visuals
      vars = style_vars(ui, id)

      # The bar occupies the BOTTOM SLOT of its region: pinned to
      # max_rect.bottom, full width — NOT to the flow cursor. A
      # mobile screen is "app bar / body / bottom nav" with the body
      # any height; a flow-placed bar rides the content and jumps
      # between tabs. The app reserves the slot up front
      # (`ui.allocate_space` before the body); the bar itself always
      # sits flush at the region's bottom edge.
      bar_h = vars.f64("height", 80.0)
      region = ui.max_rect
      size = styled_size(Vec2.new(region.width, bar_h), vars, ui, id)
      rect = Rect.from_min_size(
        Pos2.new(region.left, region.bottom - size.y),
        Vec2.new(size.x, size.y))
      ui.allocate_space(Vec2.new(region.width, size.y))
      ui.painter.rect(rect, fill: vars.color("background", visuals.panel_fill))

      # Style scope: the item cells chain onto "bottom_nav.item" (the
      # bare "item" name resolves against the live scope — same wiring
      # as tabs/sidebar). The bar itself never interacts — only the
      # cells are tap targets (a root interact here would claim the
      # press before the cells and eat every tap).
      clicked = ui.with_style_scope(ROOT_CLASS) { render(ui, rect, vars) }
      clicked || Response.container(ui.ctx, id, rect)
    end

    # The item cells: laid out inside the style scope (see #ui), each
    # over its equal share of the bar width. Returns the clicked item's
    # response this frame (nil = nothing clicked).
    private def render(ui : Ui, rect : Rect, vars : StyleVars) : Response?
      ctx = ui.ctx
      style = ui.style
      visuals = style.visuals

      item_color = vars.color("item_color", visuals.fade_color(visuals.text_color))
      active_color = vars.color("active_color", visuals.selection_fill)
      icon_size = vars.f64("icon_size", 24.0)
      font_size = vars.f64("font_size", style.font_size * 0.75)
      family = vars.str?("font_family")
      fonts = ctx.fonts_for(family)
      gap = 4.0

      clicked : Response? = nil
      @item_ids.clear
      item_w = rect.width / @items.size

      @items.each_with_index do |item, i|
        iid = ui.next_widget_id
        @item_ids << iid
        part = ItemPart.new(item.label)
        cell = Rect.from_min_size(
          Pos2.new(rect.min.x + i * item_w, rect.min.y),
          Vec2.new(item_w, rect.height))
        resp = ui.ctx.with_inspector_widget(part) {
          ui.interact(cell, iid, Sense.click) }
        selected = i == @selected

        # State overlay on top of the base vars: the selected item's
        # accent tint, hover the faded text color (resolvable per id —
        # class rules AND per-element inspector edits both land here).
        state = selected ? "selected" : (resp.hovered? ? "hover" : nil)
        sv = part.vars(ui, iid, state)
        if (pill_fill = sv.color?("background"))
          pill = Rect.from_min_size(
            Pos2.new(cell.min.x + 16.0, cell.min.y + 8.0),
            Vec2.new(cell.width - 32.0, cell.height - 16.0))
          ui.painter.rect(pill, 12.0, pill_fill)
        end
        tint = sv.color?("text_color") ||
               (selected ? active_color : item_color)

        # Icon over label, the block centered in the cell.
        label_size = fonts.measure(item.label, font_size)
        block_h = icon_size + gap + label_size.y
        top = rect.center.y - block_h / 2.0
        icon_rect = Rect.from_min_size(
          Pos2.new(cell.center.x - icon_size / 2.0, top),
          Vec2.new(icon_size, icon_size))
        Icons.draw(ui.painter, item.icon, icon_rect, tint)
        ui.painter.text(
          Pos2.new(cell.center.x - label_size.x / 2.0,
            top + icon_size + gap + label_size.y / 2.0),
          item.label, font_size, tint, family: family)

        if resp.clicked? && !selected
          @selected = i
          resp.mark_changed
          ui.ctx.request_repaint
          clicked = resp
        end
      end
      clicked
    end
  end

  class Ui
    # `ui.bottom_nav(items, selected) { |i| tab = i }` — shows the bar
    # and hands back the new index when it changed this frame.
    def bottom_nav(items : Array(BottomNav::Item), selected : Int32,
                   id : String? = nil, &on_select : Int32 ->) : Response
      widget = BottomNav.new(items, selected, id: id)
      response = add(widget)
      on_select.call(widget.selected) if response.changed?
      response
    end

    def bottom_nav(items : Array(BottomNav::Item), selected : Int32,
                   id : String? = nil) : Response
      add(BottomNav.new(items, selected, id: id))
    end
  end
end
