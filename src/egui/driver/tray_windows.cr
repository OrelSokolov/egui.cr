# Windows system-tray adapter: Shell_NotifyIconW + TrackPopupMenu.
#
# Third leg of the tray port (plans/todo/SystrayIntegration.md, Фаза 3;
# macOS — driver/tray_darwin.cr, Linux — driver/tray_linux.cr). The
# positron.cr donor (adapters/windows/tray.cr) is gone from the tree —
# this is a from-scratch implementation against the same Win32 surface
# the plan prescribed: a hidden message window receiving WM_APP+1,
# Shell_NotifyIconW + NotifyIconDataW, InsertMenuItemW/TrackPopupMenu,
# LoadImageW (ICO), GDI+ PNG→HICON.
#
# Threading — the one structural difference from the plan's assumption
# ("sokol's PeekMessage pumps WM_APP+1 for the whole thread"): on the
# detached Win32 loop the message pump runs on the C render thread,
# while `update` (where the port's create must be called) runs on the
# Crystal main thread — and window messages belong to the thread that
# created the window. So this adapter owns a dedicated Crystal thread
# running GetMessage, exactly the tray_linux.cr shape (a private
# toolkit thread). That works under both loop flavors (detached and
# EGUI_RENDER_THREAD=0) with no shim changes. The non-affine calls —
# Shell_NotifyIcon, LoadImage, GDI+ — run directly on the caller's
# thread (update); only TrackPopupMenu runs on the tray thread, as it
# must: the menu's modal loop pumps the window's own queue.
#
# Menu model: rebuilt from the item model as a snapshot on every
# click (add/remove/update/show/hide mutations land in the next
# display). TrackPopupMenu with TPM_RETURNCMD returns the selection
# directly — no WM_COMMAND plumbing; item ids map to sequential menu
# commands, because 0 is TrackPopupMenu's "dismissed" answer. The
# KB135788 fix is in: SetForegroundWindow before the menu, WM_NULL
# after — otherwise it won't dismiss on an outside click.
#
# Per-item tooltips are a no-op (HMENU items have none); set_title is
# a no-op (the Windows tray shows no label next to the icon).
#
# Clicks land in the port's mutex-guarded queue from the tray thread —
# drain with `take_clicks` from `update` (a registered `on_click`
# handler would run on the tray thread here, like on Linux).

{% if flag?(:win32) %}

@[Link("user32")]
lib LibTrayUser32
  alias WndProcT = Void*, UInt32, UInt64, Int64 -> Int64

  struct Point
    x : Int32
    y : Int32
  end

  struct Msg
    hwnd : Void*
    message : UInt32
    w_param : UInt64
    l_param : Int64
    time : UInt32
    pt_x : Int32
    pt_y : Int32
    l_private : UInt32 # WINVER >= 0x0602 tail — room for it either way
  end

  struct WndClassExW
    cb_size : UInt32
    style : UInt32
    wnd_proc : WndProcT
    cls_extra : Int32
    win_extra : Int32
    h_instance : Void*
    h_icon : Void*
    h_cursor : Void*
    h_br_background : Void*
    menu_name : UInt16*
    class_name : UInt16*
    h_icon_sm : Void*
  end

  struct MenuitemInfoW
    cb_size : UInt32
    f_mask : UInt32
    f_type : UInt32
    f_state : UInt32
    w_id : UInt32
    h_submenu : Void*
    hbmp_checked : Void*
    hbmp_unchecked : Void*
    dw_item_data : UInt64
    dw_type_data : UInt16*
    cch : UInt32
    hbmp_item : Void*
  end

  fun register_class_ex = RegisterClassExW(wc : WndClassExW*) : UInt16
  fun create_window_ex = CreateWindowExW(ex_style : UInt32, class_name : UInt16*,
    window_name : UInt16*, style : UInt32, x : Int32, y : Int32, w : Int32,
    h : Int32, parent : Void*, menu : Void*, instance : Void*,
    param : Void*) : Void*
  fun def_window_proc = DefWindowProcW(hwnd : Void*, msg : UInt32,
    w_param : UInt64, l_param : Int64) : Int64
  fun get_message = GetMessageW(msg : Msg*, hwnd : Void*, min : UInt32,
    max : UInt32) : Int32
  fun translate_message = TranslateMessage(msg : Msg*) : Int32
  fun dispatch_message = DispatchMessageW(msg : Msg*) : Int64
  fun destroy_window = DestroyWindow(hwnd : Void*) : Int32
  fun post_message = PostMessageW(hwnd : Void*, msg : UInt32, w : UInt64,
    l : Int64) : Int32
  fun register_window_message = RegisterWindowMessageW(name : UInt16*) : UInt32
  fun get_cursor_pos = GetCursorPos(pt : Point*) : Int32
  fun set_foreground_window = SetForegroundWindow(hwnd : Void*) : Int32
  fun create_popup_menu = CreatePopupMenu : Void*
  fun get_menu_item_count = GetMenuItemCount(menu : Void*) : Int32
  fun insert_menu_item = InsertMenuItemW(menu : Void*, item : UInt32,
    by_position : Int32, mii : MenuitemInfoW*) : Int32
  fun destroy_menu = DestroyMenu(menu : Void*) : Int32
  # TrackPopupMenu has no W/A split (all strings go through menu item
  # infos).
  fun track_popup_menu = TrackPopupMenu(menu : Void*, flags : UInt32,
    x : Int32, y : Int32, reserved : UInt32, hwnd : Void*,
    rect : Void*) : Int32
  fun load_image = LoadImageW(instance : Void*, name : UInt16*,
    type : UInt32, cx : Int32, cy : Int32, load : UInt32) : Void*
  fun destroy_icon = DestroyIcon(hicon : Void*) : Int32
