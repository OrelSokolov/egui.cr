# egui-cr demo: the icon providers (`icons/lucide`, ISC + 
# `icons/bootstrap`, MIT) as a searchable catalog filling the whole
# window — a radio pair switches the provider.
#
# `Egui::Icon.from_file(provider, name)` needs the provider and name
# as LITERALS at the call site — the macro reads the SVG file at
# compile time. A catalog can't hand-write ~4000 calls, so it
# enumerates the provider folders at compile time instead (`ls` +
# `read_file` in ICONS_LUCIDE / ICONS_BOOTSTRAP below) and calls the
# runtime half, `Icon.cached`, on the embedded sources: the same
# compile-time embedding, driven by the directory listing. Clicking an
# icon selects it — the preview panel on the right shows it large,
# with its names, the `Icon.from_file` usage line, and copy buttons.
# Right-clicking a cell opens a context menu: open the SVG in its
# default OS app (FileOpen system port, xdg-open / open / explorer)
# or copy the name (underscore form, `:arrow_up`) to the clipboard.
#
# Perf: only rows intersecting the scroll viewport are built. The
# sokol_gl backend has finite per-frame vertex/command budgets
# (silently dropping draws past them), so painting all ~1850 icons at
# once both tanks the frame rate and loses geometry — watch Debug →
# Show FPS while scrolling.

require "../src/egui"
require "../src/egui/backend/sokol"

