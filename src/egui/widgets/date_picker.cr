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
      fonts = ctx.fonts_for(style.font_family)
      text = @value.to_s(@format)
      text_size = fonts.measure(text, style.font_size)
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
        visuals.button_stroke, 1.0)
      ui.painter.text(Pos2.new(rect.left + pad.x, rect.center.y),
        text, style.font_size, visuals.text_color, family: style.font_family)
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
        # Anchor below the button like combo boxes/menus (upstream), but
        # flip above it when the screen runs out below — the popup must
        # not cover its own toggle either way.
        ctx.popup(@popup_id, ctx.dropdown_anchor(@popup_id, rect),
          width: 7 * CELL + 24.0) do |popup|
          calendar(popup, on_change)
        end
      end

      response
    end

    CELL = 30.0

    private def calendar(ui : Ui, on_change : Time ->) : Nil
      ctx = ui.ctx
      mem = ctx.memory
      style = ui.style
      visuals = style.visuals
      font_size = style.font_size
      loc = @value.location

      year = mem.data.get_int(@pid.child(1), @value.year)
      month = mem.data.get_int(@pid.child(2), @value.month)
      # The year/month cells have no #interact of their own, so mark them
      # used — otherwise end-frame pruning drops them and the shown month
      # resets to the selection's on the next frame.
      mem.use_id(@pid.child(1))
      mem.use_id(@pid.child(2))
      first = Time.local(year, month, 1, location: loc)
      days = first.at_end_of_month.day
      # Monday-first offset of the 1st
      offset = first.day_of_week.value - 1

      header(popup: ui, year: year, month: month) do |delta|
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

      cell_h = {font_size * Fonts::LINE_H_FACTOR,
        style.spacing.interact_size.y}.max

      # weekday row — same absolute 7×CELL columns as the day grid, so
      # the names line up with the day cells below (a plain #horizontal
      # would pack them to the left with item spacing instead).
      weekdays = {"Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"}
      color = visuals.fade_color(visuals.text_color)
      fonts = ctx.fonts_for(style.font_family)
      7.times do |col|
        label = weekdays[col]
        tw = fonts.measure(label, font_size).x
        ui.painter.text(
          Pos2.new(ui.cursor.x + col * CELL + (CELL - tw) / 2.0,
            ui.cursor.y + cell_h / 2.0),
          label, font_size, color, family: style.font_family)
      end
      ui.min_rect = ui.min_rect.union(
        Rect.from_min_size(Pos2.new(ui.cursor.x, ui.cursor.y),
          Vec2.new(7 * CELL, cell_h)))
      ui.cursor = Pos2.new(ui.max_rect.min.x, ui.cursor.y + cell_h)

      # day grid: absolute cells, flush rows (no item spacing), like
      # menu_item — the popup hugs the grid. Always laid out as 6 week
      # rows (trailing ones empty when they fit) so the popup keeps the
      # same size for every month — it must not move under the cursor.
      today = Time.local.in(loc)
      (0..5).each do |week|
        7.times do |col|
          day = week * 7 + col - offset + 1
          if day < 1 || day > days
            next # empty leading/trailing cells
          end
          x = ui.cursor.x + col * CELL
          y = ui.cursor.y
          cell = Rect.from_min_size(Pos2.new(x, y), Vec2.new(CELL, cell_h))
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
          tw = fonts.measure(label, font_size).x
          ui.painter.text(
            Pos2.new(cell.center.x - tw / 2.0, cell.center.y),
            label, font_size, color, family: style.font_family)
          if response.clicked?
            on_change.call(date)
            ctx.close_popup(@popup_id)
          end
        end
        ui.min_rect = ui.min_rect.union(
          Rect.from_min_size(Pos2.new(ui.cursor.x, ui.cursor.y),
            Vec2.new(7 * CELL, cell_h)))
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

    # Header: ‹ pinned to the row's left edge, › to its right edge, the
    # month title centered between them — a plain #horizontal packs all
    # three to the left, so the title and › are placed by hand via the
    # row cursor (like the day grid's absolute cells).
    private def header(popup : Ui, year : Int32, month : Int32,
                       &shift : Int32 ->) : Nil
      title = "#{MONTHS[month - 1]} #{year}"
      popup.horizontal do |row|
        if small_button(row, @pid.child(0xE0_u64), "‹")
          shift.call(-1)
        end
        ctx = row.ctx
        font_size = row.style.font_size
        tw = ctx.fonts_for(row.style.font_family).measure(title, font_size).x
        row.cursor = Pos2.new(row.max_rect.center.x - tw / 2.0, row.cursor.y)
        row.label(title)
        aw = small_button_size(row, "›").x
        row.cursor = Pos2.new(row.max_rect.right - aw, row.cursor.y)
        if small_button(row, @pid.child(0xE1_u64), "›")
          shift.call(1)
        end
      end
    end

    MONTHS = {"January", "February", "March", "April", "May", "June",
              "July", "August", "September", "October", "November",
              "December"}

    # Shared size for the header/Today buttons — at least square with
    # the interact height, so the narrow ‹ › glyphs stay comfortably
    # clickable (bare glyph padding made the arrows tiny).
    private def small_button_size(ui : Ui, text : String) : Vec2
      tw = ui.fonts.measure(text, ui.style.font_size).x
      h = ui.style.spacing.interact_size.y
      Vec2.new({tw + 12.0, h}.max, h)
    end

    private def small_button(ui : Ui, id : Id, text : String) : Bool
      ctx = ui.ctx
      style = ui.style
      text_size = ui.fonts.measure(text, style.font_size)
      rect = ui.allocate_at_least(small_button_size(ui, text))
      response = ui.interact(rect, id, Sense.click)
      if response.hovered?
        ui.painter.rect(rect, 3.0, style.visuals.button_hovered)
      end
      ui.painter.text(
        Pos2.new(rect.center.x - text_size.x / 2.0, rect.center.y),
        text, style.font_size, style.visuals.text_color,
        family: style.font_family)
      response.clicked?
    end
  end
end