end

@[Link("shell32")]
lib LibTrayShell32
  NIM_ADD    = 0_u32
  NIM_MODIFY = 1_u32
  NIM_DELETE = 2_u32

  # Full V4 layout (x64): tip 40..296, the uTimeout/uVersion union at
  # 560, guidItem 696, hBalloonIcon 712 — sizeof = 720.
  struct NotifyIconDataW
    cb_size : UInt32
    hwnd : Void*
    uid : UInt32
    u_flags : UInt32
    callback_message : UInt32
    h_icon : Void*
    tip : UInt16[128]
    dw_state : UInt32
    dw_state_mask : UInt32
    info : UInt16[256]
    u_version : UInt32
    info_title : UInt16[64]
    dw_info_flags : UInt32
    guid_item : UInt16[8]
    balloon_icon : Void*
  end

  fun shell_notify_icon = Shell_NotifyIconW(message : UInt32,
    data : NotifyIconDataW*) : Int32
end

@[Link("kernel32")]
lib LibTrayKernel32
  fun get_module_handle = GetModuleHandleW(name : UInt16*) : Void*
  fun get_current_thread_id = GetCurrentThreadId : UInt32
  fun post_thread_message = PostThreadMessageW(id : UInt32, msg : UInt32,
    w : UInt64, l : Int64) : Int32
  fun get_temp_path = GetTempPathW(n : UInt32, buf : UInt16*) : UInt32
end

@[Link("gdiplus")]
lib LibTrayGdiplus
  PIXEL_FORMAT_32BPP_ARGB = 0x26200A

  struct StartupInput
    version : UInt32
    debug_event_callback : Void*
    suppress_background_thread : Int32
    suppress_external_codecs : Int32
  end

  fun startup = GdiplusStartup(token : UInt64*, input : StartupInput*,
    output : Void*) : Int32
  fun create_bitmap_from_scan0 = GdipCreateBitmapFromScan0(w : Int32,
    h : Int32, stride : Int32, format : Int32, scan0 : UInt8*,
    bitmap : Void**) : Int32
  fun create_hicon_from_bitmap = GdipCreateHICONFromBitmap(bitmap : Void*,
    hicon : Void**) : Int32
  fun dispose_image = GdipDisposeImage(image : Void*) : Int32
end

