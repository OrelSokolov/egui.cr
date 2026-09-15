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
end
