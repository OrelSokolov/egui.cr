# Port of egui_extras' DatePicker (crates/egui_extras/src/datepicker/)
# — slimmed to the classic form: a button showing the date, opening a
# calendar popup (‹ month year › header, weekday row, day grid, Today).
# The shown month persists in `Memory#data` keyed by the picker id; the
# selection is app state handed back through the block, like `#slider`.
#
#   ui.date_picker("born", @date) { |t| @date = t }

module Egui
  class DatePicker
    include Widget

    @on_change : Time ->

    def initialize(id : String, @value : Time,
                   @format : String = "%Y-%m-%d",
                   &@on_change : Time ->)
      @pid = Id.from("date_picker/#{id}")
      @popup_id = "date_picker/#{id}"
    end

    # Widget entry point (`ui.add`) — wires the stored callback into
    # #show; direct callers may use `show(ui) { |t| … }`.
    def ui(ui : Ui) : Response
      show(ui, &@on_change)
    end

    def show(ui : Ui, &on_change : Time ->) : Response
      ctx = ui.ctx
      style = ui.style
      text = @value.to_s(@format)
      text_size = ctx.fonts.measure(text, style.font_size)
      pad = style.spacing.button_padding
      height = {text_size.y + 2 * pad.y, style.spacing.interact_size.y}.max
      rect = ui.allocate_at_least(Vec2.new(text_size.x + 2 * pad.x, height))
      response = ui.interact(rect, @pid, Sense.click | Sense::Focusable)

      visuals = style.visuals
      if ctx.popup_open?(@popup_id)
        painter_fill = visuals.selection_fill
      elsif response.hovered?
        painter_fill = visuals.button_fill(true, response.active?)
      else
        painter_fill = visuals.button_fill(false, false)
      end
      ui.painter.rect(rect, 4.0, painter_fill,
        visuals.border_color, 1.0)
      ui.painter.text(Pos2.new(rect.left + pad.x, rect.center.y),
        text, style.font_size, visuals.text_color)
      response.paint_focus_ring

      if response.clicked?
        if ctx.popup_open?(@popup_id)
          ctx.close_popup(@popup_id)
        else
          # seed the calendar with the selection's month
          ctx.memory.data.set_int(@pid.child(1), @value.year)
          ctx.memory.data.set_int(@pid.child(2), @value.month)
          ctx.open_popup(@popup_id)
        end
      end

      if ctx.popup_open?(@popup_id)
        # Anchored to the button rect (not a point): near the screen
        # bottom the popup flips open above it (Context#popup), so the
        # calendar never renders off-screen. The width is exactly the
        # calendar grid plus the frame padding — every row reports the
        # same grid width back to min_rect, so the popup never
        # re-snaps to a measured size and nothing shifts between
        # frames.
        grid_w = COLS * CELL + 2 * ctx.style.spacing.window_padding.x
        ctx.popup(@popup_id, rect, width: grid_w) do |popup|
          calendar(popup, on_change)
        end
      end

      response
    end

    # The calendar is laid out on one shared grid: `COLS` cells of
    # `CELL` px flush against the popup's inner left edge. The weekday
    # header, the day rows and the popup width all align to these
    # columns — anything sized per-widget (a generic horizontal row
    # with item spacing, or the popup's snap-to-measured width) would
    # drift off them.
    CELL = 30.0
    COLS = 7
    WEEKDAYS = {"Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"}

    # Left edge of grid column `col`.
    private def cell_x(ui : Ui, col : Int32) : Float64
      ui.max_rect.min.x + col * CELL
    end

    # Report one full grid-width row to the popup's min_rect — every
    # row is exactly `COLS * CELL` wide, which is what keeps the popup
    # width stable frame to frame.
    private def union_row(ui : Ui, y : Float64, h : Float64) : Nil
      ui.min_rect = ui.min_rect.union(
        Rect.from_min_size(Pos2.new(ui.max_rect.min.x, y),
          Vec2.new(COLS * CELL, h)))
    end

    private def calendar(ui : Ui, on_change : Time ->) : Nil
      ctx = ui.ctx
      mem = ctx.memory
      style = ui.style
      visuals = style.visuals
      font_size = style.font_size
      loc = @value.location

      year = mem.data.get_int(@pid.child(1), @value.year)
      month = mem.data.get_int(@pid.child(2), @value.month)
      # The shown month/year cells have no #interact call of their own —
      # mark them used so they survive end-frame pruning (like Plot's
      # bounds or Grid's column widths).
      mem.use_id(@pid.child(1))
      mem.use_id(@pid.child(2))
      first = Time.local(year, month, 1, location: loc)
      days = first.at_end_of_month.day
      # Monday-first offset of the 1st
      offset = first.day_of_week.value - 1

      header(ui, year, month) do |delta|
        m = month + delta
        y = year
        while m < 1
          m += 12
          y -= 1
        end
        while m > 12
          m -= 12
          y += 1
        end
        mem.data.set_int(@pid.child(1), y)
        mem.data.set_int(@pid.child(2), m)
      end

      # weekday row — same cell geometry as the day grid below, so the
      # day names sit exactly over their columns (a generic horizontal
      # row would space them by label width + item spacing instead)
      week_y = ui.cursor.y
      week_h = font_size * Fonts::LINE_H_FACTOR
      WEEKDAYS.each_with_index do |name, col|
        tw = ctx.fonts.measure(name, font_size).x
        ui.painter.text(
          Pos2.new(cell_x(ui, col) + (CELL - tw) / 2.0, week_y + week_h / 2.0),
          name, font_size, visuals.text_color)
      end
      union_row(ui, week_y, week_h)
      ui.cursor = Pos2.new(ui.max_rect.min.x, week_y + week_h)

      # day grid: full rows of `COLS` cells, flush (no item spacing) —
      # the popup hugs the grid.
      today = Time.local.in(loc)
      cell_h = {font_size * Fonts::LINE_H_FACTOR,
        style.spacing.interact_size.y}.max
      (0..5).each do |week|
        row_done = false
        COLS.times do |col|
          day = week * COLS + col - offset + 1
          if day < 1 || day > days
            next # empty leading/trailing cells
          end
          cell = Rect.from_min_size(Pos2.new(cell_x(ui, col), ui.cursor.y),
            Vec2.new(CELL, cell_h))
          day_id = @pid.child((day + 100).to_u64)
          response = ui.interact(cell, day_id, Sense.click)
          date = Time.local(year, month, day, 12, 0, 0, location: loc)
          if same_day?(date, @value)
            ui.painter.rect(cell, 3.0, visuals.selection_fill)
          elsif response.hovered?
            ui.painter.rect(cell, 3.0,
              visuals.fade_color(visuals.selection_fill, 0.4))
          end
          color = visuals.text_color
          color = visuals.hyperlink_color if same_day?(date, today)
          label = day.to_s
          tw = ctx.fonts.measure(label, font_size).x
          ui.painter.text(
            Pos2.new(cell.center.x - tw / 2.0, cell.center.y),
            label, font_size, color)
          if response.clicked?
            on_change.call(date)
            ctx.close_popup(@popup_id)
          end
          row_done = true
        end
        # An entirely empty trailing week (a 28-day February starting
        # Monday) advances nothing — no phantom row pads the popup.
        next unless row_done
        union_row(ui, ui.cursor.y, cell_h)
        ui.cursor = Pos2.new(ui.max_rect.min.x, ui.cursor.y + cell_h)
      end

      if small_button(ui, @pid.child(0xEE_u64), "Today")
        on_change.call(Time.local.in(loc))
        ctx.close_popup(@popup_id)
      end
    end

    # Same calendar day regardless of time-of-day (for the picker's
    # selected/today highlights).
    private def same_day?(a : Time, b : Time) : Bool
      a.year == b.year && a.month == b.month && a.day == b.day
    end

    # Header: ‹ and › pinned to the popup's inner edges so they don't
    # jump when a shorter/longer month title changes the row's layout;
    # the title is centered between them. Absolute placement + manual
    # cursor advance — the same idiom the day grid uses.
    private def header(ui : Ui, year : Int32, month : Int32,
                       &shift : Int32 ->) : Nil
      ctx = ui.ctx
      style = ui.style
      font_size = style.font_size
      title = "#{MONTHS[month - 1]} #{year}"
      title_w = ctx.fonts.measure(title, font_size).x

      h = style.spacing.interact_size.y
      bw = {ctx.fonts.measure("‹", font_size).x + 16.0, h}.max
      width = ui.max_rect.width
      top = ui.cursor
      left = Rect.from_min_size(top, Vec2.new(bw, h))
      right = Rect.from_min_size(Pos2.new(top.x + width - bw, top.y),
        Vec2.new(bw, h))

      shift.call(-1) if button_at(ui, @pid.child(0xE0_u64), "‹", left)
      ui.painter.text(
        Pos2.new(top.x + (width - title_w) / 2.0, top.y + h / 2.0),
        title, font_size, style.visuals.text_color)
      shift.call(1) if button_at(ui, @pid.child(0xE1_u64), "›", right)

      union_row(ui, top.y, h)
      ui.cursor = Pos2.new(ui.max_rect.min.x, top.y + h)
    end

    MONTHS = {"January", "February", "March", "April", "May", "June",
              "July", "August", "September", "October", "November",
              "December"}

    private def small_button(ui : Ui, id : Id, text : String) : Bool
      ctx = ui.ctx
      style = ui.style
      text_size = ctx.fonts.measure(text, style.font_size)
      size = Vec2.new(
        {text_size.x + 16.0, style.spacing.interact_size.y}.max,
        style.spacing.interact_size.y)
      button_at(ui, id, text, ui.allocate_at_least(size))
    end

    # A header button painted into an explicit rect (the arrows are
    # pinned by #header; #small_button allocates one for "Today").
    private def button_at(ui : Ui, id : Id, text : String, rect : Rect) : Bool
      ctx = ui.ctx
      style = ui.style
      text_size = ctx.fonts.measure(text, style.font_size)
      response = ui.interact(rect, id, Sense.click)
      if response.hovered?
        ui.painter.rect(rect, 3.0, style.visuals.button_hovered)
      end
      ui.painter.text(
        Pos2.new(rect.center.x - text_size.x / 2.0, rect.center.y),
        text, style.font_size, style.visuals.text_color)
      response.clicked?
    end
  end
end
