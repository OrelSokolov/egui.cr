# Port of egui_upstream/crates/egui/src/style.rs — trimmed to what
# slice-1 widgets read: spacing, font size, dark-theme widget colors.

module Egui
  class Spacing
    property item_spacing : Vec2
    property button_padding : Vec2
    property window_padding : Vec2
    property indent : Float64

    def initialize
      @item_spacing = Vec2.new(8.0, 6.0)
      @button_padding = Vec2.new(8.0, 4.0)
      @window_padding = Vec2.new(10.0, 8.0)
      @indent = 16.0
    end
  end

  class Visuals
    property window_fill : Color32
    property window_stroke : Color32
    property panel_fill : Color32
    property text_color : Color32
    property title_color : Color32

    # Button states (egui `WidgetVisuals`): weak / hovered / active.
    property button_weak : Color32
    property button_hovered : Color32
    property button_active : Color32
    property button_stroke : Color32

    def initialize
      @window_fill = Color32.rgba(27, 27, 30, 235)
      @window_stroke = Color32.rgba(80, 80, 80, 255)
      @panel_fill = Color32.rgba(22, 22, 24, 255)
      @text_color = Color32.rgba(235, 235, 235, 255)
      @title_color = Color32.rgba(250, 250, 250, 255)

      @button_weak = Color32.rgba(60, 60, 60, 180)
      @button_hovered = Color32.rgba(85, 85, 85, 200)
      @button_active = Color32.rgba(110, 110, 110, 220)
      @button_stroke = Color32.rgba(96, 96, 96, 255)
    end

    # egui `Visuals::widget_visuals(interaction)` — pick by state.
    def button_fill(hovered : Bool, active : Bool) : Color32
      return @button_active if active
      return @button_hovered if hovered
      @button_weak
    end
  end

  class Style
    property spacing : Spacing
    property visuals : Visuals
    property font_size : Float64

    def initialize
      @spacing = Spacing.new
      @visuals = Visuals.new
      @font_size = 16.0
    end
  end
end
