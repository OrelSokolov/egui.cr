# Mobile gallery — every widget from plans/todo/mobile_widgets.md in
# one screen: bottom navigation (Controls / Lists / Sheets / Extras),
# an app bar on top, a FAB bottom-right, and the overlay presenters
# (Dialog, BottomSheet, Snackbar) on demand. The app draws
# edge-to-edge on the ROOT surface via ctx.central_panel — no nested
# window chrome: a mobile app is the screen, not a window in a window.

{% unless env("EGUI_EMBEDDED") %}require "../src/egui/driver_selector"{% end %}

class MobileGalleryApp < Egui::App
  @tab = 0
  # --- Controls tab state -------------------------------------------
  @wifi = true
  @dnd = false
  @volume = 6.0_f64
  @brightness = 40.0_f64
  @chips = [
    Egui::Chip.new("Wi-Fi 6", icon: :wifi, selected: true),
    Egui::Chip.new("Bluetooth", icon: :bluetooth),
    Egui::Chip.new("Roaming"),
    Egui::Chip.new("Guest net", closable: true),
  ]
  @rating = 4.0_f64
  @price_lo = 20.0_f64
  @price_hi = 80.0_f64

  # --- Lists tab state ----------------------------------------------
  @query = ""
  @inbox : Int32? = nil

  # --- Sheets/Extras tab state --------------------------------------
  @page = 0
  @code = ""
  @refreshing = false
  @refresh_ticks = 0
  @snack : String? = nil
  @snack_action : String? = nil
  @dialog : Egui::Dialog? = nil
  @sheet_open = false
  @sheet = Egui::BottomSheet.new(id: "gallery_sheet")

  # FAB click → toast; the toast auto-hides after ~2s (app-side timer
  # — the Snackbar widget itself is stateless).
  @snack_shown_at = -1.0_f64

  def update(ctx : Egui::Context) : Nil
    # Auto-hide the toast after 2s of input time.
    if @snack && @snack_shown_at >= 0.0 &&
       ctx.input.time - @snack_shown_at > 2.0
      @snack = nil
      @snack_action = nil
    end
    # Fake refresh spin for the PullToRefresh demo: hold the indicator
    # for ~1s, then swap in fresh data.
    if @refreshing
      @refresh_ticks += 1
      @refreshing = false if @refresh_ticks > 60
    end

    # Context-level presenters run over the whole screen, above all
    # windows — before the window content so a frame they close on
    # doesn't re-open behind the scrim.
    if (dlg = @dialog)
      result = dlg.show(ctx)
      if result
        @snack = result == Egui::Dialog::SCRIM ? nil : "dialog: #{result}"
        @snack_shown_at = ctx.input.time
        @dialog = nil
      end
    end
    if @sheet_open
      closed = @sheet.show(ctx) do |body|
        body.label("Bottom sheet: drag handle on top, tap the " \
          "scrim to dismiss. v1 snaps (no drag-to-dismiss yet).")
        body.separator
        body.list_tile("Sheet item A", leading_icon: :download)
        body.list_tile("Sheet item B", leading_icon: :copy)
      end
      @sheet_open = false if closed
    end

    # The whole app IS the screen: a mobile app draws edge-to-edge on
    # the root surface — no nested window chrome (an embedded-window
    # look would be wrong here; central_panel fills available_rect).
    # `scroll: false` keeps the scaffold pinned (app bar / bottom nav
    # / FAB / toast anchor to the screen, not to scroll content — a
    # scrolling central panel puts max_rect in content coordinates and
    # the nav rides the scroll); only the tab body scrolls.
    ctx.central_panel(scroll: false) do |ui|
      # Top app bar (back + title + one action) above the body.
      ui.app_bar("Mobile gallery", back: true, id: "bar",
        on_back: ->{ @snack = "back tapped"; @snack_shown_at = ctx.input.time }
      ) do |bar|
        bar.action(:copy) { @sheet_open = true }
      end

      # The body is the only scrolling part (HTML `overflow-y: auto`
      # on the content between the fixed bars). BottomNav pins itself
      # to the region bottom and its slot must be cut out of the
      # body's height HERE — `available_height` still reaches the
      # region bottom, so a plain scroll_area would run the content
      # 80px UNDER the pinned bar (and the old `allocate_space(80)`
      # reserve only shifted the viewport's top, not its bottom — the
      # slot was double-counted as an empty strip).
      nav_h = 80.0 # BottomNav ROOT height default
      body_h = {ui.available_height - nav_h, 1.0}.max
      ui.scroll_area(max_height: body_h) do
        case @tab
        when 0 then controls_tab(ui)
        when 1 then lists_tab(ui)
        when 2 then sheets_tab(ui, ctx)
        else        extras_tab(ui)
        end
      end

      # FAB pinned bottom-right — declared AFTER the body: paint
      # order is command order, so cards/tiles can never cover the
      # circle.
      ui.overlay(:bottom_right,
        margin: Egui::StyleBox.new(bottom: 104.0, right: 16.0),
        id: "fab_spot", pass_through: true) do |o|
        o.fab(:plus, id: "fab") do
          @snack = "new item"
          @snack_action = "UNDO"
          @snack_shown_at = ctx.input.time
        end
      end

      ui.bottom_nav(NAV_ITEMS, @tab, id: "nav") { |i| @tab = i }

      # The toast itself (pinned to the screen, above the nav bar).
      if (text = @snack)
        ui.snackbar("gallery_toast", text, true,
          action_text: @snack_action, lift: 88.0) do
          @snack = nil
          @snack_action = nil
        end
      end
    end
  end

  NAV_ITEMS = [
    Egui::BottomNav::Item.new(:check, "Controls"),
    Egui::BottomNav::Item.new(:copy, "Lists"),
    Egui::BottomNav::Item.new(:up, "Sheets"),
    Egui::BottomNav::Item.new(:monitor, "Extras"),
  ]

  # --- Tab 0: switches, stepper, chips, rating, range ---------------
  private def controls_tab(ui : Egui::Ui) : Nil
    ui.card(id: "quick_settings") do |c|
      c.heading("Quick settings")
      c.list_tile("Wi-Fi", subtitle: @wifi ? "home-5G" : "off",
        leading_icon: :wifi, id: "row_wifi") do |row|
        row.switch(@wifi, id: "sw_wifi") { |v| @wifi = v }
      end
      c.list_tile("Do not disturb", leading_icon: :close, id: "row_dnd") do |row|
        row.switch(@dnd, id: "sw_dnd") { |v| @dnd = v }
      end
    end

    ui.separator
    ui.horizontal do |h|
      h.label("Volume")
      h.stepper(@volume, range: (0.0..10.0), step: 1.0, id: "step_vol") do |v|
        @volume = v
      end
    end

    ui.label("Filters")
    responses = ui.chip_row(@chips)
    responses.each_with_index do |r, i|
      chip = @chips[i]
      chip.selected = !chip.selected if chip.selected.nil? == false && r.changed?
    end

    ui.label("Rate this build")
    ui.rating_bar(@rating, count: 5, step: 0.5, id: "rating") do |v|
      @rating = v
    end

    ui.label("Price range: #{@price_lo.round} — #{@price_hi.round} ₽")
    ui.range_slider(@price_lo, @price_hi, 0.0..100.0, id: "price") do |lo, hi|
      @price_lo = lo
      @price_hi = hi
    end
  end

  # --- Tab 1: search + list tiles + avatars + swipe actions ---------
  private def lists_tab(ui : Egui::Ui) : Nil
    ui.search_bar(@query, "Search contacts", id: "search") do |s|
      @query = s
    end

    ui.swipe_item(id: "swipe_row",
      actions: [
        Egui::SwipeItem::Action.new("Delete", Egui::Color32.rgb(220, 60, 60)),
      ],
      on_dismiss: ->{ @snack = "row deleted"; @snack_shown_at = 0.0; nil }) do |row|
      row.list_tile("Alex Chen", subtitle: "swipe me left",
        leading_icon: :bluetooth, id: "row_swipe")
    end

    {"Maria Ivanova", "John Okafor", "Yuki Tanaka"}.each_with_index do |name, i|
      next if !@query.empty? && !name.downcase.includes?(@query.downcase)
      ui.horizontal do |h|
        r = h.avatar(name, size: 40.0, id: "avatar#{i}")
        h.badge(i + 1, on: r.rect, id: "badge#{i}") unless i == 2
        h.list_tile(name, subtitle: i == 0 ? "online" : "last seen 2h ago",
          id: "row#{i}")
      end
    end
  end

  # --- Tab 2: dialog, bottom sheet, pull-to-refresh, pager ----------
  private def sheets_tab(ui : Egui::Ui, ctx : Egui::Context) : Nil
    if ui.button("Show AlertDialog").clicked?
      @dialog = Egui::Dialog.new("Delete download?",
        "This file will be removed from the device.",
        ["CANCEL", "DELETE"], id: "demo_dialog")
    end
    ui.label("last: #{@last_dialog_result || "—"}")

    if ui.button("Open bottom sheet").clicked?
      @sheet_open = true
    end

    ui.separator
    ui.label("Pull the strip below (simulated)")
    ui.pull_to_refresh(@refreshing, id: "ptr", label: "Refreshing…")
    if ui.button("Start refresh").clicked?
      @refreshing = true
      @refresh_ticks = 0
    end

    ui.separator
    ui.pager(3, @page, id: "pager", height: 120.0,
      on_change: ->(i : Int32){ @page = i }) do |p, i|
      p.label("page #{i} — swipe horizontally")
    end
    ui.page_indicator(3, @page, id: "dots")
  end

  @last_dialog_result : String? = nil

  # --- Tab 3: pin, skeleton, progress, tooltip, safe area -----------
  private def extras_tab(ui : Egui::Ui) : Nil
    ui.label("Enter the code")
    ui.pin_input(@code, count: 4, id: "pin") do |text, filled|
      @code = text
      @snack = "code complete!" if filled
      @snack_shown_at = -1.0 unless filled
    end

    ui.horizontal do |h|
      h.circular_progress(0.42, text: "42%", id: "cp")
      h.label("  download")
    end

    ui.label("Skeleton (loading list)")
    ui.skeleton_list(3, id: "skel")

    ui.tooltip("tt", "This is a tooltip") do |b|
      b.button("Hover / long-press me")
    end

    ui.safe_area(top: 8.0, bottom: 8.0, left: 12.0, right: 12.0,
      id: "safe_demo") do |sa|
      sa.label("↳ padded by SafeArea (insets from a future device port)")
    end
  end
end

{% unless env("EGUI_EMBEDDED") %}
Egui.run(MobileGalleryApp.new, title: "egui-cr — mobile gallery",
  inspector: :hidden)
{% end %}
