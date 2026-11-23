# Mobile gallery, the EXML edition — the same catalog as
# examples/mobile_gallery.cr, but the whole UI is markup
# (assets/mobile_gallery.exml) through the mobile vocabulary of
# src/egui/exml_mobile.cr. The app is the store + actions: per-frame
# `sync` publishes computed slots, actions mutate them; the two
# ctx-level presenters (Dialog, BottomSheet) stay app-side (not tags).
{% unless env("EGUI_EMBEDDED") %}
require "../src/egui/driver_selector"
{% end %}
require "../src/egui/exml_mobile"
require "./mobile_components/mobile_gallery_gen"

class MobileGalleryExmlApp < Egui::App
  @exml = Egui::Exml::Document.hybrid("assets/mobile_gallery.exml")
  @rt = Egui::Exml::Runtime.new
  @renderer = Egui::Exml::Renderer.new

  # App-side presenter state (not tags — see exml_mobile.cr header).
  @dialog : Egui::Dialog? = nil
  @sheet = Egui::BottomSheet.new(id: "gallery_sheet")
  @sheet_open = false
  @refresh_ticks = 0
  @snack_at = -1.0_f64
  # Actions fire during render (no ctx in the closure) — the snack they
  # request lands right after render_routes stamps the timestamp.
  @pending_snack : {String, String?}? = nil
  @actions_registered = false

  # The store — specs drive actions and assert slots directly (the
  # music_exml_live_spec contract).
  getter rt : Egui::Exml::Runtime

  def update(ctx : Egui::Context) : Nil
    register_actions_once
    @exml.reload_if_changed
    sync(ctx)

    # Presenters ride over everything (ctx-level, like the raw app).
    if (dlg = @dialog)
      result = dlg.show(ctx)
      if result
        clear_snack if result == Egui::Dialog::SCRIM
        @rt.strings["last_result"] = result
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

    @renderer.render_routes(ctx, @exml, @rt)

    # Actions ran during the render — flush their snack request now,
    # with the frame's clock.
    if (snack = @pending_snack)
      @pending_snack = nil
      set_snack(ctx, snack[0], snack[1])
    end
  end

  # Store slots the markup reads but the widgets don't write.
  private def sync(ctx : Egui::Context) : Nil
    tab = @rt.float("tab").to_i
    4.times { |i| @rt.bools["tab#{i}"] = i == tab }
    @rt.strings["wifi_sub"] = @rt.bool("wifi") ? "home-5G" : "off"
    @rt.strings["price_lo_s"] = @rt.float("price_lo").round.to_s
    @rt.strings["price_hi_s"] = @rt.float("price_hi").round.to_s
    # Fake refresh spin: hold ~1s of frames, then swap in fresh data.
    if @rt.bool("spin") && (@refresh_ticks += 1) > 60
      @rt.bools["spin"] = false
      @refresh_ticks = 0
      set_snack(ctx, "refreshed!")
    end
    # Toast auto-hide after 2s (the Snackbar widget is stateless).
    if @rt.bool("snack_on") && @snack_at >= 0.0 &&
       ctx.input.time - @snack_at > 2.0
      clear_snack
    end
  end

  private def set_snack(ctx : Egui::Context, text : String,
                        action : String? = nil) : Nil
    @rt.strings["snack_text"] = text
    @rt.strings["snack_action"] = action || ""
    @rt.bools["snack_on"] = true
    @snack_at = ctx.input.time
  end

  private def clear_snack : Nil
    @rt.bools["snack_on"] = false
    @rt.strings["snack_action"] = ""
    @snack_at = -1.0_f64
  end

  # The store seeds: every slot the markup reads must exist from the
  # first frame (an unresolved {placeholder} renders literally — the
  # interpolation now warns-once to stderr about such misses).
  private def init_store(rt : Egui::Exml::Runtime) : Nil
    rt.floats["tab"] = 0.0
    rt.floats["volume"] = 6.0
    rt.floats["rating"] = 4.0
    rt.floats["price_lo"] = 20.0
    rt.floats["price_hi"] = 80.0
    rt.floats["page"] = 0.0
    rt.strings["query"] = ""
    rt.strings["code"] = ""
    rt.strings["snack_text"] = ""
    rt.strings["snack_action"] = ""
    rt.strings["last_result"] = "—"
    rt.bools["snack_on"] = false
    rt.bools["spin"] = false
    rt.bools["wifi"] = true
    rt.bools["dnd"] = false
    rt.bools["sel_c1"] = true
    rt.bools["sel_c2"] = false
    rt.bools["sel_c3"] = false
    rt.bools["sel_c4"] = false
  end

  private def register_actions_once : Nil
    return if @actions_registered
    @actions_registered = true
    init_store(@rt)
    rt = @rt
    rt.actions["go_back"] = ->{ @pending_snack = {"back tapped", nil} }
    rt.actions["open_sheet"] = ->{ @sheet_open = true }
    rt.actions["new_item"] = ->{ @pending_snack = {"new item", "UNDO"} }
    rt.actions["snack_clear"] = ->{ clear_snack }
    rt.actions["show_dialog"] = ->{
      @dialog = Egui::Dialog.new("Delete download?",
        "This file will be removed from the device.",
        ["CANCEL", "DELETE"], id: "demo_dialog")
    }
    rt.actions["start_refresh"] = ->{
      @rt.bools["spin"] = true
      @refresh_ticks = 0
    }
    rt.actions["row_deleted"] = ->{ @pending_snack = {"row deleted", nil} }
    rt.actions["chip_closed"] = ->{ @pending_snack = {"chip closed", nil} }
    rt.actions["code_done"] = ->{ @pending_snack = {"code complete!", nil} }
  end
end

{% unless env("EGUI_EMBEDDED") %}
Egui.run(MobileGalleryExmlApp.new, title: "egui-cr — mobile gallery (exml)",
  inspector: :hidden)
{% end %}
