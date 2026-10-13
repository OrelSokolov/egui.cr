# System port Tray: system tray / status bar icon with a native menu.
#
# Ported from positron.cr (which ported it from getlantern/systray and
# the OrelSokolov/systray fork). The core keeps the port headless: it
# owns the cross-platform menu model (`TrayItem`, `IconSource`) and the
# click queue, and delegates the native surface to an installable
# implementation — backend/sokol.cr wires backend/tray_darwin.cr
# (NSStatusBar/NSStatusItem) on macOS; other platforms keep the no-op
# default (`supported?` false).
#
# Clicks arrive on the app's main thread between frames (from the
# native menu tracker), so the queue needs no locking. Two consumption
# styles, pick one:
#   * `on_click { |id| }` — handler fires as the click arrives;
#   * `take_clicks` — drain the queue from `update` (immediate-mode
#     apps mutate state there anyway).

module Egui
  module SystemPorts
    module Tray
      class_getter implementation : Implementation = Implementation.new

      # Install a platform implementation (called by the backend).
      def self.use(implementation : Implementation) : Nil
        @@implementation = implementation
      end

      # Whether the current platform/backend has a real tray surface.
      def self.supported? : Bool
        implementation.supported?
      end

      # Create the tray icon. Call from `update` (the GUI thread).
      def self.create(icon : IconSource? = nil, title : String? = nil,
                      tooltip : String? = nil) : Nil
        implementation.create(icon, title, tooltip)
      end

      def self.set_icon(icon : IconSource) : Nil
        implementation.set_icon(icon)
      end

      # Text next to the icon (macOS/Linux only — the Windows tray has
      # no label).
      def self.set_title(title : String) : Nil
        implementation.set_title(title)
      end

      def self.set_tooltip(tooltip : String) : Nil
        implementation.set_tooltip(tooltip)
      end

      # Add a menu item, or update it when the id already exists.
      def self.add_item(item : TrayItem) : Nil
        implementation.add_item(item)
      end

      def self.add_item(id : Int32, title : String, *, tooltip : String = "",
                        disabled : Bool = false, checked : Bool = false,
                        checkable : Bool = false, parent_id : Int32 = 0,
                        hidden : Bool = false) : Nil
        add_item(TrayItem.new(id: id, title: title, tooltip: tooltip,
          disabled: disabled, checked: checked, checkable: checkable,
          parent_id: parent_id, hidden: hidden))
      end

      def self.add_separator(id : Int32) : Nil
        implementation.add_separator(id)
      end

      def self.remove_item(id : Int32) : Nil
        implementation.remove_item(id)
      end

      def self.show_item(id : Int32) : Nil
        implementation.show_item(id)
      end

      def self.hide_item(id : Int32) : Nil
        implementation.hide_item(id)
      end

      def self.show : Nil
        implementation.show
      end

      def self.hide : Nil
        implementation.hide
      end

      # Remove the tray icon and release native resources (called by
      # the backend's cleanup path).
      def self.quit : Nil
        implementation.quit
      end

      # --- Click queue ---

      # Register a click handler; fires from the GUI thread as the
      # native menu item is activated (between frames).
      def self.on_click(&block : Int32 ->) : Nil
        @@handler = block
      end

      # Drain and clear pending menu-item clicks (poll from `update`).
      def self.take_clicks : Array(Int32)
        clicks = @@pending
        @@pending = [] of Int32
        clicks
      end

      # Implementations report menu-item activations here.
      def self.enqueue_click(id : Int32) : Nil
        @@pending << id
        @@handler.try(&.call(id))
      end

      @@pending = [] of Int32
      @@handler : Proc(Int32, Nil)?

      # A single entry in the tray menu. `parent_id > 0` nests the item
      # in that item's submenu; a separator is any item whose title is
      # "-" (getlantern/systray convention).
      class TrayItem
        getter id : Int32
        getter parent_id : Int32
        property title : String
        property tooltip : String
        property disabled : Bool
        property checked : Bool
        property checkable : Bool
        property hidden : Bool

        def initialize(@id : Int32, @title : String, @tooltip : String = "",
                       @disabled : Bool = false, @checked : Bool = false,
                       @checkable : Bool = false, @parent_id : Int32 = 0,
                       @hidden : Bool = false)
        end

        def separator? : Bool
          @title == "-"
        end
      end

      # Cross-platform icon descriptor: raw image bytes plus their
      # format. Adapters convert to the native handle (PNG for macOS
      # NSImage, ICO/PNG for the Windows NotifyIcon, pixels/SNI on
      # Linux).
      struct IconSource
        getter bytes : Bytes
        getter format : Symbol

        def initialize(@bytes : Bytes, @format : Symbol = :png)
        end

        def self.png(bytes : Bytes) : self
          new(bytes, :png)
        end

        def self.svg(bytes : Bytes) : self
          new(bytes, :svg)
        end

        def self.ico(bytes : Bytes) : self
          new(bytes, :ico)
        end

        def svg? : Bool
          @format == :svg
        end

        def png? : Bool
          @format == :png
        end

        def ico? : Bool
          @format == :ico
        end
      end

      # Platform seam; the default is a headless no-op (`supported?`
      # false) so specs run without a desktop.
      class Implementation
        def supported? : Bool
          false
        end

        def create(icon : IconSource?, title : String?, tooltip : String?) : Nil
        end

        def set_icon(icon : IconSource) : Nil
        end

        def set_title(title : String) : Nil
        end

        def set_tooltip(tooltip : String) : Nil
        end

        def add_item(item : TrayItem) : Nil
        end

        def add_separator(id : Int32) : Nil
        end

        def remove_item(id : Int32) : Nil
        end

        def show_item(id : Int32) : Nil
        end

        def hide_item(id : Int32) : Nil
        end

        def show : Nil
        end

        def hide : Nil
        end

        def quit : Nil
        end
      end
    end
  end
end
