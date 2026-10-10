# egui-cr: rounded window demo — a macOS-Spotlight-style launcher.
#
# The OS window itself is a fixed-size borderless transparent surface;
# what the user perceives as "the window" is Egui::RoundedWindow — a
# rounded-rectangle shell that paints its backdrop and cuts the
# platform window to the same shape (XShape / SetWindowRgn; macOS
# composites the painted alpha natively, so the shape call is a no-op
# there). Because the shell recomputes its geometry every frame, the
# visible window ANIMATES: it starts as a lone search bar and grows,
# smoothly, by one row per matching app as you type (the height
# eases toward its target every frame), and the corner radius is a
# runtime slider — 0 = square, 24 = a pill-ish card.
#
# The apps are hardcoded (name + description + an embedded Lucide
# icon) — no system scan, it is a shape demo, not a real launcher.
# ↑/↓ move the selection, ↵ flashes a fake launch, Esc clears the
# query (and quits when it is already empty), drag anywhere to move.

require "../src/egui/backend_selector"

class RoundedWindowApp < Egui::App
  # The fixed OS-window surface; the rounded card lives inside it.
  OS_W = 640.0
  OS_H = 480.0

  CARD_W  = 560.0 # rounded card width
  CARD_TOP = 36.0 # card top inside the OS window (grows downward)
  PAD     = 14.0  # card inner padding (RoundedWindow `pad:`)
  BAR_H   = 44.0  # the search row
  ROW_H   = 46.0  # one result row
  FOOT_H  = 40.0  # the radius-slider row
  MAX_ROWS = 6

  # Spotlight-ish palette. The fill is OPAQUE: on X11 the GL swap
  # chain may drop framebuffer alpha, so translucency cannot be
  # relied on cross-platform — the shape, not the fill's alpha, is
  # what makes the corners work everywhere.
  BG     = Egui::Color32.new(36, 36, 41, 255)
  RIM    = Egui::Color32.new(255, 255, 255, 36)
  FG     = Egui::Color32.new(235, 235, 240, 255)
  HINT   = Egui::Color32.new(158, 158, 168, 255)
  SELECT = Egui::Color32.new(72, 72, 82, 255)
  HAIRLINE = Egui::Color32.new(255, 255, 255, 22)

  # One hardcoded "installed app": name, blurb, embedded Lucide icon
  # (Icon.from_file needs the literal symbol at the call site, so each
  # entry builds its icon inline below).
  class App
    getter name : String
    getter desc : String
    getter icon : Egui::Svg

    def initialize(@name : String, @desc : String, @icon : Egui::Svg)
      @icon.size = Egui::Vec2.new(22.0, 22.0)
    end
  end

  APPS = [
    App.new("Terminal", "command line",
      Egui::Icon.from_file(:lucide, :terminal, tint: FG)),
    App.new("Calculator", "calculations",
      Egui::Icon.from_file(:lucide, :calculator, tint: FG)),
    App.new("Calendar", "events & meetings",
      Egui::Icon.from_file(:lucide, :calendar, tint: FG)),
    App.new("Mail", "email client",
      Egui::Icon.from_file(:lucide, :mail, tint: FG)),
    App.new("Music", "player & library",
      Egui::Icon.from_file(:lucide, :music, tint: FG)),
    App.new("Settings", "system settings",
      Egui::Icon.from_file(:lucide, :settings, tint: FG)),
    App.new("Browser", "web browser",
      Egui::Icon.from_file(:lucide, :globe, tint: FG)),
    App.new("Notes", "quick notes",
      Egui::Icon.from_file(:lucide, :sticky_note, tint: FG)),
    App.new("Maps", "maps & routes",
      Egui::Icon.from_file(:lucide, :map, tint: FG)),
    App.new("Photos", "photo library",
      Egui::Icon.from_file(:lucide, :camera, tint: FG)),
    App.new("Code Editor", "IDE & text editor",
      Egui::Icon.from_file(:lucide, :app_window, tint: FG)),
    App.new("Weather", "weather forecast",
      Egui::Icon.from_file(:lucide, :moon, tint: FG)),
  ]

  @search_icon : Egui::Svg = begin
    svg = Egui::Icon.from_file(:lucide, :search, tint: HINT)
    svg.size = Egui::Vec2.new(20.0, 20.0)
    svg
  end

  @query = ""
  @radius = 14.0
  @height : Float64 = BAR_H + 2 * PAD # animated card height (bare bar at start)
  @selected = 0
  @focused = false
  @themed = false
  @flash : {String, Float64}? # "↵ launch" toast: app name + shown-at time

  def update(ctx : Egui::Context) : Nil
    # The card height eases toward its target every frame — repaint
    # continuously so the growth animates.
    ctx.request_repaint
    screen = ctx.input.screen_rect
    time = ctx.input.time

    # The card palette is fixed dark — force the matching theme so the
    # stock widgets (field, slider, labels) pick readable colors.
    unless @themed
      ctx.theme = Egui::Theme.dark
      @themed = true
    end

    results = APPS.select { |app| app.name.downcase.includes?(@query.downcase) }
      .first(MAX_ROWS)
    @selected = results.empty? ? 0 : {@selected, results.size - 1}.min

    # Keyboard: ↑/↓ move the selection, ↵ "launches" (a flash toast —
    # hardcoded demo, nothing to actually start), Esc clears then quits.
    if ctx.input.key_pressed?(Egui::KeyCode::Down)
      @selected = {@selected + 1, results.size - 1}.min
    end
    if ctx.input.key_pressed?(Egui::KeyCode::Up)
      @selected = {@selected - 1, 0}.max
    end
    if ctx.input.key_pressed?(Egui::KeyCode::Enter) && (app = results[@selected]?)
      @flash = {app.name, time}
    end
    if ctx.input.key_pressed?(Egui::KeyCode::Escape)
      if @query.empty?
        Egui::SystemPorts::Quit.quit!
      else
        @query = ""
      end
    end

    # The card: search bar + one row per result + the slider footer.
    # Height eases toward the target (exponential, snapped when close).
    target = BAR_H + results.size * ROW_H + FOOT_H + 2 * PAD
    delta = target - @height
    @height = delta.abs < 1.0 ? target : @height + delta * 0.28

    card = Egui::Rect.from_min_size(
      Egui::Pos2.new(screen.center.x - CARD_W / 2.0, CARD_TOP),
      Egui::Vec2.new(CARD_W, @height))

    Egui::RoundedWindow.show(ctx, card, radius: @radius,
      fill: BG, stroke: RIM, pad: PAD, drag: true, id: "spotlight") do |ui|
      painter = ctx.painter
      painter.layer = Egui::Order::Background
      painter.clip = card
      inner = ui.max_rect

      # Search row: lens icon + the borderless field (focused from the
      # first frame — Spotlight is about typing immediately).
      field : Egui::Response? = nil
      ui.horizontal do |row|
        row.add(@search_icon)
        field = row.text_edit_singleline(@query, hint: "Search apps…",
          focus_id: "spotlight", frame: false) { |t| @query = t; @selected = 0 }
      end
      field_rect = field.not_nil!.rect

      unless @focused
        field.not_nil!.request_focus
        @focused = true
      end

      # Results: rows at fixed offsets below the search row. Hover or
      # ↑/↓ selects (rounded highlight), click "launches".
      rows_top = field_rect.bottom + 6.0
      painter.line(Egui::Pos2.new(inner.left, rows_top - 3.0),
        Egui::Pos2.new(inner.right, rows_top - 3.0), 1.0, HAIRLINE)

      results.each_with_index do |app, i|
        row_rect = Egui::Rect.from_min_size(
          Egui::Pos2.new(inner.left, rows_top + i * ROW_H),
          Egui::Vec2.new(inner.width, ROW_H - 4.0))
        resp = ui.interact(row_rect, ui.named_id("app/#{app.name}"),
          Egui::Sense::Click)
        @selected = i if resp.hovered?
        if @selected == i
          painter.rect(row_rect, 8.0, SELECT, nil, 0.0)
        end
        app.icon.paint(ui, Egui::Rect.from_min_size(
          Egui::Pos2.new(row_rect.left + 10.0, row_rect.center.y - 11.0),
          Egui::Vec2.new(22.0, 22.0)))
        painter.text(Egui::Pos2.new(row_rect.left + 44.0, row_rect.center.y),
          app.name, 15.0, FG)
        unless app.desc.empty?
          desc_w = ctx.fonts.measure(app.desc, 12.5).x
          painter.text(
            Egui::Pos2.new(row_rect.right - 10.0 - desc_w, row_rect.center.y),
            app.desc, 12.5, HINT)
        end
        if resp.clicked?
          @flash = {app.name, time}
        end
      end

      # Footer (at the card's bottom edge): the corner-radius slider —
      # live proof the shape is runtime-computable — plus the launch
      # toast. Reserve the rows' space in the Ui flow first so the
      # slider lands below them.
      rows_bottom = rows_top + results.size * ROW_H
      ui.allocate_at_least(
        Egui::Vec2.new(0.0, {rows_bottom - ui.cursor.y, 0.0}.max))

      flash = @flash.try { |f| time - f[1] < 1.5 ? f[0] : nil }
      @flash = nil if flash.nil? && @flash
      ui.horizontal do |row|
        slider = row.add_sized(
          Egui::Vec2.new(inner.width * 0.5, 20.0),
          Egui::Slider.new(@radius, 0.0..24.0, "Radius"))
        if slider.changed? && (v = slider.widget_value)
          @radius = v.round
        end
        row.label(flash ? "↵ Launch: #{flash}" : "↑↓ · ↵ · Esc")
      end
    end
  end
end

Egui.run(RoundedWindowApp.new,
  title: "egui-cr — rounded window", width: RoundedWindowApp::OS_W.to_i32,
  height: RoundedWindowApp::OS_H.to_i32,
  decorations: false, transparent: true, inspector: :hidden)
