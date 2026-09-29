# Port of egui_upstream/crates/egui/src/data/output.rs (`CursorIcon`) —
# the mouse cursor request a frame produces for the integration
# (backend). Variant names follow the CSS `cursor` keywords
# (https://developer.mozilla.org/en-US/docs/Web/CSS/cursor) so
# `#to_css`/`.parse?` round-trip the CSS syntax directly:
#
#   CursorIcon::Pointer.to_css       # => "pointer"
#   CursorIcon.parse?("ew-resize")   # => CursorIcon::EwResize

module Egui
  enum CursorIcon
    Default
    None
    # Links and status:
    ContextMenu
    Help
    # Pointing hand, used for e.g. web links (CSS `pointer`).
    Pointer
    Progress
    Wait
    # Selection:
    Cell
    Crosshair
    Text
    VerticalText
    # Drag-and-drop:
    Alias
    Copy
    Move
    NoDrop
    NotAllowed
    Grab
    Grabbing
    AllScroll
    # Resizing in two directions (CSS `ew-resize`, `nesw-resize`, …):
    EwResize
    NeswResize
    NwseResize
    NsResize
    # Resizing in one direction:
    EResize
    SeResize
    SResize
    SwResize
    WResize
    NwResize
    NResize
    NeResize
    # Column/row resizing (CSS `col-resize`, `row-resize`):
    ColResize
    RowResize
    # Zooming:
    ZoomIn
    ZoomOut

    # The CSS `cursor` keyword (kebab-case — what CSS and Xcursor
    # themes both use as the cursor name).
    def to_css : String
      to_s.underscore.gsub('_', '-')
    end

    # Parse a CSS `cursor` keyword ("pointer", "ew-resize", …).
    # Returns nil for unknown names; `auto`/`inherit`/`unset` map to
    # Default (the platform's own choice).
    def self.parse?(name : String) : CursorIcon?
      normalized = name.downcase.tr("-", "_")
      return Default if {"auto", "inherit", "unset"}.includes?(normalized)
      values.find { |icon| icon.to_s.underscore == normalized }
    end
  end

  # Port of egui `CustomCursorImage` (`PlatformOutput::cursor_image`): a
  # bitmap the integration uploads to the OS as the real cursor — unlike
  # painter-drawn cursor sprites it is not clipped by the window, exactly
  # what the CSS `cursor: url(…)` syntax gives a browser. `rgba` is
  # straight (non-premultiplied) RGBA, exactly `width * height * 4`
  # bytes; the hotspot is the pixel the pointer position maps to,
  # measured from the top-left. Backends without bitmap-cursor support
  # fall back to `CursorIcon`.
  #
  # Build one and hold it (a constant or ivar), then push it per frame:
  #
  #   FILL_CURSOR = Egui::CustomCursorImage.new(rgba, 32, 32, 4, 28)
  #   resp.on_hover_cursor_image(FILL_CURSOR)
  class CustomCursorImage
    getter rgba : Bytes
    getter width : Int32
    getter height : Int32
    getter hotspot_x : Int32
    getter hotspot_y : Int32

    def initialize(rgba : Bytes, width : Int32, height : Int32,
                   hotspot_x : Int32 = 0, hotspot_y : Int32 = 0)
      if width <= 0 || height <= 0
        raise ArgumentError.new(
          "cursor image size must be positive (got #{width}x#{height})")
      end
      if rgba.size != width * height * 4
        raise ArgumentError.new(
          "rgba must be exactly width*height*4 bytes " \
          "(got #{rgba.size}, need #{width * height * 4})")
      end
      @rgba = rgba
      @width = width
      @height = height
      @hotspot_x = hotspot_x.clamp(0, width - 1)
      @hotspot_y = hotspot_y.clamp(0, height - 1)
    end

    # The identity check the backend dedupes OS cursor uploads by (the
    # `Arc::ptr_eq` role upstream): same buffer, geometry and hotspot —
    # reusing one instance across frames re-uploads nothing.
    def same?(other : CustomCursorImage) : Bool
      rgba.to_unsafe == other.rgba.to_unsafe &&
        rgba.size == other.rgba.size &&
        width == other.width && height == other.height &&
        hotspot_x == other.hotspot_x && hotspot_y == other.hotspot_y
    end
  end
end
