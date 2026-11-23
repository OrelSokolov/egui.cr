# Mobile Chip (Material 3 assist/filter/input chip, phase 3 of
# plans/todo/mobile_widgets.md): a capsule with an optional leading
# icon, a label and an optional trailing close X.
#
# Capsule geometry comes free from Painter#rect's border-radius clamp
# (radius = half the short side — the `capsule_spec.cr` primitive), so
# the paint is one rounded rect whose rounding tracks the height.
#
# State follows the Checkbox contract: the app owns `selected` and
# passes it in every frame. When `selected` is non-nil (filter chip) a
# click TOGGLES it in place (chips are app-held objects, so the flip
# survives) and `Response#changed?` reports it; nil (assist/input
# chip) means a plain action chip — a click just reports `changed?`.
#
# The close X is a nested interact registered AFTER the chip's own —
# hit-testing picks the latest widget under the pointer, so a click on
# the X routes to the X and never to the chip (the same trick the Tabs
# strip uses for its per-tab close button). `closed` / the
# `ui.chip_row` `on_close` block carry the verdict to the app.
#
# Styling — the `chip` class:
#   height          (number, default 32 — the capsule's diameter)
#   padding         (box, default 12 left/right — pill insets)
#   icon_size       (number, default 16)
#   font_size       (number, default the Ui font size)
#   text_color      (color)
#   background      (color, states: true — base + :hover overlay)
#   stroke          (color, unset = no outline)
#   selected_fill   (color, default visuals.selection_fill — the
#                    selected filter chip's capsule fill; its text goes
#                    white unless `text_color` says otherwise)
#   close_color     (color, default the faded text color)

module Egui
  class Chip
    include Widget

    CLOSE_SEED = 0xC10C_u64

    # Filter-chip state: nil = a plain action chip (click = action,
    # no toggle). Non-nil: the app's current filter state, flipped in
    # place on click.
    property selected : Bool?

    def initialize(@label : String, @icon : Symbol? = nil,
                   selected : Bool? = nil, @closable : Bool = false,
                   id : String? = nil)
      @selected = selected
      @id_name = id
      # Set for the frame whose ui() ran: the close X was clicked.
      @closed = false
    end

    def style_class : String?
      "chip"
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + [
        StyleProp.new("height", :number, fallback: 32.0, min: 0.0),
        StyleProp.new("padding", :box),
        StyleProp.new("icon_size", :number, fallback: 16.0, min: 0.0),
        StyleProp.new("background", :color, states: true),
        StyleProp.new("stroke", :color),
        StyleProp.new("selected_fill", :color),
        StyleProp.new("close_color", :color),
      ]
    end

    def inspector_label : String?
      @label
    end

    # The close X was clicked this frame (chip_row's on_close reads
    # it; `ui.chip` callers read Response#changed? instead).
    getter? closed : Bool

    # The close X's rect from the last ui() run — test/debug access to
    # the nested hit target.
    getter close_rect : Rect?

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      vars = style_vars(ui, id)
      style = effective_style(ui, id, vars)
      visuals = style.visuals
      font_size = vars.f64?("font_size") || style.font_size
      fonts = ui.ctx.fonts_for(style.font_family)

      height = vars.f64("height", 32.0)
      pad = vars.box?("padding") || StyleBox.new(0.0, 12.0, 0.0, 12.0)
      icon_size = vars.f64("icon_size", 16.0)
      gap = icon_size * 0.4

      text_w = fonts.measure(@label, font_size).x
      w = pad.horizontal + text_w
      w += icon_size + gap if @icon
      w += gap + icon_size * 0.75 if @closable
      rect = ui.allocate_at_least(Vec2.new(w, height))
      response = ui.interact(rect, id, Sense.click)

      selected = @selected == true
      # State overlay: the selected filter chip reads `:selected`
      # class rules, a hovered plain chip `:hover`.
      state = selected ? "selected" : (response.hovered? ? "hover" : nil)
      state_vars = state ? style_vars(ui, id, state) : vars

      fill = if selected
        vars.color("selected_fill", visuals.selection_fill)
      else
        state_vars.color?("background")
      end
      stroke = state_vars.color?("stroke")
      ui.painter.capsule(rect, fill, stroke)

      # Content: [icon] label [X], centered as a group, text first so
      # the padding box hugs it.
      x = rect.left + pad.left
      if @icon
        icon_rect = Rect.from_min_size(Pos2.new(x, rect.center.y - icon_size / 2.0),
          Vec2.new(icon_size, icon_size))
        Icons.draw(ui.painter, @icon.not_nil!, icon_rect,
          state_vars.color("text_color", visuals.text_color))
        x += icon_size + gap
      end
      text_color = selected ? Color32.rgb(255, 255, 255) :
        state_vars.color("text_color", visuals.text_color)
      ui.painter.text(Pos2.new(x, rect.center.y), @label, font_size,
        text_color, family: style.font_family)

      @closed = false
      @close_rect = nil
      if @closable
        xw = icon_size * 0.75
        x_rect = Rect.from_min_size(
          Pos2.new(rect.right - pad.right - xw, rect.center.y - xw / 2.0),
          Vec2.new(xw, xw))
        @close_rect = x_rect
        # Nested interact AFTER the chip: hit-testing hands the click
        # to the X (see the class comment).
        x_id = id.child(CLOSE_SEED)
        x_resp = ui.interact(x_rect, x_id, Sense.click)
        if x_resp.clicked?
          @closed = true
          response = x_resp
          response.mark_changed
          ui.ctx.request_repaint
        end
      end

      # Click toggles the filter state (only when the app manages one
      # — nil chips are action chips); the verdict rides Response.
      if response.clicked? && response.id == id && !@selected.nil?
        @selected = !@selected.not_nil!
        response.mark_changed
        ui.ctx.request_repaint
      end
      response
    end
  end
end

# Ui sugar for the mobile widget set (see widgets/switch.cr — the
# class is reopened per phase file, `ui.cr` stays untouched).
class Egui::Ui
  # `ui.chip(chip)` — a single chip; `Response#changed?` reports a
  # click (filter chips flip `chip.selected` themselves).
  def chip(chip : Chip) : Response
    add(chip)
  end

  # `ui.chip_row(chips) { |i| … }` — a wrapped row of chips (the
  # horizontal row's line-break wrap carries the layout; see
  # spec/row_wrap_spec.cr). `on_close` fires with the chip's index
  # when its close X was clicked this frame; the app drops the chip.
  # Returns one Response per chip (same order as `chips`).
  def chip_row(chips : Array(Chip), &on_close : Int32 ->) : Array(Response)
    responses = [] of Response
    horizontal do |row|
      chips.each_with_index do |chip, i|
        r = row.add(chip)
        on_close.call(i) if chip.closed?
        responses << r
      end
    end
    responses
  end

  def chip_row(chips : Array(Chip)) : Array(Response)
    chip_row(chips) { |_| }
  end
end
