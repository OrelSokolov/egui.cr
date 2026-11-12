# ChatApp — the h2code TUI two-zone model on egui.cr, 1:1 with
# ~/hcode/docs/TUI_ZONES.md:
#
#   LOG (append-only)                     every finalized piece — user
#   ● user message                        messages, tool headers and
#   ● assistant message                   results, step summaries —
#   ● Выполнена команда: bash             appended ONCE, never rewritten.
#   ─────────────────────────────────
#   ACTIVE ZONE (repainted every frame)   transient lines that appear /
#   ⠹ Обдумываю ответ…                    disappear as work starts and
#   ● Запуск команды: bash — …            finishes; on completion the
#   ┃ streaming assistant text…           content migrates into the log
#   ● CI: ждём сборку…                    (the release invariant).
#   ┌──────────────────────────────┐
#   │ input box             [➤]    │      the editor box grows with
#   └──────────────────────────────┘      its content.
#
# Visuals mirror the TUI's dark theme (~/hcode/src/tui/theme.cr, the
# xterm-256 palette translated to RGB): monospace everywhere, the
# braille spinner (⠋⠙⠹…, 80 ms — TUI spinner.cr FRAMES), the pulsing
# CI circle (● → • → ⋅ → •), the ┃ streaming bar in the logo color.
# The "agent" is a fiber play-acting the pipeline: think → stream →
# tool → CI, each stage declare_active/release_active with its zone.
#
# Entry point: examples/chat.cr (fonts + Egui.run). Bench:
# bench/chat_bench.cr drives this app headless over a 100k-entry log.

require "../../src/egui"