class LucideIconsApp < Egui::App
  # Catalog cell: a large icon-only button (the icon box is
  # font_size * Fonts::LINE_H_FACTOR ≈ 62 px) with the icon name as a
  # single-line ellipsized caption. Fixed cell heights keep every row
  # the same size — the viewport culling below advances skipped rows
  # by a constant stride and relies on rendered rows matching it.
  CELL_W = 156.0
  BUTTON_H = 88.0
  ICON_FONT = 48.0
  CAPTION_FONT = 15.0

  # {dashed-name, svg-source} per icon, alphabetical — both sets
  # embedded at compile time, so search covers every icon on disk.
  # (The macro language has no Dir/File, so the provider folder is
  # listed with a compile-time shell command. NB macro backticks run
  # NO shell: on Windows the listing must go through `cmd /c dir /b`
  # — dir is a cmd builtin, and there is no ls — with literal
  # backslashes doubled against macro-string unescaping; Unix keeps
  # `ls -1`. `read_file` embeds each SVG.) The folders themselves are
  # kept too: the context menu opens the icon's file on disk through
  # the FileOpen system port (xdg-open / open / explorer).
  ICONS_LUCIDE = {{ begin
    files = flag?(:windows) ? `cmd /c dir /b "#{__DIR__}\\..\\icons\\lucide\\*.svg"`.gsub(/\r/, "") : `ls -1 #{__DIR__}/../icons/lucide/*.svg`
    files.split("\n").select { |f| f.size > 0 }.sort.map do |f|
      name = f.split(/[\\\/]/)[-1].split(".")[0]
      {name, read_file("#{__DIR__}/../icons/lucide/#{name.id}.svg")}
    end
  end }}
  ICONS_BOOTSTRAP = {{ begin
    files = flag?(:windows) ? `cmd /c dir /b "#{__DIR__}\\..\\icons\\bootstrap\\*.svg"`.gsub(/\r/, "") : `ls -1 #{__DIR__}/../icons/bootstrap/*.svg`
    files.split("\n").select { |f| f.size > 0 }.sort.map do |f|
      name = f.split(/[\\\/]/)[-1].split(".")[0]
      {name, read_file("#{__DIR__}/../icons/bootstrap/#{name.id}.svg")}
    end
  end }}
  PROVIDERS = {"lucide" => ICONS_LUCIDE, "bootstrap" => ICONS_BOOTSTRAP}
  DIRS = {"lucide" => {{ __DIR__ + "/../icons/lucide" }},
          "bootstrap" => {{ __DIR__ + "/../icons/bootstrap" }}}

  # Ctrl+F lands focus on the search field (see @focus_search below).
  ACTION_FOCUS_SEARCH = Egui::HotkeyAction.new("lucide.focus_search")

  @query = ""
  @show_fps = true
  @fps = 0.0
  @hotkeys_ready = false
  @focus_search = false
  # Active provider ("lucide" / "bootstrap").
  @provider = "lucide"
  # {provider, dashed-name, svg-source} of the icon in the preview.
  @selected : Tuple(String, String, String)? = nil

  def update(ctx : Egui::Context) : Nil
    # FPS meter: EMA over the begin-frame interval (the frame rate
    # the user perceives; when the CPU can't keep up it sinks below
    # vsync). request_repaint keeps frames coming while shown — an
    # idle app would otherwise freeze the meter at its last reading.
    if (dt = ctx.input.dt) > 0.0
      target = 1.0 / dt
      @fps = @fps > 0.0 ? @fps + (target - @fps) * 0.15 : target
    end
    ctx.request_repaint if @show_fps

    # Default hotkey bindings — once, on the first frame.
    unless @hotkeys_ready
      ctx.hotkeys.bind("Ctrl+F", ACTION_FOCUS_SEARCH)
      @hotkeys_ready = true
    end
    # The action fires before the field is built below; requesting
    # focus on the response takes effect on the next frame's pass
    # through the widget, so keep the app painting until then.
    if ctx.consume_action(ACTION_FOCUS_SEARCH)
      @focus_search = true
      ctx.request_repaint
    end

    ctx.menu_bar do |bar|
      bar.menu_button("Debug") do |menu|
        menu.menu_item("#{@show_fps ? "✓ " : ""}Show FPS") do
          @show_fps = !@show_fps
        end
      end
    end

    # Preview panel: the icon selected in the catalog, shown large
    # (see #preview).
    ctx.side_panel(:right, "preview", width: 300.0) do |ui|
      preview(ui)
    end

    ctx.central_panel do |ui|
      fg = ui.style.visuals.text_color
      icons = PROVIDERS[@provider]
      # `arrow up` / `arrow_up` both match `arrow-up.svg`.
      q = @query.downcase.gsub(/[\s_]+/, "-")
      matches = q.empty? ? icons : icons.select { |name, _| name.includes?(q) }

      ui.horizontal do |row|
        # Provider switch — bootstrap is a separate catalog, so the
        # query and the selection stay per-provider coherent.
        PROVIDERS.each_key do |p|
          row.radio(@provider == p, p).clicked do
            @provider = p
            # The preview shows a different catalog — drop a stale
            # selection from the previous provider.
            if (sel = @selected) && sel[0] != p
              @selected = nil
            end
          end
        end
        # NB: no `row.separator` here — in a horizontal layout
        # Separator allocates the full remaining height as its size,
        # blowing up the row (search field ends up mid-screen, the
        # grid below the fold).
        row.add(Egui::Button.new("")
          .icon(Egui::Icon.from_file(:lucide, :search, tint: fg)))
        search = row.text_edit_singleline(@query, hint: "search #{icons.size} #{@provider} icons…",
          focus_id: "lucide-search") { |t| @query = t }
        search.request_focus if @focus_search
        @focus_search = false
        row.label("#{matches.size}/#{icons.size}")
      end
      ui.separator

      ui.scroll_area do |scroll|
        if matches.empty?
          scroll.label("no icons match #{@query.inspect}")
          next
        end
        gap = scroll.style.spacing.item_spacing.y
        row_h = BUTTON_H + gap + CAPTION_FONT * Egui::Fonts::LINE_H_FACTOR
        clip = scroll.painter.clip
        n = {(scroll.available_width / CELL_W).floor.to_i, 1}.max
        # LUCIDE_NO_CULL=1: paint every row — the worst case for the
        # backend's vertex/command budgets and the Svg raster-texture
        # pool (the whole active catalog, ~2000 icons, baked live).
        # Stress mode, not a mode you ever want to ship.
        no_cull = ENV["LUCIDE_NO_CULL"]? == "1"
        matches.each_slice(n) do |slice|
          y = scroll.cursor.y
          # Viewport culling: rows fully outside the clip (one row of
          # slack for kinetic overshoot) only advance the cursor — no
          # widgets, no paint commands, no tessellation.
          if !no_cull &&
             (y + row_h < clip.min.y - row_h || y - row_h > clip.max.y)
            scroll.allocate_space(Egui::Vec2.new(0.0, row_h))
          else
            scroll.columns(n) do |cols|
              cols.each_with_index do |col, i|
                next unless (icon = slice[i]?)
                name, source = icon
                # Button: centered in the cell — a vertical column
                # places every widget at its left edge and the button
                # only takes its natural width (glyph box + padding),
                # so shift the column cursor to the cell's horizontal
                # center for the add and restore it after (top_down
                # keeps cursor.x; the caption below needs the full
                # width back).
                cell_w = col.available_width
                btn_w = ICON_FONT * Egui::Fonts::LINE_H_FACTOR +
                        col.style.spacing.button_padding.x * 2.0
                cell_left = col.cursor.x
                col.cursor = Egui::Pos2.new(
                  cell_left + (cell_w - btn_w) / 2.0, col.cursor.y)
                r = col.add_sized(Egui::Vec2.new(btn_w, BUTTON_H),
                  Egui::Button.new("")
                    .icon(Egui::Icon.cached(@provider, name, fg, source))
                    .style { |s| s.font_size = ICON_FONT })
                col.cursor = Egui::Pos2.new(cell_left, col.cursor.y)
                # Click: select — the preview panel shows this icon.
                r.clicked { @selected = {@provider, name, source} }
                # Secondary press: editor / clipboard actions.
                r.context_menu { |menu| icon_menu(menu, @provider, name) }
                # Caption: centered under the button — Label always
                # paints from the left edge, so the single-line caption
                # is measured and painted manually at the column's
                # horizontal center (full-width allocation keeps the
                # row stride the culling above relies on).
                cap = caption(ctx, name, col.available_width)
                cap_h = CAPTION_FONT * Egui::Fonts::LINE_H_FACTOR
                crect = col.allocate_space(Egui::Vec2.new(col.available_width, cap_h))
                cap_w = ctx.fonts.measure_cached(cap, CAPTION_FONT).x
                col.painter.text(Egui::Pos2.new(
                  crect.left + (crect.width - cap_w) / 2.0,
                  crect.top + cap_h / 2.0), cap, CAPTION_FONT, fg)
              end
            end
          end
        end
      end

      # FPS overlay, top-right over the (left-packed) search row.
      if @show_fps
        text = "#{"%.0f" % @fps} fps · #{"%.1f" % (1000.0 / @fps)} ms"
        w = ctx.fonts.measure(text, 14.0).x
        ui.painter.text(Egui::Pos2.new(ui.max_rect.right - w - 12.0,
          ui.max_rect.min.y + 20.0), text, 14.0, fg)
      end
    end
  end

  # Preview panel body: the selected icon rendered large — an
  # icon-only button sized to the panel width (the glyph box is
  # font_size * LINE_H_FACTOR square, so the font size is derived
  # from the available width minus the button padding), its name,
  # the underscore symbol form, the `Icon.from_file` usage line, and
  # copy buttons. The big icon carries the same context menu as the
  # catalog cells.
  private def preview(ui : Egui::Ui) : Nil
    fg = ui.style.visuals.text_color
    unless (sel = @selected)
      ui.label("Click an icon to select it — it shows up here.\n" \
               "Right-click a cell for editor and clipboard actions.")
      return
    end
    provider, name, source = sel
    w = ui.available_width
    pad = ui.style.spacing.button_padding.x
    big = ui.add_sized(Egui::Vec2.new(w, w),
      Egui::Button.new("")
        .icon(Egui::Icon.cached(provider, name, fg, source))
        .style { |s| s.font_size = (w - pad * 2.0) / Egui::Fonts::LINE_H_FACTOR })
    big.context_menu { |menu| icon_menu(menu, provider, name) }
    ui.heading(name)
    ui.label(":#{name.gsub("-", "_")}")
    ui.add(Egui::Button.new("Copy :#{name.gsub("-", "_")}").icon(:copy))
      .clicked { copy_name(name) }
    # The usage line to paste into code — provider and icon name as
    # literals, exactly what the `from_file` macro requires.
    code = usage_code(provider, name)
    ui.separator
    ui.label(code)
    ui.add(Egui::Button.new("Copy from_file call").icon(:copy))
      .clicked { Egui::SystemPorts::Clipboard.text = code }
  end

  # The `Icon.from_file` call for this icon, underscore symbol form:
  # `:arrow_up` maps to `arrow-up.svg` at compile time.
  private def usage_code(provider : String, name : String) : String
    "Egui::Icon.from_file(:#{provider}, :#{name.gsub("-", "_")})"
  end

  # Context menu shared by the catalog cells and the preview icon.
  private def icon_menu(menu : Egui::Ui, provider : String, name : String) : Nil
    menu.menu_item("Open in SVG editor") do
      Egui::SystemPorts::FileOpen.show("#{DIRS[provider]}/#{name}.svg")
    end
    menu.menu_item("Copy :#{name.gsub("-", "_")}", icon: :copy) do
      copy_name(name)
    end
    menu.menu_item("Copy from_file call", icon: :copy) do
      Egui::SystemPorts::Clipboard.text = usage_code(provider, name)
    end
  end

  private def copy_name(name : String) : Nil
    Egui::SystemPorts::Clipboard.text = name.gsub("-", "_")
  end

  # Cell caption: underscore form of the name, ellipsized to the
  # column width (single line → uniform row heights).
  private def caption(ctx : Egui::Context, name : String,
                      max_w : Float64) : String
    text = name.gsub("-", "_")
    return text if ctx.fonts.measure_cached(text, CAPTION_FONT).x <= max_w
    cut = text.size
    while cut > 1 &&
          ctx.fonts.measure_cached(text[0, cut] + "…", CAPTION_FONT).x > max_w
      cut -= 1
    end
    text[0, cut] + "…"
  end
end

Egui::Backend::Sokol.run(LucideIconsApp.new, title: "egui-cr — icons (lucide · bootstrap)",
  width: 1120, height: 760, inspector: :hidden, vsync: false)
# vsync off: an FPS meter capped at the monitor's refresh rate
# measures the monitor, not the app — this demo exists to measure.
