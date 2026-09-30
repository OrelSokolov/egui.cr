# Windows XP (Luna) modal dialog for the Paint demo — the look
# `Context#window` can't render: the gradient caption with a glossy
# red close button, the blue window frame, the #ECE9D8 body and real
# XP push buttons (75×23, bottom-right). Caption/frame colors are
# shared with the main window's chrome (WindowFrame::WindowsXp).
#
# Modal like the OS originals: everything below is blocked
# (`Memory#mark_modal`) but there is no scrim — XP disables the
# parent window instead of dimming it.

module PaintXp
  class Dialog
    CAPTION_H    = 25.0 # Luna dialog titlebar height
    FRAME_W      = 3.0  # blue frame on the sides/bottom
    OUTLINE_W    = 1.0  # navy ring around the whole window
    PAD          = 11.0 # body inset (the classic 7-dlg-unit margin)
    BTN_W        = 75.0 # XP push button default size
    BTN_H        = 23.0
    BTN_GAP      = 6.0
    BTN_TOP_GAP  = 14.0 # air between the content and the button row
    BTN_BOTTOM   = 11.0 # air under the button row
    TITLE_PAD    = 8.0
    TITLE_PT     = 12.0
    CLOSE_BTN    = 18.0 # glossy close button box
    CLOSE_INSET  = 3.0

    # Returned instead of a button label when the caption ✕ (or Esc)
    # closes the dialog.
    CLOSE = "✕"

    # Dialog face (#f8f6e7 — lighter than the panels' #ECE9D8, the
    # jspaint/xp dialog background).
    FACE = Egui::Color32.rgb(248, 246, 231)

    # Luna push button: light gradient with a navy ring, the XP orange
    # glow on hover, sunken fill on press.
    PB_TOP      = Egui::Color32.rgb(255, 255, 255)
    PB_BOTTOM   = Egui::Color32.rgb(238, 235, 218)
    PB_RING     = Egui::Color32.rgb(0, 60, 116)
    PB_HOT_TOP  = Egui::Color32.rgb(255, 243, 200)
    PB_HOT_BOT  = Egui::Color32.rgb(255, 222, 155)
    PB_HOT_RING = Egui::Color32.rgb(198, 119, 0)
    PB_DOWN_TOP = Egui::Color32.rgb(224, 220, 200)
    PB_DOWN_BOT = Egui::Color32.rgb(205, 200, 176)

    def initialize(@ctx : Egui::Context, @key : String)
    end

    # Show the dialog centered on the window (draggable by the caption,
    # position persists until closed). Returns the label of the button
    # clicked this frame — CLOSE for the caption ✕ / Esc — or nil.
    def show(title : String, width : Float64,
             buttons : Array(String) = [] of String,
             &body : Egui::Ui ->) : String?
      ctx = @ctx
      ctx.memory.mark_modal
      id = Egui::Id.from("paint_dialog/#{@key}")
      layer = Egui::LayerId.new(Egui::Order::Foreground, id)
      screen = ctx.input.screen_rect
      p = ctx.painter

      # Centered on the parent using the last measured size; the
      # position sticks once dragged (Areas, like Context#window).
      prev = ctx.memory.layer_sizes[id]? || Egui::Vec2.new(width, 180.0)
      pos = ctx.memory.areas.pos_for(id, Egui::Pos2.new(
        screen.center.x - prev.x / 2.0, screen.center.y - prev.y / 2.0))

      # --- content first (auto-fit height, like Context#window) -------
      p.layer = Egui::Order::Foreground
      p.clip = Egui::Rect.from_min_size(pos, Egui::Vec2.new(width, 1e6))
      # Two back-patch slots UNDER the content (within one layer, push
      # order == paint order): the blue window base and the FACE body
      # fill — both would otherwise cover the widgets, being sized only
      # after the content is measured.
      shadow_slot = p.add_noop # drop shadow: FIRST — the backend fills
      # the caster silhouette solid, it must land under the base/body
      base_slot = p.add_noop
      body_fill_slot = p.add_noop
      content_min = pos + Egui::Vec2.new(
        OUTLINE_W + FRAME_W + PAD, OUTLINE_W + CAPTION_H + PAD)
      ui = Egui::Ui.new(ctx, id.child(Egui::Id.from("body").value),
        Egui::Rect.from_min_size(content_min, Egui::Vec2.new(width - 2 * PAD, 1e6)))
      ui.layer = layer
      ui.clip = Egui::Rect.from_min_size(pos, Egui::Vec2.new(width, 1e6))
      body.call(ui)

      foot_h = buttons.empty? ? PAD : BTN_TOP_GAP + BTN_H + BTN_BOTTOM
      outer = Egui::Rect.new(
        pos,
        Egui::Pos2.new(
          {ui.min_rect.right + PAD + FRAME_W + OUTLINE_W, pos.x + width}.max,
          ui.min_rect.bottom + foot_h + FRAME_W + OUTLINE_W))

      # Keep the whole dialog inside the window (Context#window's
      # constrain), then remember the position for the next frame.
      if screen.width > 0.0
        x = pos.x.clamp(screen.left,
          {screen.right - outer.width, screen.left}.max)
        y = pos.y.clamp(screen.top,
          {screen.bottom - outer.height, screen.top}.max)
        shift = Egui::Vec2.new(x - pos.x, y - pos.y)
        if shift.x.abs > 0.01 || shift.y.abs > 0.01
          pos += shift
          outer = Egui::Rect.new(pos, outer.max + shift)
          ctx.memory.areas.set_pos(id, pos)
        end
      end

      inner = outer.shrink(OUTLINE_W)
      caption = Egui::Rect.from_min_size(
        Egui::Pos2.new(inner.left, inner.top),
        Egui::Vec2.new(inner.width, CAPTION_H))
      body_rect = Egui::Rect.new(
        Egui::Pos2.new(inner.left, caption.bottom),
        Egui::Pos2.new(inner.right, inner.bottom - FRAME_W))

      clicked = nil

      # --- caption: drag + close -------------------------------------
      title_rect = Egui::Rect.from_min_size(
        pos, Egui::Vec2.new(outer.width, OUTLINE_W + CAPTION_H))
      drag = ctx.interact(id.child(0_u64), title_rect,
        Egui::Sense.click_and_drag, layer, outer)
      if drag.dragged?
        ctx.memory.areas.move_by(id, drag.drag_delta)
        ctx.request_repaint
      end
      close_r = Egui::Rect.from_min_size(
        Egui::Pos2.new(inner.right - CLOSE_INSET - CLOSE_BTN,
          inner.top + (CAPTION_H - CLOSE_BTN) / 2.0),
        Egui::Vec2.new(CLOSE_BTN, CLOSE_BTN))
      close = ctx.interact(id.child(1_u64), close_r, Egui::Sense::Click,
        layer, outer)
      clicked = CLOSE if close.clicked?

      # --- the shell --------------------------------------------------
      p.clip = outer.shrink(-16.0) # let the drop shadow bleed out
      p.set(shadow_slot, Egui::ShadowCmd.new(outer.shrink(-16.0), outer,
        0.0, 10.0, 0.0, Egui::Vec2.new(0.0, 4.0),
        Egui::Color32.rgba(0, 0, 0, 70), false))
      # window base: blue frame fill + the navy outline ring, back-
      # patched UNDER the content (see base_slot above)
      p.set(base_slot, Egui::RectCmd.new(outer, outer, 0.0,
        Egui::WindowFrame::WindowsXp::FRAME, Egui::WindowFrame::WindowsXp::FRAME_OUTER, 1.0))
      # Luna caption: deep gradient with the bright band on top
      p.rect_gradient(caption, 0.0, Egui::WindowFrame::WindowsXp::CAP_MID, Egui::WindowFrame::WindowsXp::CAP_DEEP)
      band_h = {CAPTION_H * 0.35, 2.0}.max
      p.rect_gradient(Egui::Rect.from_min_size(
        caption.min, Egui::Vec2.new(caption.width, band_h)),
        0.0, Egui::WindowFrame::WindowsXp::CAP_LIGHT, Egui::WindowFrame::WindowsXp::CAP_MID)
      # title with the Luna soft shadow
      tp = Egui::Pos2.new(caption.left + TITLE_PAD, caption.center.y)
      p.text(tp + Egui::Vec2.new(1.0, 1.0), title, TITLE_PT, Egui::WindowFrame::WindowsXp::TITLE_SHADOW)
      p.text(tp, title, TITLE_PT, Egui::Color32.rgb(255, 255, 255))
      # body: FACE fill (under the content, via the reserved slot) and
      # the light hairline where the frame meets the client area
      p.set(body_fill_slot, Egui::RectCmd.new(body_rect, body_rect,
        0.0, FACE, nil, 0.0))
      p.rect(body_rect, 0.0, nil, Egui::WindowFrame::WindowsXp::FRAME_INNER, 1.0)

      # glossy red close button (the main window's caption style)
      top, bottom = if close.active? && close.hovered?
                      {Egui::WindowFrame::WindowsXp::CLOSE_DOWN_TOP, Egui::WindowFrame::WindowsXp::CLOSE_DOWN_BOT}
                    elsif close.hovered?
                      {Egui::WindowFrame::WindowsXp::CLOSE_HOT_TOP, Egui::WindowFrame::WindowsXp::CLOSE_HOT_BOT}
                    else
                      {Egui::WindowFrame::WindowsXp::CLOSE_TOP, Egui::WindowFrame::WindowsXp::CLOSE_BOTTOM}
                    end
      p.rect(close_r, 3.0, top, Egui::WindowFrame::WindowsXp::CLOSE_RING, 1.0, bottom)
      c = close_r.center
      g = CLOSE_BTN / 4.0 - 1.0
      white = Egui::Color32.rgb(255, 255, 255)
      p.line(Egui::Pos2.new(c.x - g, c.y - g), Egui::Pos2.new(c.x + g, c.y + g),
        1.5, white)
      p.line(Egui::Pos2.new(c.x + g, c.y - g), Egui::Pos2.new(c.x - g, c.y + g),
        1.5, white)

      # --- XP push buttons, bottom-right ------------------------------
      buttons.each_with_index do |label, i|
        bx = inner.right - PAD - (buttons.size - i) * BTN_W -
             (buttons.size - 1 - i) * BTN_GAP
        rect = Egui::Rect.from_min_size(
          Egui::Pos2.new(bx, body_rect.bottom - BTN_BOTTOM - BTN_H),
          Egui::Vec2.new(BTN_W, BTN_H))
        resp = ctx.interact(Egui::Id.from("paint_dialog/#{@key}/btn/#{i}"),
          rect, Egui::Sense::Click, layer, outer)
        clicked = label if resp.clicked?
        ring = resp.hovered? && !(resp.active? && resp.hovered?) ?
               PB_HOT_RING : PB_RING
        top, bottom = if resp.active? && resp.hovered?
                        {PB_DOWN_TOP, PB_DOWN_BOT}
                      elsif resp.hovered?
                        {PB_HOT_TOP, PB_HOT_BOT}
                      else
                        {PB_TOP, PB_BOTTOM}
                      end
        p.rect(rect, 3.0, top, ring, 1.0, bottom)
        tw = ctx.fonts.measure(label, 14.0).x
        p.text(Egui::Pos2.new(rect.center.x - tw / 2.0, rect.center.y),
          label, 14.0, Egui::Color32.rgb(0, 0, 0))
      end

      # --- keyboard: Esc closes, Enter pushes the default button ------
      clicked = CLOSE if ctx.input.key_pressed?(Egui::KeyCode::Escape)
      clicked = buttons.first if clicked.nil? && !buttons.empty? &&
                                ctx.input.key_pressed?(Egui::KeyCode::Enter)

      ctx.memory.layer_sizes[id] = outer.size
      p.layer = Egui::Order::Background
      p.clip = Egui::Rect.new(Egui::Pos2.new(-1e9, -1e9),
        Egui::Pos2.new(1e9, 1e9))
      clicked
    end
  end
end