class ChatApp < Egui::App
  # TUI spinner.cr FRAMES — 80 ms per step.
  SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  # CI wait pulse: ● → • → ⋅ → •, ~250 ms per step (message_renderer.cr).
  PULSE_FRAMES = ["●", "•", "⋅", "•"]

  # h2code TUI dark theme (xterm-256 → RGB).
  C_BG      = Egui::Color32.rgb(0x26, 0x26, 0x26) # 235 background
  C_TEXT    = Egui::Color32.rgb(0xE4, 0xE4, 0xE4) # 254 text
  C_PRIMARY = Egui::Color32.rgb(0x5F, 0xAF, 0xFF) # 75 primary/tool_header
  C_DIM     = Egui::Color32.rgb(0x8A, 0x8A, 0x8A) # 245 dim/tool_result
  C_USER    = Egui::Color32.rgb(0xFF, 0xD7, 0x87) # 222 user_msg
  C_LOGO    = Egui::Color32.rgb(0xAF, 0xAF, 0x87) # 144 logo (streaming ┃)
  C_TELEM   = Egui::Color32.rgb(0xFF, 0xD7, 0x5F) # 221 telemetry (CI)
  C_SUCCESS = Egui::Color32.rgb(0x5F, 0xD7, 0x87) # 78 success

  # One finalized line of the LOG zone, rendered once by role.
  # `rows`/`wrap_width` are the SCROLL GEOMETRY: the entry's row
  # count under the log's current width — kept in sync for the WHOLE
  # log by #rewrap_all on every width change, so the scrollbar and the
  # painted rows never disagree. `lines`/`lines_width` are the cheaper
  # per-entry text cache: the actual wrapped text, laid out only for
  # the visible entries (a layout row count that disagrees with the
  # greedy estimate patches the tree on the spot — mono fonts make
  # that a no-op in practice).
  class Entry
    getter role : Symbol
    getter text : String
    property lines : String
    property rows : Int32
    property wrap_width : Float64 = -1.0
    property lines_width : Float64 = -1.0

    def initialize(@role : Symbol, @text : String)
      @lines = @text
      @rows = 1
    end
  end

  # One ACTIVE-zone line: appears on declare_active, disappears on
  # release_active. `kind` picks the line's leading glyph:
  #   :spinner — braille spinner + status label
  #   :stream  — the ┃ bar + live streaming text
  #   :pulse   — the animated ● → • → ⋅ circle (CI / background waits)
  #   :tool    — running tool header (the ● bullet, like tool_header)
  class Zone
    getter kind : Symbol
    property label : String
    property text : String = ""

    def initialize(@kind : Symbol, @label : String)
    end
  end

  REPLIES = [
    "Принято. Раскладываю ответ на слова — каждое прилетает в активную зону ┃, а целиком мигрирует в лог по завершении.",
    "Это всё та же двухзонная модель: лог append-only и никогда не перерисовывается, активная зона живёт один такт работы.",
    "Зона со спиннером уже погасла, её строка уехала в лог — это инвариант release: ни одна активная строка не исчезает бесследно.",
    "Дальше по пьесе — вызов инструмента и ожидание CI: следи за пульсирующим кружком над полем ввода.",
  ]

  getter log : Array(Entry)
  @log = [] of Entry
  @zones = {} of String => Zone   # insertion order = render order
  @draft = ""
  @play = 0                       # play counter → unique zone keys
  # Cumulative row counts of the log (Fenwick tree): prefix(i) is the
  # total wrapped rows of entries [0, i). A new entry appends O(log n)
  # and a rewrap patches a delta O(log n) — the log's pixel geometry
  # stays queryable without walking 100k entries per frame.
  @rows = RowIndex.new
  # The width the geometry (entry.rows) is currently wrapped under;
  # nil until the first frame positions the log.
  @log_wrap_width : Float64? = nil
  # word → pixel width (the greedy row counter's cache; the vocabulary
  # of a real log is small, so this stays tiny).
  @word_widths = {} of String => Float64
  # Bench seam: force the log's wrap width (resize simulation).
  property forced_wrap_width : Float64? = nil

  LOG_SCROLL = Egui::Id.from("chat/log")
  DRAFT_ID   = "composer/draft"   # stable focus id → the cursor
                                   # survives the panel reflow when
                                   # zones appear/disappear above

  # Binary-indexed tree over per-entry row counts.
  class RowIndex
    def initialize
      @tree = Array(Int32).new(1, 0) # 1-based
    end

    def size : Int32
      @tree.size - 1
    end

    def push(rows : Int32) : Nil
      m = @tree.size # the new 1-based index
      @tree << 0
      lb = m & -m
      if lb == 1 # a pure leaf
        @tree.unsafe_put(m, rows)
      else
        # Node m covers [m-lb+1, m]. Everything below m is already in
        # the tree, so the node's total is the new rows plus the
        # range sum of its existing span — later appends build their
        # parents the same way (a plain add() would silently miss the
        # parent nodes created AFTER it).
        @tree.unsafe_put(m, rows + prefix(m - 1) - prefix(m - lb))
      end
    end

    # `i0` is a 1-based entry index.
    def add(i0 : Int32, delta : Int32) : Nil
      i = i0
      while i < @tree.size
        @tree.unsafe_put(i, @tree.unsafe_fetch(i) + delta)
        i += i & -i
      end
    end

    # Sum of rows over entries [0, i0).
    def prefix(i0 : Int32) : Int32
      i = i0
      sum = 0
      while i > 0
        sum += @tree.unsafe_fetch(i)
        i &= i - 1
      end
      sum
    end
  end

  def initialize
    super
    @log = [] of Entry
    ctx.theme = Egui::Theme.dark
  end

  # The greeting the entry point shows on launch.
  def welcome! : Nil
    append(:assistant,
      "Привет! Это двухзонная модель h2code в GUI: лог сверху, " \
      "активная зона снизу. Отправь сообщение.")
  end

  # --- LOG zone ----------------------------------------------------------

  private def append(role : Symbol, text : String) : Nil
    entry = Entry.new(role, text)
    # New entries join the log with geometry already consistent with
    # the current width (after the first frame fixed @log_wrap_width).
    if (w = @log_wrap_width) && role != :blank
      entry.rows = greedy_rows(entry.text, w)
      entry.wrap_width = w
    end
    @log << entry
    @rows.push(entry.rows)
    if role.in?(:user, :assistant) # the TUI blank line after a message
      @log << Entry.new(:blank, "")
      @rows.push(1)
    end
    # Stick the log to the bottom: a huge offset clamps to max on the
    # next frame's layout (ScrollArea clamps after laying content out).
    ctx.memory.data.set_vec2(LOG_SCROLL, Egui::Vec2.new(0.0, 1e9))
    ctx.request_repaint
  end

  # --- wrap geometry ------------------------------------------------------

  private def word_width(word : String, fonts : Egui::Fonts,
                         fs : Float64) : Float64
    @word_widths[word]? || begin
      w = fonts.measure(word, fs).x
      @word_widths[word] = w
      w
    end
  end

  # Greedy word-wrap row count — the cheap O(bytes) twin of
  # Fonts#layout (same greedy algorithm). Mono stacks take the
  # zero-allocation fast path: every char is one column of a fixed
  # advance, so the count is a plain byte scan. Non-mono stacks fall
  # back to per-word measures through the word cache. Any disagreement
  # with the real layout is patched when the entry is painted.
  @mono_advance : Float64 = -1.0 # -1 unchecked, -2 not mono, else px

  private def mono_advance(fonts : Egui::Fonts, fs : Float64) : Float64
    return @mono_advance if @mono_advance >= 0.0 || @mono_advance == -2.0
    m = fonts.measure("MMMMMMMMMM", fs).x / 10.0
    i = fonts.measure("iiiiiiiiii", fs).x / 10.0
    @mono_advance = (m - i).abs < 0.01 ? m : -2.0
    @mono_advance
  end

  private def greedy_rows(text : String, wrap_w : Float64,
                          fonts : Egui::Fonts = ctx.fonts,
                          fs : Float64 = ctx.style.font_size) : Int32
    return 1 if text.empty?
    if (adv = mono_advance(fonts, fs)) && adv > 0.0
      greedy_rows_mono(text, {wrap_w / adv, 1.0}.max.floor.to_i)
    else
      greedy_rows_generic(text, wrap_w, fonts, fs)
    end
  end

  # Byte scan over the text: UTF-8 lead bytes count one column each,
  # spaces break words, newlines break rows. No allocations.
  private def greedy_rows_mono(text : String, wrap_cols : Int32) : Int32
    rows = 1
    line_cols = 0
    word_cols = 0
    in_word = false
    flush = -> do
      if in_word
        if line_cols == 0
          line_cols = word_cols
        elsif line_cols + 1 + word_cols <= wrap_cols
          line_cols += 1 + word_cols
        else
          rows += 1
          line_cols = word_cols
        end
        word_cols = 0
        in_word = false
      end
    end
    bytes = text.to_unsafe
    i = 0
    n = text.bytesize
    while i < n
      b = bytes[i]
      if b == 0x20
        flush.call
      elsif b == 0x0A
        flush.call
        rows += 1
        line_cols = 0
      elsif b & 0xC0 != 0x80 # UTF-8 lead byte → one char/column
        word_cols += 1
        in_word = true
      end
      i += 1
    end
    flush.call
    rows
  end

  # The per-word-measure fallback for proportional stacks.
  private def greedy_rows_generic(text : String, wrap_w : Float64,
                                  fonts : Egui::Fonts,
                                  fs : Float64) : Int32
    space = word_width(" ", fonts, fs)
    rows = 0
    text.each_line do |line|
      rows += 1
      next if line.empty?
      w = 0.0
      first = true
      line.split(' ') do |word|
        next if word.empty?
        ww = word_width(word, fonts, fs)
        if first
          w = ww
          first = false
        elsif w + space + ww <= wrap_w
          w += space + ww
        else
          rows += 1
          w = ww
        end
      end
    end
    rows
  end

  # Re-wrap the WHOLE log's geometry under `wrap_w` — synchronously,
  # on the very frame the width changed, so the scrollbar, the offsets
  # and the painted rows always agree (the greedy counter keeps this
  # at ~tens of ms for 100k entries instead of the seconds a full
  # Fonts#layout pass would take).
  private def rewrap_all(wrap_w : Float64,
                         fonts : Egui::Fonts,
                         fs : Float64) : Nil
    @log.each_with_index do |entry, i|
      new_rows = entry.role == :blank ? 1 : greedy_rows(entry.text, wrap_w,
        fonts, fs)
      if new_rows != entry.rows
        @rows.add(i + 1, new_rows - entry.rows)
        entry.rows = new_rows
      end
      entry.wrap_width = wrap_w
      entry.lines_width = -1.0 # laid-out text is stale; visible only
    end
    @log_wrap_width = wrap_w
  end

  # --- ACTIVE zone -------------------------------------------------------

  # TUI `declare_active(key)`: a transient line appears above the input.
  private def declare_active(key : Symbol, label : String, play : Int32) : Nil
    @zones["#{key}/#{play}"] = Zone.new(key, label)
    ctx.request_repaint
  end

  # TUI `release_active(key)`: the line disappears — and its summary
  # lands in the log, so nothing vanishes without a trace.
  private def release_active(key : Symbol, play : Int32) : Nil
    @zones.delete("#{key}/#{play}")
    ctx.request_repaint
  end

  # --- the "agent": think → stream → tool → CI --------------------------

  private def send_message : Nil
    text = @draft.strip
    return if text.empty?
    @play += 1
    play = @play
    @draft = ""
    append(:user, text)
    spawn do
      declare_active(:spinner, "Обдумываю ответ…", play)
      sleep 900.milliseconds
      release_active(:spinner, play)
      append(:think, "Обдумано · 0.9 с")

      declare_active(:stream, "", play)
      stream = @zones["stream/#{play}"].not_nil!
      # Long enough to outgrow MAX_ZONE_LINES — the zone tail-clips
      # (top rows fall off) while the words keep arriving, then the
      # whole text migrates into the log on release.
      full = (REPLIES + REPLIES.reverse).join(' ') +
             " Эхо: #{text[0, 40]}."
      words = full.split(' ')
      words.each_with_index do |word, i|
        stream.text = words[0..i].join(' ')
        ctx.request_repaint
        sleep 40.milliseconds
      end
      release_active(:stream, play)
      append(:assistant, stream.text)

      cmd = "echo #{text[0, 16].inspect}"
      declare_active(:tool, "Запуск команды: bash — #{cmd}", play)
      sleep 1.second
      release_active(:tool, play)
      append(:tool_run, "Выполнена команда: bash — #{cmd}")
      append(:tool_result, "ок (exit 0)")

      declare_active(:pulse, "CI: ждём сборку коммита", play)
      sleep 2.5.seconds
      release_active(:pulse, play)
      append(:ci, "CI passed ✓ · 2.5 с")
    end
  end

  # --- layout -------------------------------------------------------------

  def update(ctx : Egui::Context) : Nil
    # The composer is pinned to the bottom and NEVER reflows when zones
    # come and go; the active zone builds itself ON TOP of it as its
    # own strip (the second bottom_panel bites above the first), so it
    # appears and vanishes without touching the editor box.
    ctx.bottom_panel("composer", height: composer_height(ctx),
                     resizable: false, fill: C_BG) do |ui|
      composer(ctx, ui)
    end
    unless @zones.empty?
      ctx.bottom_panel("active", height: active_height(ctx),
                       resizable: false, fill: C_BG) do |ui|
        # A bottom panel's flow is left_to_right (rows seeded at the
        # interact height — one zone line would stand taller than a
        # text line). Lay the zone lines out in a top-down child so
        # each is exactly one line_h tall, like a TUI screen row.
        column = ui.child_ui(ui.max_rect, layout: Egui::Layout.top_down)
        active_zone(ctx, column)
      end
    end

    ctx.central_panel(fill: C_BG) do |ui|
      log_zone(ui)
    end
  end

  # LOG: append-only feed, rendered exactly like the TUI message renderer:
  # user — bold user_msg; assistant/tool headers — ● + bold primary;
  # tool results and step summaries — dim; a blank line after messages.
  #
  # WRAPPING: every width change re-wraps the WHOLE log's row geometry
  # synchronously (#rewrap_all — the greedy counter, ~tens of ms for
  # 100k entries), so the scrollbar and the scroll offsets are always
  # in sync with what is painted. The actual laid-out text is produced
  # only for the visible entries; a layout row count that disagrees
  # with the greedy estimate patches the tree on the spot.
  #
  # The row geometry lives in the @rows Fenwick tree, so the viewport
  # window is found by a BINARY SEARCH over exact y positions (each
  # probe is an O(log n) prefix query) and the rows above/below the
  # clip are skipped by two bulk allocations — a 100k-entry log costs
  # O(visible + log² n) per frame, not O(log).
  private def log_zone(ui : Egui::Ui) : Nil
    Egui::ScrollArea.new(id: LOG_SCROLL).show(ui) do |scroll|
      style = scroll.style
      line_h = style.font_size * Egui::Fonts::LINE_H_FACTOR
      gap = style.spacing.item_spacing.y
      fonts = scroll.fonts
      fs = style.font_size
      clip = scroll.painter.clip
      wrap_w = {(@forced_wrap_width || scroll.available_width), 10.0}.max
      n = @log.size
      # NB: the clip and the flow cursor share the painter's
      # (offset-shifted) coordinate space — compare them directly.
      base = scroll.cursor.y

      rewrap_all(wrap_w, fonts, fs) if @log_wrap_width != wrap_w

      # Exact top edge of entry i: wrapped rows of everything before
      # it, one inter-entry gap per predecessor.
      top = ->(i : Int32) do
        base + @rows.prefix(i) * line_h + i * gap
      end
      height = ->(i : Int32) { @log.unsafe_fetch(i).rows * line_h }

      # First entry whose bottom edge crosses into the clip. The bulk
      # skip lands the cursor ON entry lo's top edge: the advance after
      # an allocate adds one inter-entry gap, so reserve gap less.
      lo, hi = 0, n
      while lo < hi
        mid = (lo + hi) // 2
        if top.call(mid) + height.call(mid) > clip.min.y
          hi = mid
        else
          lo = mid + 1
        end
      end
      if lo > 0
        scroll.allocate_space(
          Egui::Vec2.new(0.0, {top.call(lo) - base - gap, 0.0}.max))
      end

      idx = lo
      while idx < n
        break if scroll.cursor.y > clip.max.y
        entry = @log.unsafe_fetch(idx)
        unless entry.role == :blank # blanks are always one empty row
          if entry.lines_width != wrap_w # lay the visible text out
            galley = fonts.layout(
              [Egui::TextRun.new(entry.text, fs)], max_width: wrap_w)
            lines = galley.rows.map(&.text)
            entry.lines = lines.join('\n')
            entry.lines_width = wrap_w
            unless lines.size == entry.rows # greedy/layout disagreement
              @rows.add(idx + 1, lines.size - entry.rows)
              entry.rows = lines.size
            end
          end
          text = entry.lines
          case entry.role
          when :user
            scroll.rich(
              Egui::RichText.new("● #{text}").bold.color(C_USER),
              wrap: false)
          when :assistant
            scroll.rich(Egui::RichText.new("● #{text}").color(C_TEXT),
              wrap: false)
          when :tool_run
            scroll.rich(
              Egui::RichText.new("● #{text}").bold.color(C_PRIMARY),
              wrap: false)
          when :tool_result
            scroll.rich(Egui::RichText.new("→ #{text}").color(C_DIM),
              wrap: false)
          when :think
            scroll.rich(Egui::RichText.new("● #{text}").color(C_DIM),
              wrap: false)
          when :ci
            scroll.rich(Egui::RichText.new("● #{text}").color(C_TELEM),
              wrap: false)
          end
        else # :blank — the TUI separator line after a message
          scroll.allocate_space(Egui::Vec2.new(0.0, line_h))
        end
        idx += 1
      end

      # Bulk-skip whatever remains below the viewport: up to entry n's
      # top edge (the cursor already sits gap past the last drawn one).
      if idx < n
        scroll.allocate_space(
          Egui::Vec2.new(0.0, {top.call(n) - scroll.cursor.y, 0.0}.max))
      end

      if ENV["CHAT_DEBUG"]?
        STDERR.printf("[log_zone] n=%d base=%.1f clip=[%.1f..%.1f] " \
                      "lo=%d idx=%d model_h=%.1f wrap_w=%.1f rows_total=%d\n",
          n, base, clip.min.y, clip.max.y, lo, idx,
          @rows.prefix(n) * line_h + (n - 1) * gap, wrap_w,
          @rows.prefix(n))
      end
    end
  end

  # The active-zone strip. Lines wrap to the panel width, but the zone
  # is BOUNDED: at most MAX_ZONE_LINES screen rows, tail-clipped like
  # the TUI ActiveZone (only the bottom portion is drawn — the top
  # rows fall off as new streaming words push the block up).
  MAX_ZONE_LINES = 6

  # The zone's screen line: glyph + label/text.
  private def zone_line(zone : Zone, t : Float64) : String
    case zone.kind
    when :spinner
      "#{SPINNER_FRAMES[(t * 12.5).to_i % SPINNER_FRAMES.size]} #{zone.label}"
    when :stream
      "┃ #{zone.text.empty? ? " " : zone.text}"
    when :pulse
      "#{PULSE_FRAMES[(t * 4.0).to_i % PULSE_FRAMES.size]} #{zone.label}"
    else # :tool — running tool header
      "● #{zone.label}"
    end
  end

  # Wrap width of the active-zone strip: the panel's inner width.
  private def zone_wrap_width(ctx : Egui::Context) : Float64
    {ctx.input.screen_rect.width -
       ctx.style.spacing.window_padding.x * 2.0, 10.0}.max
  end

  # Per-zone wrapped lines + how many top rows the tail clip drops.
  # Height and painting both build off this one computation, so the
  # panel height and the painted rows can never disagree.
  private def zone_layout(ctx : Egui::Context, wrap_w : Float64)
    t = ctx.input.time
    fonts = ctx.fonts_for(ctx.style.font_family)
    fs = ctx.style.font_size
    laid = [] of {Symbol, Array(String)}
    total = 0
    @zones.each_value do |zone|
      galley = fonts.layout(
        [Egui::TextRun.new(zone_line(zone, t), fs)], max_width: wrap_w)
      lines = galley.rows.map(&.text)
      total += lines.size
      laid << {zone.kind, lines}
    end
    {laid, {total - MAX_ZONE_LINES, 0}.max}
  end

  private def active_zone(ctx : Egui::Context, ui : Egui::Ui) : Nil
    laid, skip = zone_layout(ctx, zone_wrap_width(ctx))
    ctx.request_repaint if @zones.any? { |_, z| z.kind != :tool }
    laid.each do |kind, lines|
      next if lines.size <= skip
      shown = skip > 0 ? lines[skip..] : lines
      skip = 0
      text = Egui::RichText.new(shown.join('\n'))
      case kind
      when :spinner, :tool then text = text.bold.color(C_PRIMARY)
      when :stream         then text = text.color(C_LOGO)
      else                      text = text.color(C_TELEM)
      end
      ui.rich(text, wrap: false)
    end
  end

  # The editor box: a textarea that GROWS with its content — the row
  # count follows the ACTUAL wrapped layout of the draft (both explicit
  # Shift+Enter newlines and soft wraps), clamped at MAX_ROWS; past it
  # the box scrolls internally. Enter sends the message, Shift+Enter
  # breaks the line (consumed here, before the textarea's keyboard
  # pass, so the widget never sees the plain Enter).
  MAX_ROWS = 8

  # Width of the textarea's wrap region — mirrors TextArea's own math:
  # panel padding → button column → box inset → the reserved scrollbar
  # strip (TextArea::BAR_W).
  private def draft_wrap_width(ctx : Egui::Context) : Float64
    style = ctx.style
    btn_w = ctx.fonts_for(style.font_family)
            .measure("Отправить", style.font_size).x +
            style.spacing.button_padding.x * 2.0 + 20.0
    inner = ctx.input.screen_rect.width -
            style.spacing.window_padding.x * 2.0 - btn_w
    inner - 2.0 * (style.spacing.button_padding.x + 2.0) -
      Egui::TextArea::BAR_W
  end

  # Rows the draft needs at the current width: the galley's own row
  # count — explicit newlines AND soft wraps both grow the box.
  private def input_rows(ctx : Egui::Context) : Int32
    return 1 if @draft.empty?
    style = ctx.style
    wrap_w = {draft_wrap_width(ctx), 10.0}.max
    galley = ctx.fonts_for(style.font_family)
             .layout([Egui::TextRun.new(@draft, style.font_size)],
               max_width: wrap_w)
    galley.rows.size.clamp(1, MAX_ROWS)
  end

  private def composer_height(ctx : Egui::Context) : Float64
    style = ctx.style
    line_h = style.font_size * Egui::Fonts::LINE_H_FACTOR
    ta_h = input_rows(ctx) * line_h +
           2.0 * (style.spacing.button_padding.y + 2.0)
    # Breathing room: panel paddings and a reserve at the bottom — the
    # textarea clamps into whatever the panel gives it, so extra
    # height is only air. Zone lines NEVER factor in here: the active
    # zone is its own strip above this panel, not part of its height.
    style.spacing.window_padding.y * 2.0 + ta_h + 16.0
  end

  # The active-zone strip: one line_h per visible (tail-clipped) zone
  # line, a gap between the zones shown, plus the panel's padding.
  private def active_height(ctx : Egui::Context) : Float64
    style = ctx.style
    line_h = style.font_size * Egui::Fonts::LINE_H_FACTOR
    laid, skip = zone_layout(ctx, zone_wrap_width(ctx))
    rows = 0
    zones_shown = 0
    laid.each do |_, lines|
      next if lines.size <= skip
      rows += lines.size - skip
      skip = 0
      zones_shown += 1
    end
    style.spacing.window_padding.y * 2.0 + rows * line_h +
      {zones_shown - 1, 0}.max * style.spacing.item_spacing.y
  end

  private def composer(ctx : Egui::Context, ui : Egui::Ui) : Nil
    style = ctx.style
    line_h = style.font_size * Egui::Fonts::LINE_H_FACTOR
    pad = style.spacing.button_padding
    rows = input_rows(ctx)
    ta_h = rows * line_h + 2.0 * (pad.y + 2.0)

    # Enter sends (Shift+Enter stays the textarea's newline): claimed
    # BEFORE the widget's keyboard pass so it never inserts a break.
    enter_send = ctx.input.key_pressed?(Egui::KeyCode::Enter) &&
                 !ctx.input.modifiers.shift && !@draft.strip.empty?
    ctx.input.consume_key(Egui::KeyCode::Enter) if enter_send

    ui.horizontal(wrap: false) do |row|
      # Reserve the button column, then let the textarea eat the rest.
      btn_w = row.fonts.measure("Отправить", style.font_size).x +
              pad.x * 2.0 + 20.0
      response = row.add_sized(
        Egui::Vec2.new({row.available_width - btn_w, 60.0}.max, ta_h),
        Egui::TextArea.new(@draft,
          "напишите сообщение… (Enter — отправить, Shift+Enter — перенос)",
          rows, true, DRAFT_ID))
      if response.changed? && (text = response.widget_text)
        @draft = text
      end
      if enter_send
        send_message
      elsif row.button("Отправить").clicked?
        send_message
        response.request_focus # keep typing after sending
      end
    end
  end
end
