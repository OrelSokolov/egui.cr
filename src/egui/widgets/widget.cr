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

    # CSS-like class this widget styles under in the global
    # `StyleSheet` (nil = not registered yet). Widgets adopt the class
    # system gradually; see `Button` and `containers/sidebar.cr` for
    # the reference wiring (base + state overlays).
    def style_class : String?
      nil
    end

    # Customize this widget's style; nil fields keep the theme value:
    #
    #   Button.new("OK").style { |s| s.fill = Color32.rgb(180, 40, 40) }
    def style(& : WidgetStyle ->) : self
      ws = (@style_override ||= WidgetStyle.new)
      yield ws
      self
    end

    # The effective Style with the full cascade applied:
    # theme → class rules (`class_vars`) → class state overlay
    # (`state`, resolved through #style_class) → this widget's `#style`
    # overrides (a copy — the theme is never mutated; widgets without
    # any layer share the theme object itself, no per-widget copying).
    protected def effective_style(ui : Ui, class_vars : StyleVars? = nil,
                                  state : String? = nil) : Style
      base = ui.style
      if class_vars && !class_vars.empty?
        base = class_vars.apply_over(base)
      end
      if state && (path = style_class) &&
         (overlay = ui.ctx.stylesheet.state_vars(path, state)) &&
         !overlay.empty?
        base = overlay.apply_over(base, state)
      end
      if (ws = @style_override)
        ws.merge_over(base)
      else
        base
      end
    end
  end
end
