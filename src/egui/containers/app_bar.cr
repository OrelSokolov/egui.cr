# Mobile top app bar (Material 3 top app bar / iOS navigation bar) —
# plans/todo/mobile_widgets.md #5.
#
# The screen-scaffold contract: the bar occupies the TOP slot of the
# screen — optional back chevron, a title, and up to 3 action icon
# buttons flush right. One row, height from style (56 — the Material
# standard); the body keeps the rest of the screen. The collapsing
# (scroll-shrink) variant from the plan is deliberately NOT in v1 —
# it needs the scroll-offset contract of the body container; if that
# lands later it should be a separate entry, not this file.
#
# Interactions follow the nested-click trick the Tabs close button
# uses: the back button and each action interact AFTER the bar's own
# (Sense.none) interact, so hit-testing routes the tap to the inner
# control. Callbacks fire once per click: `on_back` through the
# `#on_back` builder (or the `Ui#app_bar` parameter), per-action
# through `#action(icon) { … }`. `Response#changed?` is true on any
# click — `back_clicked?` / `clicked_action` say which.
#
# Styling goes through the global `StyleSheet` (CSS-like classes):
#   app_bar            — height (56), background, text_color (title),
#                        icon_color (back + actions), icon_size (24),
#                        font_size, font_family + width/height/min_/
#                        max_ length keys via #styled_size
#   app_bar.back       — icon_color (+ :hover overlay) of the chevron
#   app_bar.action     — icon_color (+ :hover overlay) of an action
# The theme presets do NOT ship defaults for the class yet (the mobile
# theme catalog is a post-phase-2 decision) — the Visuals fallbacks
# above apply until a rule sets a key.