module Egui
  module Driver
    class WindowsTray < Egui::SystemPorts::Tray::Implementation
      TRAY_CLASS_NAME = "EguiCrTrayWindow"

      # The icon's callback message (V0 shell behavior: lParam carries
      # the mouse message, wParam the icon id).
      CALLBACK_MSG = 0x8001_u32 # WM_APP + 1

      WM_LBUTTONUP = 0x0202_u32
      WM_RBUTTONUP = 0x0205_u32
      WM_NULL      = 0x0000_u32
      WM_QUIT      = 0x0012_u32

      NIF_MESSAGE = 0x01_u32
      NIF_ICON    = 0x02_u32
      NIF_TIP     = 0x80_u32

      IMAGE_ICON      = 1_u32
      LR_LOADFROMFILE = 0x10_u32

      TPM_RIGHTBUTTON = 0x02_u32
      TPM_NONOTIFY    = 0x80_u32
      TPM_RETURNCMD   = 0x100_u32

      MIIM_STATE   = 0x01_u32
      MIIM_ID      = 0x02_u32
      MIIM_SUBMENU = 0x04_u32
      MIIM_STRING  = 0x40_u32
      MIIM_FTYPE   = 0x100_u32

      MFT_SEPARATOR = 0x800_u32
      MFS_DISABLED  = 0x03_u32
      MFS_CHECKED   = 0x08_u32

      @mutex = Thread::Mutex.new
      @items = Hash(Int32, Egui::SystemPorts::Tray::TrayItem).new
      @icon : Void* = Pointer(Void).null       # HICON (owned; DestroyIcon)
      @tooltip = ""
      @hwnd : Void* = Pointer(Void).null       # the tray thread's window
      @added = false                            # NIM_ADD succeeded
      @started = false                          # create() ran, thread live
      @thread_id : UInt32 = 0
      # Menu-build scratch (tray thread only, inside show_menu):
      @root_menu : Void* = Pointer(Void).null
      @submenus = Hash(Int32, Void*).new        # parent id → its submenu
      @click_map = Hash(UInt32, Int32).new      # menu command → item id
      @next_cmd : UInt32 = 1

      @@instance : WindowsTray? = nil
      @@class_registered = false
      @@taskbar_created : UInt32 = 0            # RegisterWindowMessage id
      @@gdiplus_token : UInt64 = 0
      @@wnd_proc : LibTrayUser32::WndProcT = ->(hwnd : Void*, msg : UInt32,
        w_param : UInt64, l_param : Int64) {
        handled = @@instance.try(&.wnd_proc(hwnd, msg, w_param, l_param))
        handled ? 0_i64 : LibTrayUser32.def_window_proc(hwnd, msg, w_param, l_param)
      }

      def supported? : Bool
        true
      end

      def create(icon : Egui::SystemPorts::Tray::IconSource?,
                 title : String?, tooltip : String?) : Nil
        return if @started
        @started = true
        @@instance = self
        startup_gdiplus
        if icon
          h = hicon_from(icon)
          @mutex.synchronize { @icon = h } if h
        end
        @mutex.synchronize { @tooltip = tooltip || "" }
        # The hidden window + GetMessage loop live on the tray thread
        # (window messages belong to the creating thread; see the file
        # comment). Thread.new GC-registers the thread for us.
        Thread.new do
          @thread_id = LibTrayKernel32.get_current_thread_id
          tray_thread_main
        end
      end

      def set_icon(icon : Egui::SystemPorts::Tray::IconSource) : Nil
        h = hicon_from(icon)
        return unless h
        old = Pointer(Void).null
        @mutex.synchronize do
          old = @icon
          @icon = h
          sync_icon_locked if @added
        end
        LibTrayUser32.destroy_icon(old) unless old.null?
      end

      def set_title(title : String) : Nil
        # The Windows tray shows no label next to the icon (port doc).
      end

      def set_tooltip(tooltip : String) : Nil
        @mutex.synchronize do
          @tooltip = tooltip
          sync_icon_locked if @added
        end
      end

      def add_item(item : Egui::SystemPorts::Tray::TrayItem) : Nil
        return if item.separator?
        @mutex.synchronize { @items[item.id] = item.dup }
      end

      def add_separator(id : Int32) : Nil
        sep = Egui::SystemPorts::Tray::TrayItem.new(id: id, title: "-")
        @mutex.synchronize { @items[id] = sep }
      end

      def remove_item(id : Int32) : Nil
        @mutex.synchronize { @items.delete(id) }
      end

      def show_item(id : Int32) : Nil
        @mutex.synchronize { @items[id]?.try { |i| i.hidden = false } }
      end

      def hide_item(id : Int32) : Nil
        @mutex.synchronize { @items[id]?.try { |i| i.hidden = true } }
      end

      def show : Nil
        @mutex.synchronize { add_locked }
      end

      def hide : Nil
        @mutex.synchronize do
          return unless @added
          d = notify_data(0)
          LibTrayShell32.shell_notify_icon(LibTrayShell32::NIM_DELETE,
            pointerof(d))
          @added = false
        end
      end

      def quit : Nil
        @mutex.synchronize do
          return unless @started
          if @added
            d = notify_data(0)
            LibTrayShell32.shell_notify_icon(LibTrayShell32::NIM_DELETE,
              pointerof(d))
            @added = false
          end
        end
        # End the tray thread's GetMessage loop; it destroys its own
        # window on the way out (DestroyWindow is thread-affine). A
        # quit before the thread set its id fails silently — the icon
        # dies with the process either way.
        tid = @thread_id
        if tid != 0
          LibTrayKernel32.post_thread_message(tid, WM_QUIT, 0_u64, 0_i64)
        end
        @started = false
      end

      # --- tray thread ---------------------------------------------------

      private def tray_thread_main : Nil
        register_window_class
        @@taskbar_created = LibTrayUser32.register_window_message(
          "TaskbarCreated".to_utf16) if @@taskbar_created == 0

        hinstance = LibTrayKernel32.get_module_handle(nil)
        # A plain hidden window, NOT HWND_MESSAGE: message-only windows
        # don't receive broadcasts, and the explorer-restart re-add
        # needs the TaskbarCreated broadcast.
        hwnd = LibTrayUser32.create_window_ex(0, TRAY_CLASS_NAME.to_utf16,
          "egui-cr tray".to_utf16, 0, 0, 0, 0, 0, nil, nil, hinstance, nil)
        return if hwnd.null?
        @mutex.synchronize { @hwnd = hwnd }

        add_locked

        msg = LibTrayUser32::Msg.new
        while LibTrayUser32.get_message(pointerof(msg), nil, 0, 0) > 0
          LibTrayUser32.translate_message(pointerof(msg))
          LibTrayUser32.dispatch_message(pointerof(msg))
        end

        @mutex.synchronize do
          LibTrayUser32.destroy_window(@hwnd) unless @hwnd.null?
          @hwnd = Pointer(Void).null
          @added = false
        end
      end

      private def register_window_class : Nil
        return if @@class_registered
        @@class_registered = true
        wc = LibTrayUser32::WndClassExW.new
        wc.cb_size = sizeof(LibTrayUser32::WndClassExW).to_u32
        wc.wnd_proc = @@wnd_proc
        wc.h_instance = LibTrayKernel32.get_module_handle(nil)
        wc.class_name = TRAY_CLASS_NAME.to_utf16.to_unsafe
        LibTrayUser32.register_class_ex(pointerof(wc))
      end

      # Static WndProc → instance. Returns true when handled.
      protected def wnd_proc(hwnd : Void*, msg : UInt32, w_param : UInt64,
                             l_param : Int64) : Bool
        if msg == CALLBACK_MSG
          # V0 callback: lParam's low word is the mouse message. Any
          # click on the icon opens the menu — the port has no
          # default-item concept, and this matches the macOS adapter's
          # behavior (every click opens the NSMenu).
          case (l_param & 0xFFFF).to_u32
          when WM_LBUTTONUP, WM_RBUTTONUP
            show_menu(hwnd)
          end
          return true
        end
        if @@taskbar_created != 0 && msg == @@taskbar_created
          # Explorer restarted — re-add the icon.
          @mutex.synchronize do
            @added = false
            add_locked
          end
          return true
        end
        false
      end

      # Snapshot the model → HMENU → KB135788 dance → TPM_RETURNCMD
      # selection → enqueue. Runs on the tray thread.
      private def show_menu(hwnd : Void*) : Nil
        items = @mutex.synchronize { @items.values }
        @submenus.clear
        @click_map.clear
        @next_cmd = 1
        @root_menu = LibTrayUser32.create_popup_menu
        return if @root_menu.null?
        items.each do |item|
          next if item.hidden
          place(item, items)
        end

        pt = LibTrayUser32::Point.new
        LibTrayUser32.get_cursor_pos(pointerof(pt))
        LibTrayUser32.set_foreground_window(hwnd)
        cmd = LibTrayUser32.track_popup_menu(@root_menu,
          TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
          pt.x, pt.y, 0, hwnd, nil)
        # KB135788: without the WM_NULL the menu stays open on an
        # outside click.
        LibTrayUser32.post_message(hwnd, WM_NULL, 0_u64, 0_i64)
        LibTrayUser32.destroy_menu(@root_menu)
        @root_menu = Pointer(Void).null

        return if cmd == 0
        id = @click_map[cmd.to_u32]?
        return unless id
        # Keep the model's checked state in sync (the HMENU dies here).
        @mutex.synchronize do
          if (item = @items[id]?) && item.checkable
            item.checked = !item.checked
          end
        end
        Egui::SystemPorts::Tray.enqueue_click(id)
      end

      # One item into whatever container its parent_id selects; `sub`
      # is the submenu to attach when this item is itself a parent.
      private def place(item : Egui::SystemPorts::Tray::TrayItem,
                        items : Array(Egui::SystemPorts::Tray::TrayItem),
                        sub : Void* = Pointer(Void).null) : Nil
        target = submenu_of(item.parent_id, items)
        return if target.null?
        if item.separator?
          mii = LibTrayUser32::MenuitemInfoW.new
          mii.cb_size = sizeof(LibTrayUser32::MenuitemInfoW).to_u32
          mii.f_mask = MIIM_FTYPE
          mii.f_type = MFT_SEPARATOR
          LibTrayUser32.insert_menu_item(target,
            LibTrayUser32.get_menu_item_count(target).to_u32, 1, pointerof(mii))
          return
        end
        cmd = @next_cmd
        @next_cmd += 1
        @click_map[cmd] = item.id

        mii = LibTrayUser32::MenuitemInfoW.new
        mii.cb_size = sizeof(LibTrayUser32::MenuitemInfoW).to_u32
        mii.f_mask = MIIM_STRING | MIIM_ID | MIIM_STATE
        unless sub.null?
          mii.f_mask |= MIIM_SUBMENU
          mii.h_submenu = sub
        end
        mii.f_type = 0 # MFT_STRING
        mii.f_state = 0
        mii.f_state |= MFS_CHECKED if item.checkable && item.checked
        mii.f_state |= MFS_DISABLED if item.disabled
        mii.w_id = cmd
        mii.cch = item.title.size.to_u32
        mii.dw_type_data = item.title.to_utf16.to_unsafe
        LibTrayUser32.insert_menu_item(target,
          LibTrayUser32.get_menu_item_count(target).to_u32, 1, pointerof(mii))
      end

      # The menu container for children of `id` — the parent item is
      # created on demand (parents may be added after their children).
      private def submenu_of(id : Int32,
                             items : Array(Egui::SystemPorts::Tray::TrayItem)) : Void*
        return @root_menu if id <= 0
        if (sub = @submenus[id]?)
          return sub
        end
        parent = items.find(&.id.==(id))
        return @root_menu unless parent # dangling parent_id → root
        sub = LibTrayUser32.create_popup_menu
        @submenus[id] = sub
        place(parent, items, sub)
        sub
      end

      # --- shell icon state ---------------------------------------------

      private def notify_data(flags : UInt32) : LibTrayShell32::NotifyIconDataW
        d = LibTrayShell32::NotifyIconDataW.new
        d.cb_size = sizeof(LibTrayShell32::NotifyIconDataW).to_u32
        d.hwnd = @hwnd
        d.uid = 1
        d.u_flags = flags
        d.callback_message = CALLBACK_MSG
        d.h_icon = @icon
        copy_wstr(d.tip.to_unsafe, 128, @tooltip)
        d
      end

      # NIM_MODIFY with the current icon + tooltip (caller holds @mutex).
      private def sync_icon_locked : Nil
        return unless @added && !@hwnd.null?
        d = notify_data(NIF_ICON | NIF_TIP)
        LibTrayShell32.shell_notify_icon(LibTrayShell32::NIM_MODIFY,
          pointerof(d))
      end

      # NIM_ADD (caller holds @mutex).
      private def add_locked : Nil
        return if @added || @hwnd.null?
        d = notify_data(NIF_MESSAGE | NIF_ICON | NIF_TIP)
        @added = LibTrayShell32.shell_notify_icon(LibTrayShell32::NIM_ADD,
          pointerof(d)) != 0
      end

      private def copy_wstr(dst : UInt16*, cap : Int32, s : String) : Nil
        return if cap <= 0
        chars = s.to_utf16
        i = 0
        while i < chars.size && i < cap - 1
          dst[i] = chars[i]
          i += 1
        end
        dst[i] = 0
      end

      # --- HICON ---------------------------------------------------------

      private def hicon_from(icon : Egui::SystemPorts::Tray::IconSource) : Void*
        if icon.ico?
          # GDI+ has no ICO decoder — a temp .ico file + LoadImageW
          # handles multi-size icons natively.
          hicon_from_ico(icon.bytes)
        else
          # PNG/JPEG through the backend codec; SVG through the
          # NanoSvgCr fallback (ImageCodec.decode answers both).
          frame = Egui::ImageCodec.decode(icon.bytes)
          return Pointer(Void).null unless frame
          hicon_from_rgba(frame.rgba, frame.width, frame.height)
        end
      end

      # Straight-alpha RGBA8 → GDI+ ARGB32 bitmap → HICON. GDI+ calls
      # are thread-agnostic, so this runs on the caller's thread.
      private def hicon_from_rgba(rgba : Bytes, w : Int32, h : Int32) : Void*
        null = Pointer(Void).null
        return null unless w > 0 && h > 0 && rgba.size >= w * h * 4
        bitmap = Pointer(Void).null
        rc = LibTrayGdiplus.create_bitmap_from_scan0(w, h, w * 4,
          LibTrayGdiplus::PIXEL_FORMAT_32BPP_ARGB, rgba, pointerof(bitmap))
        return null if rc != 0 || bitmap.null?
        hicon = Pointer(Void).null
        rc = LibTrayGdiplus.create_hicon_from_bitmap(bitmap, pointerof(hicon))
        LibTrayGdiplus.dispose_image(bitmap)
        hicon
      end

      private def hicon_from_ico(bytes : Bytes) : Void*
        path = write_temp_ico(bytes)
        return Pointer(Void).null unless path
        hicon = LibTrayUser32.load_image(nil, path.to_utf16, IMAGE_ICON,
          0, 0, LR_LOADFROMFILE)
        File.delete(path) rescue nil
        hicon
      end

      private def write_temp_ico(bytes : Bytes) : String?
        tmp = Slice(UInt16).new(1024)
        n = LibTrayKernel32.get_temp_path(1024, tmp.to_unsafe)
        return nil if n == 0 || n >= 1024
        dir = String.from_utf16(tmp[0, n])
        path = "#{dir}egui_tray_#{Random::Secure.hex(8)}.ico"
        begin
          File.write(path, bytes)
        rescue
          return nil
        end
        path
      end

      private def startup_gdiplus : Nil
        return if @@gdiplus_token != 0
        input = LibTrayGdiplus::StartupInput.new
        input.version = 1
        token = 0_u64
        LibTrayGdiplus.startup(pointerof(token), pointerof(input), nil)
        @@gdiplus_token = token
      end
    end
  end
end

{% end %}
