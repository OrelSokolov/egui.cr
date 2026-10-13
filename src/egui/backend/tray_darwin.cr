# macOS system-tray adapter: NSStatusBar / NSStatusItem through the
# minimal ObjC runtime layer (backend/objc.cr).
#
# Ported from positron.cr's adapters/macos/tray.cr (StatusBarTray),
# which follows the reference implementation in OrelSokolov/systray
# (`systray_darwin.m`, a getlantern/systray fork):
#   - the status item is explicitly made `visible` after creation
#     (a user-hidden item stays hidden otherwise, even across
#     restarts),
#   - icons are normalized to a 16×16 NSImage (`setSize:`) with
#     `template` support,
#   - the button's `imagePosition` is kept explicit
#     (NSImageOnly / NSImageLeft / NSNoImage),
#   - menu items dispatch through target-action with the item id
#     as the tag; checkable items toggle on click.
#
# Differences from the positron donor: no `App.ensure_app` (sokol
# already raised NSApplication), and clicks go through
# `SystemPorts::Tray.enqueue_click` instead of a direct callback.
# All calls must happen on the GUI thread — same thread sokol's
# legacy macOS loop uses for frames, so calling from `update` is
# safe, and menu actions fire between frames.

require "./objc"

module Egui
  module Backend
    class DarwinTray < Egui::SystemPorts::Tray::Implementation
      NS_VARIABLE_STATUS_ITEM_LENGTH = -1.0
      ACTION_SELECTOR                = "eguiCrTrayAction:"

      # NSCellImagePosition values
      NS_NO_IMAGE   = 0_i64
      NS_IMAGE_LEFT = 2_i64
      NS_IMAGE_ONLY = 5_i64

      ICON_WIDTH  = 16.0
      ICON_HEIGHT = 16.0

      @status_bar : Void*?
      @status_item : Void*?
      @menu : Void*?
      @items = Hash(Int32, Egui::SystemPorts::Tray::TrayItem).new
      @nodes = Hash(Int32, Void*).new # id -> NSMenuItem
      @target_obj : Void*?

      @@action_imp : Proc(Void*, Void*, Void*, Nil)?

      def supported? : Bool
        true
      end

      def create(icon : Egui::SystemPorts::Tray::IconSource?,
                 title : String?, tooltip : String?) : Nil
        ObjC.with_autorelease_pool do
          @status_bar = ObjC.send0(ObjC.cls("NSStatusBar"), ObjC.sel("systemStatusBar"))
          # NSVariableStatusItemLength (-1.0): float argument → NSInvocation.
          item = ObjC::Call
            .new(@status_bar.not_nil!, "statusItemWithLength:")
            .double(2, NS_VARIABLE_STATUS_ITEM_LENGTH)
            .invoke
            .ret_ptr
          # statusItemWithLength: follows the autorelease convention;
          # keep our own reference like systray_darwin.m's strong ivar.
          ObjC.send0(item, ObjC.sel("retain"))
          @status_item = item

          @target_obj ||= build_target
          menu = ObjC.send1(
            ObjC.send0(ObjC.cls("NSMenu"), ObjC.sel("alloc")),
            ObjC.sel("initWithTitle:"), ObjC.nsstr(title || ""))
          ObjC.send0(menu, ObjC.sel("retain"))
          # Items must obey setEnabled: instead of AppKit's auto-enable
          # heuristics (which would grey out everything target-less).
          ObjC.send1(menu, ObjC.sel("setAutoenablesItems:"), ObjC.bool_arg(false))
          ObjC.send1(item, ObjC.sel("setMenu:"), menu)
          @menu = menu

          # Once the user has removed the item (⌘-drag), it needs to be
          # explicitly brought back — ensure it is always visible at
          # startup, exactly like systray_darwin.m's initStatusItem.
          if ObjC.send1_b(item, ObjC.sel("respondsToSelector:"), ObjC.sel("setVisible:"))
            ObjC.send1(item, ObjC.sel("setVisible:"), ObjC.bool_arg(true))
          end

          set_icon(icon) if icon
          set_title(title) if title
          set_tooltip(tooltip) if tooltip
        end
      end

      def set_icon(icon : Egui::SystemPorts::Tray::IconSource) : Nil
        if icon.ico?
          # ICO has no NSImage decoder — the caller should pass PNG/SVG.
          return
        end
        return unless status_item?

        image = ObjC.send1(
          ObjC.send0(ObjC.cls("NSImage"), ObjC.sel("alloc")),
          ObjC.sel("initWithData:"), ObjC.nsdata(icon.bytes))
        return if image.null?
        # systray_darwin.m setIcon: normalize to 16×16 (SVGs otherwise
        # keep their natural size, e.g. 128×128) and mark non-template
        # (full color) — template icons would be flattened monochrome.
        ObjC.send_size(image, "setSize:",
          ObjC::LibObjC::NSSize.new(width: ICON_WIDTH, height: ICON_HEIGHT))
        ObjC.send1(image, ObjC.sel("setTemplate:"), ObjC.bool_arg(false))
        # The button retains the image; balance our alloc reference.
        ObjC.send1(button, ObjC.sel("setImage:"), image)
        ObjC.send0(image, ObjC.sel("release"))
        update_button_style
      end

      def set_title(title : String) : Nil
        return unless status_item?
        ObjC.send1(button, ObjC.sel("setTitle:"), ObjC.nsstr(title))
        update_button_style
      end

      def set_tooltip(tooltip : String) : Nil
        return unless status_item?
        ObjC.send1(button, ObjC.sel("setToolTip:"), ObjC.nsstr(tooltip))
      end

      def add_item(item : Egui::SystemPorts::Tray::TrayItem) : Nil
        return if item.separator?

        @items[item.id] = item.dup
        return unless menu_created?

        if node = @nodes[item.id]?
          apply_item_state(node, item)
        else
          node = ObjC.send3(
            ObjC.send0(ObjC.cls("NSMenuItem"), ObjC.sel("alloc")),
            ObjC.sel("initWithTitle:action:keyEquivalent:"),
            ObjC.nsstr(item.title),
            ObjC.sel(ACTION_SELECTOR),
            ObjC.nsstr(""))
          ObjC.send1(node, ObjC.sel("setTarget:"), @target_obj.not_nil!)
          ObjC.send1(node, ObjC.sel("setTag:"), ObjC.int_arg(item.id))
          ObjC.send1(parent_menu_for(item.parent_id), ObjC.sel("addItem:"), node)
          @nodes[item.id] = node
          apply_item_state(node, item)
        end
      end

      def add_separator(id : Int32) : Nil
        return unless menu_created?
        separator = ObjC.send0(ObjC.cls("NSMenuItem"), ObjC.sel("separatorItem"))
        ObjC.send1(separator, ObjC.sel("setTag:"), ObjC.int_arg(id))
        ObjC.send1(@menu.not_nil!, ObjC.sel("addItem:"), separator)
        @nodes[id] = separator
      end

      def remove_item(id : Int32) : Nil
        @items.delete(id)
        if (node = @nodes.delete(id)) && !node.null?
          owner = ObjC.send0(node, ObjC.sel("menu"))
          ObjC.send1(owner, ObjC.sel("removeItem:"), node) unless owner.null?
        end
      end

      def show_item(id : Int32) : Nil
        if node = @nodes[id]?
          ObjC.send1(node, ObjC.sel("setHidden:"), ObjC.bool_arg(false))
        end
      end

      def hide_item(id : Int32) : Nil
        if node = @nodes[id]?
          ObjC.send1(node, ObjC.sel("setHidden:"), ObjC.bool_arg(true))
        end
      end

      def show : Nil
        if item = @status_item
          ObjC.send1(item, ObjC.sel("setVisible:"), ObjC.bool_arg(true)) if responds?(item, "setVisible:")
        end
      end

      def hide : Nil
        if item = @status_item
          ObjC.send1(item, ObjC.sel("setVisible:"), ObjC.bool_arg(false)) if responds?(item, "setVisible:")
        end
      end

      def quit : Nil
        if (bar = @status_bar) && (item = @status_item)
          ObjC.send1(bar, ObjC.sel("removeStatusItem:"), item)
          ObjC.send0(item, ObjC.sel("release"))
        end
        if (menu = @menu)
          ObjC.send0(menu, ObjC.sel("release"))
        end
        @status_item = nil
        @menu = nil
      end

      # --- Internals ---

      protected def handle_action(sender : Void*) : Nil
        id = ObjC.send0_i(sender, ObjC.sel("tag")).to_i32
        item = @items[id]?

        # NSMenuItem does not auto-toggle; keep the checked state here.
        if item && item.checkable
          item.checked = !item.checked
          @items[id] = item
          if node = @nodes[id]?
            ObjC.send1(node, ObjC.sel("setState:"), ObjC.int_arg(item.checked ? 1 : 0))
          end
        end

        Egui::SystemPorts::Tray.enqueue_click(id)
      end

      # systray_darwin.m updateTitleButtonStyle: keep the icon/title
      # layout explicit so AppKit doesn't guess.
      private def update_button_style : Nil
        btn = button
        has_image = !ObjC.send0(btn, ObjC.sel("image")).null?
        title = ObjC.to_s(ObjC.send0(btn, ObjC.sel("title")))

        position = if has_image
                     (title && !title.empty?) ? NS_IMAGE_LEFT : NS_IMAGE_ONLY
                   else
                     NS_NO_IMAGE
                   end
        ObjC.send1(btn, ObjC.sel("setImagePosition:"), ObjC.int_arg(position))
      end

      private def button : Void*
        ObjC.send0(@status_item.not_nil!, ObjC.sel("button"))
      end

      private def status_item? : Bool
        !@status_item.nil? && !@status_item.not_nil!.null?
      end

      private def menu_created? : Bool
        !@menu.nil? && !@menu.not_nil!.null?
      end

      private def responds?(obj : Void*, selector : String) : Bool
        ObjC.send1_b(obj, ObjC.sel("respondsToSelector:"), ObjC.sel(selector))
      end

      # Items with parent_id land in the parent's submenu (created on
      # demand, like find_menu_item + setSubmenu in systray_darwin.m);
      # everything else goes on the root menu.
      private def parent_menu_for(parent_id : Int32) : Void*
        return @menu.not_nil! unless parent_id > 0
        parent = @nodes[parent_id]?
        return @menu.not_nil! if parent.nil?

        submenu = ObjC.send0(parent, ObjC.sel("submenu"))
        if submenu.null?
          submenu = ObjC.send1(
            ObjC.send0(ObjC.cls("NSMenu"), ObjC.sel("alloc")),
            ObjC.sel("initWithTitle:"), ObjC.nsstr(""))
          ObjC.send0(submenu, ObjC.sel("retain"))
          ObjC.send1(parent, ObjC.sel("setSubmenu:"), submenu)
        end
        submenu
      end

      private def apply_item_state(node : Void*, item : Egui::SystemPorts::Tray::TrayItem) : Nil
        ObjC.send1(node, ObjC.sel("setTitle:"), ObjC.nsstr(item.title))
        ObjC.send1(node, ObjC.sel("setState:"), ObjC.int_arg((item.checkable && item.checked) ? 1 : 0))
        ObjC.send1(node, ObjC.sel("setEnabled:"), ObjC.bool_arg(!item.disabled))
        ObjC.send1(node, ObjC.sel("setHidden:"), ObjC.bool_arg(item.hidden))
        ObjC.send1(node, ObjC.sel("setToolTip:"), ObjC.nsstr(item.tooltip)) unless item.tooltip.empty?
      end

      # NSObject receiving menu item target-action clicks.
      private def build_target : Void*
        objc_class = ObjC.new_class("EguiCrTrayTarget")

        @@action_imp = ->(objc_self : Void*, _cmd : Void*, sender : Void*) {
          tray = ObjC.target_for(objc_self).as?(DarwinTray)
          tray.try(&.handle_action(sender))
        }
        ObjC::LibObjC.class_addMethod(
          objc_class, ObjC.sel(ACTION_SELECTOR),
          @@action_imp.not_nil!.pointer.as(Void*), "v@:@")

        target = ObjC.send0(objc_class, ObjC.sel("new"))
        ObjC.bind_target(target, self)
        target
      end
    end
  end
end