module Egui
  class AppBar
    include Widget

    ROOT_CLASS = "app_bar"
    DEFAULT_HEIGHT = 56.0
    # Material: at most 3 actions — beyond that the content belongs in
    # an overflow menu (not in v1; the constructor refuses a 4th).
    MAX_ACTIONS = 3
    # A 24pt glyph needs a ~40pt square to be a finger-sized target.
    TAP_SQUARE = 40.0

    # One action icon button: icon from `Icons::NAMES` + the callback
    # to fire when it is clicked this frame.
    class Action
      getter icon : Symbol

      def initialize(@icon : Symbol, &@on_click : ->)
      end

      def fire : Nil
        @on_click.call
      end
    end

    # The StyledPart behind the back chevron / an action button (see
    # widgets/styled_part.cr): inspector meta + the per-part keys. The
    # bare names chain onto the live "app_bar" scope; :hover overlays
    # resolve per part id.
    class IconPart < StyledPart
      def initialize(part_name : String, label : String?)
        super("AppBar#{part_name.capitalize}", part_name, [
          StyleProp.new("icon_color", :color, states: true),
        ], label)
      end
    end

    getter actions : Array(Action)
    getter? back_clicked : Bool
    # The index of the action clicked THIS frame (nil = none).
    getter clicked_action : Int32?

    @on_back : (->)?

    def initialize(@title : String, @back : Bool = false,
                   id : String? = nil)
      @id_name = id
      @back_clicked = false
      @clicked_action = nil
      @actions = [] of Action
    end

    # Add an action icon button (up to #{MAX_ACTIONS}); the block fires
    # on click. Chainable — `bar.action(:plus) { … }.action(:search) { … }`.
    def action(icon : Symbol, &on_click : ->) : self
      unless Icons::NAMES.includes?(icon)
        raise ArgumentError.new("AppBar#action: unknown icon " \
                                "#{icon.inspect} — Icons::NAMES has " \
                                "#{Icons::NAMES.inspect}")
      end
      if @actions.size >= MAX_ACTIONS
        raise ArgumentError.new("AppBar supports at most #{MAX_ACTIONS} " \
                                "actions (overflow menu is not in v1)")
      end
      @actions << Action.new(icon, &on_click)
      self
    end

    # The callback fired when the back chevron is clicked.
    def on_back(&on_click : ->) : self
      @on_back = on_click
      self
    end

    def style_class : String?
      ROOT_CLASS
    end

    # The root keys #ui reads. The per-button keys live on IconPart.
    def style_properties : Array(StyleProp)
      [StyleProp.new("height", :number, min: 0.0),
       StyleProp.new("background", :color),
       StyleProp.new("text_color", :color),
       StyleProp.new("icon_color", :color),
       StyleProp.new("icon_size", :number, min: 0.0),
       StyleProp.new("font_size", :number, min: 0.0),
       StyleProp.new("font_family", :string)]
    end

    def inspector_label : String?
      @title
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      vars = style_vars(ui, id)

      bar_h = vars.f64("height", DEFAULT_HEIGHT)
      size = styled_size(Vec2.new(ui.available_width, bar_h), vars, ui, id)
      rect = ui.allocate_at_least(size)
      ui.with_style_scope(ROOT_CLASS) { render(ui, rect, vars, id) }
    end

    # The bar body: background, optional back chevron, title, action
    # buttons. Runs inside the "app_bar" style scope (see #ui) so the
    # bare "back"/"action" part names chain onto it.
    private def render(ui : Ui, rect : Rect, vars : StyleVars,
                       id : Id) : Response
      style = ui.style
      visuals = style.visuals

      @back_clicked = false
      @clicked_action = nil
      response : Response? = nil

      # The bar background paints under everything; the bar's own
      # interact is Sense.none — only the buttons are tap targets.
      ui.painter.rect(rect, fill: vars.color("background", visuals.panel_fill))
      ui.interact(rect, id, Sense.none)

      icon_size = vars.f64("icon_size", 24.0)
      font_size = vars.f64("font_size", style.font_size)
      family = vars.str?("font_family")
      fonts = ui.ctx.fonts_for(family)
      icon_color = vars.color("icon_color", visuals.text_color)

      # Back chevron: a square tap target at the left edge.
      x = rect.min.x
      if @back
        back_id = ui.next_widget_id
        back_rect = Rect.from_min_size(
          Pos2.new(x, rect.center.y - TAP_SQUARE / 2.0),
          Vec2.new(TAP_SQUARE, TAP_SQUARE))
        part = IconPart.new("back", "back")
        resp = ui.ctx.with_inspector_widget(part) {
          ui.interact(back_rect, back_id, Sense.click) }
        c = part.vars(ui, back_id, resp.hovered? ? "hover" : nil)
          .color("icon_color", icon_color)
        glyph = Rect.from_min_size(
          Pos2.new(back_rect.center.x - icon_size / 2.0,
            back_rect.center.y - icon_size / 2.0),
          Vec2.new(icon_size, icon_size))
        Icons.draw(ui.painter, :left, glyph, c)
        x = back_rect.max.x
        if resp.clicked?
          @back_clicked = true
          resp.mark_changed
          ui.ctx.request_repaint
          @on_back.try(&.call)
          response = resp
        end
      end

      # Title: left-aligned after the back slot, vertically centered.
      title_size = fonts.measure(@title, font_size)
      ui.painter.text(
        Pos2.new(x + 16.0, rect.center.y - title_size.y / 2.0),
        @title, font_size,
        vars.color("text_color", visuals.text_color), family: family)

      # Action buttons: flush right, laid out in declaration order
      # (action 0 leftmost of the group — the reading order).
      ax = rect.max.x
      @actions.size.times do |ri|
        i = @actions.size - 1 - ri
        action = @actions[i]
        aid = ui.next_widget_id
        ax -= TAP_SQUARE
        a_rect = Rect.from_min_size(
          Pos2.new(ax, rect.center.y - TAP_SQUARE / 2.0),
          Vec2.new(TAP_SQUARE, TAP_SQUARE))
        part = IconPart.new("action", "action #{i + 1}")
        resp = ui.ctx.with_inspector_widget(part) {
          ui.interact(a_rect, aid, Sense.click) }
        c = part.vars(ui, aid, resp.hovered? ? "hover" : nil)
          .color("icon_color", icon_color)
        glyph = Rect.from_min_size(
          Pos2.new(a_rect.center.x - icon_size / 2.0,
            a_rect.center.y - icon_size / 2.0),
          Vec2.new(icon_size, icon_size))
        Icons.draw(ui.painter, action.icon, glyph, c)
        ax -= 4.0
        if resp.clicked?
          @clicked_action = i
          resp.mark_changed
          ui.ctx.request_repaint
          action.fire
          response = resp
        end
      end

      response || Response.new(ui.ctx, id, rect, Sense.none, false, false,
        0, false, false, false, false, false, Vec2.zero)
    end
  end

  class Ui
    # `ui.app_bar("Title", back: true, on_back: ->{ … }) { |bar|
    #    bar.action(:plus) { … } }` — shows the bar; the optional
    # block registers the actions before the bar is added. Any click
    # (back or action) reports through `Response#changed?`; the
    # callbacks fire on their own.
    def app_bar(title : String, back : Bool = false, id : String? = nil,
                on_back : (->)? = nil,
                &setup : AppBar ->) : Response
      app_bar_add(AppBar.new(title, back, id: id), on_back, setup)
    end

    def app_bar(title : String, back : Bool = false, id : String? = nil,
                on_back : (->)? = nil) : Response
      app_bar_add(AppBar.new(title, back, id: id), on_back, nil)
    end

    private def app_bar_add(bar : AppBar, on_back : (->)?,
                            setup : (AppBar ->)?) : Response
      bar.on_back(&on_back) if on_back
      setup.try(&.call(bar))
      add(bar)
    end
  end
end
