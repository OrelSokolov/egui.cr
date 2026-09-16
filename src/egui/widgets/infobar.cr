# egui.cr-native InfoBar (no upstream counterpart) — a Rails-style
# flash message: a full-width colored bar with a level icon, the
# message, and an optional dismiss X. The app owns the message
# Rails-style (`@flash : String?`); the widget only owns the
# first-shown timestamp (so `auto_hide` can expire) in IdTypeMap,
# reset whenever the message text changes.
#
# Levels: :info (theme accent), :success, :warning, :error — all with
# white text/icons on saturated fills. While hidden (X clicked or
# `auto_hide` elapsed) the widget paints nothing, allocates zero
# height, and reports `Response#changed?` once so the app can drop
# the message.

module Egui
  class InfoBar
    include Widget

    LEVELS = {:info, :success, :warning, :error}

    # Fixed level fills (all carry white text/icons well on both the
    # dark and light theme); :info follows the theme accent instead.
    SUCCESS_FILL = Color32.rgb(56, 142, 60)
    WARNING_FILL = Color32.rgb(204, 143, 17)
    ERROR_FILL   = Color32.rgb(198, 40, 40)

    def initialize(@message : String, @level : Symbol = :info,
                   @dismissible : Bool = true,
                   @auto_hide : Float64? = nil)
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      fonts = ui.ctx.fonts
      font_size = style.font_size
      pad = style.spacing.button_padding
      id = ui.next_widget_id
      data = ui.ctx.memory.data

      # First-shown bookkeeping for auto_hide (reset on a new message).
      # No #interact call of their own → mark the cells used so they
      # survive end-frame pruning (the Grid trick).
      now = ui.ctx.input.time
      shown_at = data.get_f64(id.child(0), -1.0)
      if data.get_string(id.child(1), "") != @message
        data.set_string(id.child(1), @message)
        data.set_f64(id.child(0), now)
        shown_at = now
      end
      ui.ctx.memory.use_id(id.child(0))
      ui.ctx.memory.use_id(id.child(1))

      # Hidden state: nothing painted, zero height, changed? = true so
      # the app can clear the message (once — after that the widget
      # stops being created).
      if (ah = @auto_hide) && shown_at >= 0.0 && now - shown_at >= ah
        rect = ui.allocate_at_least(Vec2.new(ui.available_width, 0.0))
        response = ui.interact(rect, id, Sense.none)
        response.mark_changed
        return response
      end

      visuals = style.visuals
      fill = level_fill(visuals)
      text_size = fonts.measure(@message, font_size)
      height = {text_size.y + pad.y * 2.0,
                 style.spacing.interact_size.y}.max

      rect = ui.allocate_at_least(Vec2.new(ui.available_width, height))

      # Dismiss X lives in a nested interact AFTER the bar itself (the
      # Sidebar/TabBar pattern: the later widget eats the click).
      x_size = text_size.y * 0.66
      x_rect : Rect? = nil
      x_response : Response? = nil
      if @dismissible
        x_rect = Rect.from_min_size(
          Pos2.new(rect.right - pad.x - x_size,
            rect.center.y - x_size / 2.0),
          Vec2.new(x_size, x_size))
      end

      response = ui.interact(rect, id, Sense.click)
      x_response = ui.interact(x_rect, id.child(2), Sense.click) if x_rect

      ui.painter.rect(rect, 4.0, fill)

      # Level icon: a stroked circle with the level glyph inside —
      # all vector (Icons / painter primitives), no font coverage
      # needed for ✓/✕-style characters.
      icon_r = text_size.y * 0.55
      icon_center = Pos2.new(rect.left + pad.x + icon_r, rect.center.y)
      icon_color = Color32.new(255, 255, 255, 255)
      ui.painter.circle_stroke(icon_center, icon_r, icon_color, 1.5)
      case @level
      when :info
        ui.painter.circle_filled(icon_center, icon_r * 0.32, icon_color)
      when :success
        Icons.draw(ui.painter, :check,
          Rect.from_min_size(Pos2.new(icon_center.x - icon_r * 0.6,
            icon_center.y - icon_r * 0.6), Vec2.new(icon_r * 1.2, icon_r * 1.2)),
          icon_color)
      when :warning
        ui.painter.line(Pos2.new(icon_center.x, icon_center.y - icon_r * 0.5),
          Pos2.new(icon_center.x, icon_center.y + icon_r * 0.15), 2.0,
          icon_color)
        ui.painter.circle_filled(
          Pos2.new(icon_center.x, icon_center.y + icon_r * 0.5),
          1.4, icon_color)
      when :error
        Icons.draw(ui.painter, :close,
          Rect.from_min_size(Pos2.new(icon_center.x - icon_r * 0.5,
            icon_center.y - icon_r * 0.5), Vec2.new(icon_r, icon_r)),
          icon_color)
      end

      text_x = icon_center.x + icon_r + style.spacing.icon_spacing
      ui.painter.text(Pos2.new(text_x, rect.center.y), @message,
        font_size, Color32.new(255, 255, 255, 255))

      if (xr = x_rect) && (xresp = x_response)
        if xresp.hovered?
          ui.painter.rect(xr, 3.0, Color32.new(255, 255, 255, 60))
        end
        Icons.draw(ui.painter, :close, xr, icon_color)
        if xresp.clicked?
          response.mark_changed # dismissed — the app clears the message
        end
      end

      response
    end

    private def level_fill(visuals : Visuals) : Color32
      case @level
      when :success then SUCCESS_FILL
      when :warning then WARNING_FILL
      when :error   then ERROR_FILL
      else               visuals.selection_fill # :info — theme accent
      end
    end

  end

  class Ui
    # `ui.infobar(message, level: :info) { … }` — shows an InfoBar
    # (Rails flash message). The block fires when the bar dismissed
    # itself this frame (X clicked or `auto_hide` seconds elapsed
    # since the message first appeared) — the app clears its flash.
    def infobar(message : String, level : Symbol = :info,
                auto_hide : Float64? = nil, &on_dismiss : ->) : Response
      response = add(InfoBar.new(message, level, auto_hide: auto_hide))
      yield if response.changed?
      response
    end
  end
end
