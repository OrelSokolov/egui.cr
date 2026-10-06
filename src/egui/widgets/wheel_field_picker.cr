# Windows 11 (WinUI)–style wheel picker engine, shared by `DatePicker`
# (day/month/year) and `TimePicker` (hour/minute/second): a field of
# segments — `15.09.2026`, `12:30:45` — whose order and separators come
# from the format string. A click opens a flyout of wheel columns, one
# per segment in the same order: the selection sits in the CENTER row
# between two hairlines, items fade with distance above and below; the
# wheel steps by one (clamped at the ends — NO wrap), a click picks.
# Edits land on a DRAFT (the widget is rebuilt every frame, so it lives
# in `Memory#data`); the footer's half-width buttons settle it Windows
# style: ✓ commits — fires the block once and closes, ✕ dismisses —
# closes leaving the committed value untouched. The day list follows
# the picked month/year — a Feb 31 clamps to the month's last day.

module Egui
  class WheelFieldPicker
    include Widget

    record Segment, kind : Symbol, sep : String

    # Range of the year column.
    YEAR_RANGE = 1900..2100
    # Rows above/below the centered selection (7 visible rows total).
    ROWS_SIDE = 3
    # Horizontal padding inside a wheel column.
    COL_PAD = 8.0
    # Inner padding of the flyout frame — tight, so the grid and the
    # footer reach almost edge-to-edge (native flyout look).
    FLYOUT_PAD = 3.0
    # Footer button height as a multiple of the interact row — half
    # again taller, so the ✓/✕ targets read as buttons, not grid rows.
    FOOTER_H_FACTOR = 1.5

    # Memory salts: the draft's ymd/hms cells and the footer buttons.
    DRAFT_DATE = 0xDA1_u64
    DRAFT_TIME = 0xDA2_u64
    ACCEPT_SALT = 0xAC1_u64
    CANCEL_SALT = 0xCC1_u64

    getter value : Time

    @on_change : Time ->
    @segments : Array(Segment)

    def initialize(prefix : String, id : String, @value : Time,
                   format : String, &@on_change : Time ->)
      @pid = Id.from("#{prefix}/#{id}")
      @popup_id = "#{prefix}/#{id}"
      @segments = parse_format(format)
    end

    # Split a strftime-ish format into ordered segments, keeping the
    # literal run before each token as its separator ("%d.%m.%Y" →
    # day "", month ".", year "."). Unknown tokens are skipped.
    private def parse_format(format : String) : Array(Segment)
      segments = [] of Segment
      sep = ""
      i = 0
      while i < format.size
        ch = format[i]
        if ch == '%' && i + 1 < format.size
          kind = case format[i + 1]
                 when 'd', 'e'          then :day
                 when 'm', 'b', 'B', 'h' then :month
                 when 'Y', 'y'          then :year
                 when 'H', 'I', 'k', 'l' then :hour
                 when 'M'               then :minute
                 when 'S', 's', 'L'     then :second
                 else
                   nil
                 end
          if kind
            segments << Segment.new(kind, sep)
            sep = ""
          end
          i += 2
        else
          sep += ch
          i += 1
        end
      end
      segments
    end

    # Widget entry point (`ui.add`) — wires the stored callback into
    # #show; direct callers may use `show(ui) { |t| … }`.
    def ui(ui : Ui) : Response
      show(ui, &@on_change)
    end

    def show(ui : Ui, &on_change : Time ->) : Response
      ctx = ui.ctx
      style = ui.style
      fonts = ctx.fonts_for(style.font_family)
      font_size = style.font_size
      visuals = style.visuals

      # Stable widths: each field is as wide as the widest value it can
      # show, so the field doesn't jitter when the value changes.
      field_ws = @segments.map { |seg| field_width(fonts, font_size, seg.kind) }
      wheel_ws = @segments.map { |seg| wheel_width(fonts, font_size, seg.kind) }
      pad = style.spacing.button_padding
      width = 2 * pad.x + field_ws.sum +
              @segments.sum { |seg| fonts.measure(seg.sep, font_size).x }
      height = {fonts.measure("0", font_size).y + 2 * pad.y,
        style.spacing.interact_size.y}.max
      rect = ui.allocate_at_least(Vec2.new(width, height))
      response = ui.interact(rect, @pid, Sense.click | Sense::Focusable)

      # Text-field look (Win11 field): weak fill; the segment under the
      # pointer reads as a band, like the native field's spin areas.
      ui.painter.rect(rect, 4.0, visuals.button_weak,
        visuals.button_stroke, 1.0)
      x = rect.left + pad.x
      @segments.each_with_index do |seg, i|
        unless seg.sep.empty?
          ui.painter.text(Pos2.new(x, rect.center.y), seg.sep, font_size,
            visuals.fade_color(visuals.text_color), family: style.font_family)
          x += fonts.measure(seg.sep, font_size).x
        end
        band = Rect.from_min_size(Pos2.new(x, rect.top + 2.0),
          Vec2.new(field_ws[i], rect.height - 4.0))
        if response.hovered? && (p = ctx.input.pointer_pos) &&
           p.x >= band.left && p.x < band.right
          ui.painter.rect(band, 3.0,
            visuals.fade_color(visuals.selection_fill, 0.35))
        end
        label = field_label(seg.kind)
        tw = fonts.measure(label, font_size).x
        ui.painter.text(Pos2.new(band.center.x - tw / 2.0, rect.center.y),
          label, font_size, visuals.text_color, family: style.font_family)
        x = band.right
      end
      response.paint_focus_ring

      if response.clicked?
        if ctx.popup_open?(@popup_id)
          ctx.close_popup(@popup_id)
        else
          ctx.open_popup(@popup_id)
          seed_draft(ctx)
        end
      end

      if ctx.popup_open?(@popup_id)
        # The flyout sizes from the WHEEL columns (month names are
        # wider than the field's numeric month), floored at the button.
        # Tight 3px inner padding — the wheels and the ✓/✕ footer hug
        # the frame edge-to-edge like the native flyout (the default
        # window padding left a thick frame around the grid).
        fly_w = wheel_ws.sum { |w| w + 2 * COL_PAD } + 2 * FLYOUT_PAD
        ctx.popup(@popup_id, ctx.dropdown_anchor(@popup_id, rect),
          width: fly_w, min_width: rect.width,
          pad: Vec2.new(FLYOUT_PAD, FLYOUT_PAD)) do |pop|
          flyout(pop, fonts, font_size, wheel_ws, &on_change)
        end
      end

      response
    end

    # The flyout: absolute wheel columns (like CalendarPicker's day
    # grid — no packing), the selection centered in row ROWS_SIDE, and
    # the ✓/✕ footer below. Time wheels carry an H/M/S header row
    # (like the calendar's weekday row). Everything edits the DRAFT;
    # only the footer's check fires the block.
    private def flyout(pop : Ui, fonts, font_size : Float64,
                       wheel_ws : Array(Float64), &on_change : Time ->) : Nil
      ctx = pop.ctx
      style = pop.style
      visuals = style.visuals
      row_h = {font_size * Fonts::LINE_H_FACTOR,
        style.spacing.interact_size.y}.max
      side = ROWS_SIDE
      list_h = (side * 2 + 1) * row_h
      foot_h = style.spacing.interact_size.y * FOOTER_H_FACTOR
      col_ws = wheel_ws.map { |w| w + 2 * COL_PAD }
      # Header row height: one row when any column has a header label
      # (the time wheels — three bare number columns read ambiguously),
      # none for the date wheels (month names/years are self-evident).
      head_h = @segments.any? { |seg| header_label(seg.kind) } ? row_h : 0.0
      content = Rect.from_min_size(
        Pos2.new(pop.cursor.x, pop.cursor.y + head_h),
        Vec2.new(col_ws.sum, list_h))
      footer = Rect.from_min_size(Pos2.new(content.left, content.bottom),
        Vec2.new(content.width, foot_h))

      # The header caps, faded like the calendar's weekday row.
      if head_h > 0.0
        color = visuals.fade_color(visuals.text_color)
        x = content.left
        @segments.each_with_index do |seg, ci|
          label = header_label(seg.kind).not_nil!
          tw = fonts.measure(label, font_size).x
          pop.painter.text(
            Pos2.new(x + (col_ws[ci] - tw) / 2.0,
              content.top - head_h / 2.0),
            label, font_size, color, family: style.font_family)
          x += col_ws[ci]
        end
      end

      # The center slot: selection band + hairlines across all columns.
      center = Rect.from_min_size(
        Pos2.new(content.left, content.top + side * row_h),
        Vec2.new(content.width, row_h))
      pop.painter.rect(center, 0.0,
        visuals.fade_color(visuals.selection_fill, 0.25))
      accent = visuals.fade_color(visuals.selection_fill, 0.7)
      pop.painter.line(Pos2.new(content.left, center.top),
        Pos2.new(content.right, center.top), 1.0, accent)
      pop.painter.line(Pos2.new(content.left, center.bottom),
        Pos2.new(content.right, center.bottom), 1.0, accent)

      # The draft outlives frames (Memory), so mark its cells used —
      # they have no #interact call of their own.
      ctx.memory.use_id(@pid.child(DRAFT_DATE))
      ctx.memory.use_id(@pid.child(DRAFT_TIME))
      cur = draft(ctx)

      x = content.left
      @segments.each_with_index do |seg, ci|
        col_id = @pid.child((ci + 1).to_u64)
        col_rect = Rect.from_min_size(Pos2.new(x, content.top),
          Vec2.new(col_ws[ci], list_h))
        x += col_ws[ci]
        range = range_of(seg.kind, cur)
        sel = selected_of(seg.kind, cur)

        # Wheel FIRST, and stepping IS selecting (WinUI): the item that
        # lands in the center row becomes the draft's value. The column
        # registers as a scroll sink, so the delta only arrives while
        # the pointer is over THIS column.
        ctx.memory.register_scroll_area(col_id, col_rect, pop.layer)
        if ctx.memory.active_scroll_area? == col_id &&
           (dy = ctx.input.scroll.y) != 0.0
          # scroll.y > 0 is wheel-down (next), < 0 wheel-up (previous)
          stepped = (sel + (dy > 0 ? 1 : -1)).clamp(range.begin, range.end)
          if stepped != sel
            cur = rebuild(seg.kind, stepped, cur)
            set_draft(ctx, cur)
            sel = stepped
            ctx.request_repaint
          end
        end

        fade = {1.0, 0.72, 0.5, 0.34}
        (-side..side).each do |d|
          v = sel + d
          next if v < range.begin || v > range.end
          cell = Rect.from_min_size(
            Pos2.new(col_rect.left + 2.0, content.top + (side + d) * row_h),
            Vec2.new(col_rect.width - 4.0, row_h))
          resp = pop.interact(cell, col_id.child((v - range.begin + 2).to_u64),
            Sense.click)
          if resp.hovered?
            pop.painter.rect(cell, 3.0,
              visuals.fade_color(visuals.selection_fill, 0.4))
          end
          label = wheel_label(seg.kind, v)
          tw = fonts.measure(label, font_size).x
          pop.painter.text(Pos2.new(cell.center.x - tw / 2.0, cell.center.y),
            label, font_size,
            visuals.fade_color(visuals.text_color, fade[d.abs]),
            family: style.font_family)
          if resp.clicked?
            cur = rebuild(seg.kind, v, cur)
            set_draft(ctx, cur)
            ctx.request_repaint
          end
        end
      end

      # Footer (Win11 flyout bottom bar): two half-width buttons split
      # by a hairline — ✓ commits the draft (one on_change, close), ✕
      # dismisses it (close, committed value untouched).
      weak = visuals.fade_color(visuals.text_color, 0.35)
      pop.painter.line(Pos2.new(footer.left, footer.top),
        Pos2.new(footer.right, footer.top), 1.0, weak)
      pop.painter.line(Pos2.new(footer.center.x, footer.top),
        Pos2.new(footer.center.x, footer.bottom), 1.0, weak)
      half = footer.width / 2.0
      buttons = {Rect.from_min_size(footer.min, Vec2.new(half, foot_h)),
                 @pid.child(ACCEPT_SALT), true}
      cross = {Rect.from_min_size(Pos2.new(footer.left + half, footer.top),
        Vec2.new(half, foot_h)), @pid.child(CANCEL_SALT), false}
      {buttons, cross}.each do |(brect, bid, accept)|
        resp = pop.interact(brect, bid, Sense.click)
        if resp.hovered? || resp.active?
          pop.painter.rect(brect, 0.0,
            visuals.button_fill(resp.hovered?, resp.active?))
        end
        s = {brect.width, brect.height}.min * 0.5
        box = Rect.from_min_size(
          Pos2.new(brect.center.x - s / 2.0, brect.center.y - s / 2.0),
          Vec2.new(s, s))
        Icons.draw(pop.painter, accept ? :check : :close, box,
          visuals.text_color, 2.0)
        if resp.clicked?
          ctx.close_popup(@popup_id)
          on_change.call(cur) if accept
        end
      end

      total = content.union(footer)
      total = total.union(Rect.from_min_size(
        Pos2.new(content.left, content.top - head_h),
        Vec2.new(content.width, head_h))) if head_h > 0.0
      pop.min_rect = pop.min_rect.union(total)
      pop.cursor = Pos2.new(pop.max_rect.min.x, total.bottom)
    end

    # --- draft (the value being edited while the flyout is open) ------

    # Two Int32 cells — ymd and hms — carry the draft across frames;
    # -1 marks "no draft" (midnight is a valid 0 hms, so not a flag).
    private def seed_draft(ctx : Context) : Nil
      set_draft(ctx, @value)
    end

    private def set_draft(ctx : Context, t : Time) : Nil
      ctx.memory.data.set_int(@pid.child(DRAFT_DATE),
        t.year * 10_000 + t.month * 100 + t.day)
      ctx.memory.data.set_int(@pid.child(DRAFT_TIME),
        t.hour * 10_000 + t.minute * 100 + t.second)
    end

    private def draft(ctx : Context) : Time
      ymd = ctx.memory.data.get_int(@pid.child(DRAFT_DATE), -1)
      hms = ctx.memory.data.get_int(@pid.child(DRAFT_TIME), -1)
      return @value if ymd < 0 || hms < 0
      Time.local(ymd // 10_000, ymd // 100 % 100, ymd % 100,
        hms // 10_000, hms // 100 % 100, hms % 100,
        location: @value.location)
    end

    # --- segment values --------------------------------------------------

    # Column header hint: the time wheels are three bare number columns,
    # so each carries a faded H/M/S cap over it (like the calendar's
    # weekday row); date columns are self-evident and stay bare.
    private def header_label(kind : Symbol) : String?
      case kind
      when :hour   then "H"
      when :minute then "M"
      when :second then "S"
      else
        nil
      end
    end

    private def range_of(kind : Symbol, base : Time) : Range(Int32, Int32)
      case kind
      when :day    then 1..days_in(base.year, base.month)
      when :month  then 1..12
      when :year   then YEAR_RANGE
      when :hour   then 0..23
      when :minute then 0..59
      else              0..59
      end
    end

    private def selected_of(kind : Symbol, base : Time) : Int32
      case kind
      when :day     then base.day
      when :month   then base.month
      when :year    then base.year
      when :hour    then base.hour
      when :minute  then base.minute
      else               base.second
      end
    end

    # The field shows numbers (matching the numeric formats); the wheel
    # spells months out (WinUI's flyout shows names).
    private def field_label(kind : Symbol) : String
      "%02d" % selected_of(kind, @value)
    end

    private def wheel_label(kind : Symbol, v : Int32) : String
      kind == :month ? CalendarPicker::MONTHS[v - 1] : "%02d" % v
    end

    private def field_width(fonts, font_size : Float64,
                            kind : Symbol) : Float64
      range_of(kind, @value).max_of { |v| fonts.measure("%02d" % v, font_size).x }
    end

    private def wheel_width(fonts, font_size : Float64,
                            kind : Symbol) : Float64
      range_of(kind, @value).max_of { |v| fonts.measure(wheel_label(kind, v), font_size).x }
    end

    # New value with one field replaced; day clamps to the target
    # month's length (leap-aware), the time-of-day is preserved.
    private def rebuild(kind : Symbol, v : Int32, base : Time) : Time
      year = base.year
      month = base.month
      day = base.day
      case kind
      when :year
        year = v
        day = {day, days_in(year, month)}.min
      when :month
        month = v
        day = {day, days_in(year, month)}.min
      when :day
        day = v
      end
      Time.local(year, month, day,
        kind == :hour ? v : base.hour,
        kind == :minute ? v : base.minute,
        kind == :second ? v : base.second,
        nanosecond: base.nanosecond, location: base.location)
    end

    private def days_in(year : Int32, month : Int32) : Int32
      Time.local(year, month, 1, location: @value.location)
        .at_end_of_month.day
    end
  end
end
