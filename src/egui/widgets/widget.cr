# Port of the egui `Widget` trait (egui_upstream/crates/egui/src/ui.rs:
# `pub trait Widget { fn ui(self, ui: &mut Ui) -> Response; }`).
#
# In Crystal this is a module with an abstract method; `Ui#add`
# (`ui.add(widget)` upstream) dispatches through it.
#
# The module also carries the per-widget style-override plumbing:
# `#style` collects a `WidgetStyle` (nilable fields — nil = inherit from
# the app theme), and `#effective_style` merges it over the theme's
# Style at build time. Widgets opt in by resolving their style through
# `effective_style(ui)` at the top of `#ui`.

module Egui
  module Widget
    abstract def ui(ui : Ui) : Response

    @style_override : WidgetStyle?

    # Customize this widget's style; nil fields keep the theme value:
    #
    #   Button.new("OK").style { |s| s.fill = Color32.rgb(180, 40, 40) }
    def style(& : WidgetStyle ->) : self
      ws = (@style_override ||= WidgetStyle.new)
      yield ws
      self
    end

    # The theme's Style merged with this widget's `#style` overrides
    # (a copy — the theme is never mutated; widgets without overrides
    # share the theme object itself, no per-widget copying).
    protected def effective_style(ui : Ui) : Style
      if ws = @style_override
        ws.merge_over(ui.style)
      else
        ui.style
      end
    end
  end
end
