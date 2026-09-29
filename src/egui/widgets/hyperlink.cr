# Port of egui_upstream/crates/egui/src/widgets/hyperlink.rs (lite).
#
# A colored, underlined, clickable label — HTML `<a>` semantics:
# the default is underlined and hyperlink-colored, `#underline(false)`
# is the CSS `text-decoration: none`, and the color reacts to hover /
# active through the `link` class rules (`link:hover`, `link:active`)
# exactly the way a `Button` fill does. Opening the URL shells out to
# xdg-open on Linux.

module Egui
  class Hyperlink
    include Widget

    def initialize(@label : String, @url : String, id : String? = nil)
      @id_name = id
    end

    # CSS `text-decoration` for this link: nil (the default) follows
    # the `link` class rules (`underline: true` — the HTML default);
    # an explicit bool wins over the stylesheet, like an inline style.
    def underline(flag : Bool) : self
      @underline = flag
      self
    end

    @underline : Bool?

    def style_class : String?
      "link"
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("text_color", :color, states: true),
       StyleProp.new("font_size", :number),
       StyleProp.new("hyperlink_color", :color),
       StyleProp.new("underline", :bool, states: true, fallback: true)]
    end

    def inspector_label : String?
      @label
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      class_vars = style_vars(ui, id, "link")
      style = effective_style(ui, id, class_vars)
      font_size = style.font_size
      text_size = ui.ctx.fonts.measure(@label, font_size)

      rect = ui.allocate_at_least(text_size)
      # Upstream: Link is Sense::click only — NOT focusable. There is no
      # keyboard activation in this framework (no Enter/Space on focused
      # widgets), so focus on a link would be an unactionable decoration.
      response = ui.interact(rect, id, Sense.click)
      # Upstream: a pointing hand over links, independent of the
      # interact_cursor style.
      ui.ctx.set_cursor_icon(CursorIcon::Pointer) if response.hovered?

      # CSS-like state resolution, same as Button: the live interaction
      # state picks the `link:hover` / `link:active` overlays, so both
      # the text color and the underline ride the state bag (a
      # `link:hover { underline }` rule applies while hovered).
      state = response.active? ? "active" : response.hovered? ? "hover" : nil
      state_vars = style_vars(ui, id, "link", state)
      color = state_vars.color?("text_color") ||
              style.visuals.hyperlink_color
      # The explicit `#underline` attribute beats the stylesheet — a
      # plain `||` would drop an explicit `false`.
      underline = @underline.nil? ? state_vars.bool("underline", true) : @underline

      rich = RichText.new(@label).color(color)
      rich = rich.underline if underline
      galley = ui.ctx.fonts.layout(rich.runs(font_size, color))
      ui.painter.paint_galley(rect.min, galley, ui.ctx.fonts, color)

      Hyperlink.open_url(@url) if response.clicked?
      response
    end

    def self.open_url(url : String) : Nil
      Process.new("xdg-open", [url],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
    rescue File::Error | IO::Error
      # xdg-open missing or exec failed — nothing sensible to do headless.
    end
  end
end
