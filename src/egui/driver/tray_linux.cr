# Linux system-tray adapter: Ayatana AppIndicator (StatusNotifierItem
# over D-Bus) with a GTK menu.
#
# Ported from positron.cr's adapters/linux/app_indicator_tray.cr and
# getlantern/systray's systray_linux.c (~/systray): all GTK work is
# marshalled to one thread through g_idle_add, menu items are tracked
# by id so updates, submenus and checkables work like on the other
# platforms.
#
# The egui.cr Linux driver owns X11 directly — there is no GTK main
# loop to piggyback on (unlike positron). So the adapter owns a
# dedicated pthread running gtk_main, spawned on the first `create`
# (getlantern does the same with a locked OS goroutine). Officially
# GTK wants the main thread; running the whole toolkit on one private
# thread is the established getlantern/systray deployment shape.
# The thread registers itself with the Boehm GC
# (GC_allow_register_threads + GC_register_my_thread) so the Crystal
# closures it runs are traced — the sokol render thread avoids this by
# never allocating Crystal-side; here the idle callbacks do.
#
# Clicks fire on the GTK thread and land in the port's mutex-guarded
# click queue; drain with `take_clicks` from `update`. A registered
# `on_click` handler would run on the tray's GTK thread on this
# platform — prefer `take_clicks` for immediate-mode apps.
#
# Opt-in like audio: `require "egui/driver/tray_linux"` installs the
# implementation and links GTK/Ayatana; apps that skip it keep the
# headless no-op port. The icon needs a StatusNotifier host in the
# session (KDE/XFCE, GNOME with the AppIndicator extension).

{% if flag?(:linux) && !flag?(:android) %}

@[Link("ayatana-appindicator3")]
lib LibAppIndicator
  APP_INDICATOR_STATUS_PASSIVE = 0
  APP_INDICATOR_STATUS_ACTIVE  = 1

  fun app_indicator_get_type : UInt64
  fun app_indicator_set_status(self : Void*, status : Int32)
  fun app_indicator_set_menu(self : Void*, menu : Void*)
  fun app_indicator_set_icon_full(self : Void*, icon_name : LibC::Char*, icon_desc : LibC::Char*)
  fun app_indicator_set_attention_icon_full(self : Void*, icon_name : LibC::Char*, icon_desc : LibC::Char*)
  fun app_indicator_set_title(self : Void*, title : LibC::Char*)
  fun app_indicator_set_label(self : Void*, label : LibC::Char*, guide : LibC::Char*)
end

@[Link("gtk-3")]
lib LibGTK
  fun gtk_init_check(argc : Int32*, argv : UInt8**) : Int32
  fun gtk_menu_new : Void*
  fun gtk_menu_item_new_with_label(label : LibC::Char*) : Void*
  fun gtk_check_menu_item_new_with_label(label : LibC::Char*) : Void*
  fun gtk_check_menu_item_set_active(widget : Void*, active : Int32)
  fun gtk_menu_item_set_label(widget : Void*, label : LibC::Char*)
  fun gtk_menu_item_get_submenu(widget : Void*) : Void*
  fun gtk_menu_item_set_submenu(widget : Void*, submenu : Void*)
  fun gtk_separator_menu_item_new : Void*
  fun gtk_menu_shell_append(menu_shell : Void*, child : Void*)
  fun gtk_widget_show(widget : Void*)
  fun gtk_widget_hide(widget : Void*)
  fun gtk_widget_set_sensitive(widget : Void*, sensitive : Int32)
  fun gtk_main
  fun gtk_main_quit
end

@[Link("glib-2.0")]
lib LibGLib
  fun g_idle_add(func : Void* -> Int32, data : Void*) : UInt32
end

@[Link("gobject-2.0")]
lib LibGObject
  fun g_object_new(object_type : UInt64, ...) : Void*
  fun g_signal_connect_data(
    instance : Void*,
    detailed_signal : LibC::Char*,
    c_handler : Void*,
    data : Void*,
    destroy_data : Void*,
    connect_flags : Int32,
  ) : UInt64
  fun g_signal_handler_block(instance : Void*, handler_id : UInt64)
  fun g_signal_handler_unblock(instance : Void*, handler_id : UInt64)
end

