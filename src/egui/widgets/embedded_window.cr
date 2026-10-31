# A window INSIDE the window — the Firefox-style About dialog. Where
# Egui::AboutModal is a static modal card, this floats as a real app
# dialog window over the app (chrome via Context#embedded_window,
# the Win11 miniature frame): centered, close ✕, Escape/scrim
# dismiss; dragging comes along for free but is not required.
#
# Layout:
#
#   ┌─────────────────────────────────────────┐
#   │ About my app                     [✕]    │
#   │ A: ┌────────┐  App name                  │
#   │    │        │  version                   │
#   │    │  BIG   │  [Check for updates]       │
#   │    │  icon  │  update status (small)     │
#   │    │ ≥400pt │  multiline description     │
#   │    └────────┘                            │
#   │─────────────────────────────────────────│
#   │ B: C: Licensing · End User Rights · …   │
#   │    D: small text (centered)             │
#   └─────────────────────────────────────────┘
#
# The icon (block A) is an SVG SOURCE string stretched to the content
# height, at least 200pt tall (narrow screens cap its width share) —
# a real logo block, not a 64px favicon.
#
#   win = Egui::EmbeddedWindow.new("About my app", version: "1.0",
#     description: "…", icon: File.read("logo.svg"),
#     links: {"Licensing" => url, …}, footer: "©",
#     update_label: "Check for updates")
#   win.on_update = ->{ win.update_status = "Up to date"; nil }
#   @open = false if @open && win.show(ctx)   # while @open

module Egui
  # The StyledPart behind the `Context#embedded_window` shell (see
  # widgets/styled_part.cr): the chrome is paint-in-place (painter
  # calls straight from the context, not through `Ui#add`), so without
  # a part the inspector records no meta for its interacts — the frame
  # was unpickable and its colors/geometry (the Win11 constants) were
  # unreachable from the cascade. The part gives the shell the
  # "embedded_window" class and declares the keys #embedded_window
  # reads; every hard-coded Win11 value stays as the per-key fallback,
  # so an unstyled frame paints exactly as before.
  class EmbeddedWindowPart < StyledPart
    def initialize(label : String?)
      super("Window", "embedded_window", [
        StyleProp.new("background", :color, label: "fill"),
        StyleProp.new("stroke", :color, label: "border"),
        StyleProp.new("rounding", :number, min: 0.0, fallback: 8.0),
        StyleProp.new("caption_fill", :color),
        StyleProp.new("title_color", :color),
        StyleProp.new("title_font_size", :number, min: 0.0),
        StyleProp.new("caption_height", :number, min: 0.0),
        StyleProp.new("close_background", :color, states: true),
      ], label)
    end
  end

  class EmbeddedWindow
    # The icon's MINIMUM height: stretched to the content height, but
    # never smaller than this (the big-logo look).
    ICON_MIN = 200.0
    # On narrow screens (mobile) the icon column caps at this share of
    # the window width — 400pt of icon would leave no room for text.
    ICON_WIDTH_SHARE = 0.55
    # Air between the icon and the app column.
    ICON_GAP = 16.0

    def initialize(@title : String, @version : String? = nil,
                   @description : String = "", @icon : String? = nil,
                   @links : Array({String, String}) = [] of {String, String},
                   @footer : String = "", @update_label : String? = nil,
                   @width : Float64 = 640.0, @id : String = "about_window")
    end

    # Fires when the update button is clicked (nil = no button).
    property on_update : (-> Nil)?
    # Live status line under the update button ("" = hidden) — the
    # on_update handler sets it ("Up to date…").
    property update_status : String = ""

    # Draw the window (call every frame while open). True the frame
    # the user closed it — the ✕, the scrim or Escape.
    def show(ctx : Context) : Bool
      ctx.embedded_window(@id, title: @title, width: @width,
        frame: :win11) do |ui|
        # --- A: the BIG icon left, the app column right ---------------
        # The column lays out first (its height decides how tall the
        # icon block must be), then the icon stretches into the space
        # left of it — one pass, no re-layout.
        avail = ui.available_width
        icon_w = @icon ? {ICON_MIN, avail * ICON_WIDTH_SHARE}.min : 0.0
        gap = @icon ? ICON_GAP : 0.0
        col = ui.child_ui(
          Rect.from_min_size(
            Pos2.new(ui.cursor.x + icon_w + gap, ui.cursor.y),
            Vec2.new({avail - icon_w - gap, 10.0}.max, 1e6)),
          layout: Layout.top_down)
        col.heading(@title)
        col.label("Version #{@version}") if @version
        if (label = @update_label)
          # Explicit id: hosts can address the button (specs,
          # "press it from code" demos).
          col.button(label, id: "#{@id}_update").clicked?.try { |c|
            @on_update.try(&.call) if c
          }
        end
        unless @update_status.empty?
          col.rich(RichText.new(@update_status)
            .small(col.style.font_size).weak(col.style.visuals))
        end
        col.label(@description, wrap: true) unless @description.empty?
        col_h = col.min_rect.height
        side = {col_h, icon_w > 0.0 ? ICON_MIN : 0.0}.max
        if (source = @icon) && side > 0.0
          cell = ui.child_ui(Rect.from_min_size(
            Pos2.new(ui.cursor.x, ui.cursor.y), Vec2.new(icon_w, side)))
          cell.add(Svg.new(source, Vec2.new(icon_w, side)))
        end
        ui.allocate_space(Vec2.new(avail, {side, col_h}.max))

        # --- B: the links row (C) and the small footer text (D) ------
        # The footer label is CENTERED (Label#align) — the small
        # copyright line reads as a caption of the whole dialog, not a
        # dangling ragged paragraph at its left edge.
        unless @links.empty?
          ui.separator
          ui.horizontal do |row|
            @links.each_with_index do |(label, url), i|
              row.label("·") if i > 0
              row.hyperlink_to(label, url, id: "#{@id}_link_#{i}")
            end
          end
        end
        unless @footer.empty?
          ui.rich(RichText.new(@footer)
            .small(ui.style.font_size).weak(ui.style.visuals),
            align: :center)
        end
      end
    end
  end
end