# Boehm GC thread registration: exposes the collector's symbols (they
# are linked into every Crystal binary through the runtime's libgc).
lib LibGcThread
  struct GcStackBase
    mem_base : Void*
    reg_base : Void*
    cold_base : Void*
  end

  fun allow_register_threads = GC_allow_register_threads : Void
  fun get_stack_base = GC_get_stack_base(sb : GcStackBase*) : Int32
  fun register_my_thread = GC_register_my_thread(sb : GcStackBase*) : Int32
  fun unregister_my_thread = GC_unregister_my_thread : Int32
end

module Egui
  module Driver
    class LinuxTray < Egui::SystemPorts::Tray::Implementation
      struct MenuItemNode
        getter widget : Void*
        getter signal_id : UInt64
        getter click_box : Void* # keeps the boxed {self, id} alive for the signal's lifetime

        def initialize(@widget : Void*, @signal_id : UInt64, @click_box : Void*)
        end
      end

      @indicator : Void* = Pointer(Void).null
      @menu : Void* = Pointer(Void).null
      @started = false        # the GTK thread spawned (GUI thread)
      @failed = false         # gtk_init_check failed (GTK thread)
      @items = Hash(Int32, Egui::SystemPorts::Tray::TrayItem).new
      @nodes = Hash(Int32, MenuItemNode).new
      @temp_icon_path : String? = nil # GUI-thread-owned
      @pending_icon_path : String? = nil
      @pending_title : String? = nil
      @thread : LibC::PthreadT = 0_u64

      # Idle closures passed to C: glib holds the raw pointer only, so
      # keep every box referenced until its callback ran (removed by
      # the GTK thread, added by the GUI thread — mutex-guarded).
      @@refs = [] of Void*
      @@refs_lock = Thread::Mutex.new

      def supported? : Bool
        true
      end

      def create(icon : Egui::SystemPorts::Tray::IconSource?,
                 title : String?, tooltip : String?) : Nil
        return if @started
        @started = true
        # The temp icon file must be written on the GUI thread (Crystal
        # IO needs the scheduler, absent on the tray's pthread); the
        # GTK thread only hands the path to AppIndicator.
        @pending_icon_path = write_icon_file(icon) if icon && !icon.ico?
        @pending_title = title

        LibGcThread.allow_register_threads
        arg = Box.box(self)
        if LibC.pthread_create(pointerof(@thread), Pointer(LibC::PthreadAttrT).null,
                               @@thread_proc, arg) == 0
          LibC.pthread_detach(@thread)
        else
          @started = false
        end
      end

      def set_icon(icon : Egui::SystemPorts::Tray::IconSource) : Nil
        # AppIndicator's pixbuf loader has no ICO decoder.
        return if icon.ico?
        path = write_icon_file(icon)
        return unless path
        on_gtk_thread { gtk_apply_icon(path) }
      end

      def set_title(title : String) : Nil
        on_gtk_thread { gtk_set_title(title) }
      end

      def set_tooltip(tooltip : String) : Nil
        # AppIndicator exposes no icon tooltip (positron no-op'd here
        # too); the panel shows the title.
      end

      def add_item(item : Egui::SystemPorts::Tray::TrayItem) : Nil
        return if item.separator?
        on_gtk_thread { gtk_add_or_update_item(item.dup) }
      end

      def add_separator(id : Int32) : Nil
        on_gtk_thread do
          separator = LibGTK.gtk_separator_menu_item_new
          LibGTK.gtk_menu_shell_append(@menu, separator)
          LibGTK.gtk_widget_show(separator)
          @nodes[id] = MenuItemNode.new(separator, 0_u64, Pointer(Void).null)
        end
      end

      def remove_item(id : Int32) : Nil
        on_gtk_thread do
          @items.delete(id)
          # positron's remove: hide the widget (stays owned by the
          # menu, like the donor's do_hide_item).
          node = @nodes.delete(id)
          node.try { |n| LibGTK.gtk_widget_hide(n.widget) }
        end
      end

      def show_item(id : Int32) : Nil
        on_gtk_thread { @nodes[id]?.try { |n| LibGTK.gtk_widget_show(n.widget) } }
      end

      def hide_item(id : Int32) : Nil
        on_gtk_thread { @nodes[id]?.try { |n| LibGTK.gtk_widget_hide(n.widget) } }
      end

      def show : Nil
        on_gtk_thread do
          LibAppIndicator.app_indicator_set_status(
            @indicator, LibAppIndicator::APP_INDICATOR_STATUS_ACTIVE)
        end
      end

      def hide : Nil
        on_gtk_thread do
          LibAppIndicator.app_indicator_set_status(
            @indicator, LibAppIndicator::APP_INDICATOR_STATUS_PASSIVE)
        end
      end

      def quit : Nil
        on_gtk_thread do
          # AppIndicator has no "unregister"; PASSIVE hides the icon
          # (same workaround as systray_linux.c's do_quit).
          LibAppIndicator.app_indicator_set_status(
            @indicator, LibAppIndicator::APP_INDICATOR_STATUS_PASSIVE)
          LibGTK.gtk_main_quit
        end
      end

      # --- GTK thread ---

      # pthread body: registers with the GC, initializes GTK, creates
      # the indicator + menu, applies what `create` captured, then owns
      # the main loop until quit.
      def gtk_thread_main : Nil
        stack_base = LibGcThread::GcStackBase.new
        registered = LibGcThread.get_stack_base(pointerof(stack_base)) == 0 &&
                     LibGcThread.register_my_thread(pointerof(stack_base)) == 0

        if LibGTK.gtk_init_check(Pointer(Int32).null, Pointer(Pointer(UInt8)).null) == 0
          @failed = true
          LibGcThread.unregister_my_thread if registered
          return
        end

        # g_object_new instead of the deprecated app_indicator_new()
        # (getlantern/systray's fix).
        @indicator = LibGObject.g_object_new(
          LibAppIndicator.app_indicator_get_type,
          "id", "egui-cr-tray",
          "category", "ApplicationStatus",
          "icon-name", "",
          Pointer(Void).null)
        @menu = LibGTK.gtk_menu_new
        LibAppIndicator.app_indicator_set_menu(@indicator, @menu)
        LibAppIndicator.app_indicator_set_status(
          @indicator, LibAppIndicator::APP_INDICATOR_STATUS_ACTIVE)

        # Whatever create() was passed, before any idle callback runs.
        if (path = @pending_icon_path)
          gtk_apply_icon(path)
        end
        @pending_title.try { |t| gtk_set_title(t) }

        LibGTK.gtk_main

        LibGcThread.unregister_my_thread if registered
      end

      # AppIndicator resolves icons by name or absolute path — the
      # temp file itself is written on the GUI thread (write_icon_file);
      # here only the two native calls happen.
      protected def gtk_apply_icon(path : String) : Nil
        return if @indicator.null?
        LibAppIndicator.app_indicator_set_icon_full(@indicator, path, "")
        LibAppIndicator.app_indicator_set_attention_icon_full(@indicator, path, "")
      end

      protected def gtk_set_title(title : String) : Nil
        return if @indicator.null?
        LibAppIndicator.app_indicator_set_title(@indicator, title)
        LibAppIndicator.app_indicator_set_label(@indicator, title, "")
      end

      # positron's do_add_or_update_item: update in place when the id
      # exists (blocking the check handler so a programmatic state set
      # does not fire a click), else append to the root menu or the
      # parent's on-demand submenu.
      protected def gtk_add_or_update_item(item : Egui::SystemPorts::Tray::TrayItem) : Nil
        return if @indicator.null?
        @items[item.id] = item

        if node = @nodes[item.id]?
          LibGTK.gtk_menu_item_set_label(node.widget, item.title)
          if item.checkable
            LibGObject.g_signal_handler_block(node.widget, node.signal_id)
            LibGTK.gtk_check_menu_item_set_active(
              node.widget, item.checked ? 1 : 0)
            LibGObject.g_signal_handler_unblock(node.widget, node.signal_id)
          end
        else
          widget = LibGTK.gtk_check_menu_item_new_with_label(item.title) if item.checkable
          widget ||= LibGTK.gtk_menu_item_new_with_label(item.title)
          LibGTK.gtk_check_menu_item_set_active(widget, item.checked ? 1 : 0) if item.checkable

          click_box = Box.box({self, item.id})
          signal_id = LibGObject.g_signal_connect_data(
            widget, "activate",
            @@activate_proc.pointer.as(Void*), click_box.as(Void*),
            Pointer(Void).null, 0)

          parent_menu = parent_menu_for(item.parent_id)
          LibGTK.gtk_menu_shell_append(parent_menu, widget)
          @nodes[item.id] = MenuItemNode.new(widget, signal_id, click_box)
          node = @nodes[item.id]
        end

        if node = @nodes[item.id]?
          LibGTK.gtk_widget_set_sensitive(node.widget, item.disabled ? 0 : 1)
          item.hidden ? LibGTK.gtk_widget_hide(node.widget)
                       : LibGTK.gtk_widget_show(node.widget)
        end
      end

      # Menu "activate" (GTK thread): mirror the checkable toggle in
      # the port's model — the GTK widget already flipped its own
      # visual state — then queue the click.
      protected def handle_activate(id : Int32) : Nil
        if (item = @items[id]?) && item.checkable
          item.checked = !item.checked
          @items[id] = item
        end
        Egui::SystemPorts::Tray.enqueue_click(id)
      end

      # Items with parent_id nest under the parent's submenu, created
      # on demand (positron's submenu branch).
      private def parent_menu_for(parent_id : Int32) : Void*
        return @menu unless parent_id > 0
        parent = @nodes[parent_id]?
        return @menu if parent.nil?

        submenu = LibGTK.gtk_menu_item_get_submenu(parent.widget)
        if submenu.null?
          submenu = LibGTK.gtk_menu_new
          LibGTK.gtk_menu_item_set_submenu(parent.widget, submenu)
        end
        submenu
      end

      # --- GUI thread helpers ---

      # AppIndicator resolves icons by absolute path, and the file
      # extension tells the loader the format (systray_linux.c
      # do_set_icon). Replaces (unlinks) the previous temp icon —
      # positron's cleanup_temp_icon.
      private def write_icon_file(icon : Egui::SystemPorts::Tray::IconSource) : String?
        ext = icon.svg? ? "svg" : "png"
        path = File.join(Dir.tempdir, "egui_tray_icon_#{Random::Secure.hex(8)}.#{ext}")
        begin
          File.write(path, icon.bytes)
        rescue
          return nil
        end
        if (old = @temp_icon_path) && old != path
          File.delete(old) rescue nil
        end
        @temp_icon_path = path
        path
      end

      # Public for the require-time at_exit hook (main-thread teardown:
      # unlink the temp icon file).
      def cleanup_temp_icon : Nil
        if (path = @temp_icon_path)
          File.delete(path) rescue nil
          @temp_icon_path = nil
        end
      end

      # --- GUI thread → GTK thread marshalling ---

      # g_idle_add is thread-safe; sources queued before gtk_main
      # started run once it does, strictly after gtk_thread_main's own
      # setup (same thread, same context).
      private def on_gtk_thread(&job : Proc(Nil)) : Nil
        return unless @started
        box = Box(Proc(Nil)).box(job)
        @@refs_lock.synchronize { @@refs << box }
        LibGLib.g_idle_add(@@idle_proc, box)
      end

      # Shared (self-free of captures) so they convert to plain C
      # function pointers; the per-instance state rides in Box args.
      @@idle_proc : Void* -> Int32 = ->(ptr : Void*) {
        job = Box(Proc(Nil)).unbox(ptr)
        job.call
        @@refs_lock.synchronize { @@refs.delete(ptr) }
        0 # G_SOURCE_REMOVE — run once
      }

      @@activate_proc : Void*, Void* -> Nil = ->(widget : Void*, data : Void*) {
        tuple = Box(Tuple(LinuxTray, Int32)).unbox(data)
        tuple[0].handle_activate(tuple[1])
      }

      @@thread_proc : Void* -> Void* = ->(arg : Void*) {
        Box(LinuxTray).unbox(arg).gtk_thread_main
        Pointer(Void).null
      }
    end

    # Installed at require time — audio.cr's pattern: opt-in backends
    # self-install, sokol's run() only wires the darwin default. The
    # at_exit (main thread — Crystal IO is scheduler-bound) unlinks the
    # temp icon; quit() itself may run on the render thread.
    instance = LinuxTray.new
    SystemPorts::Tray.use(instance)
    at_exit { instance.cleanup_temp_icon }
  end
end

{% end %}
