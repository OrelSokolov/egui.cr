# egui.cr-native container (no upstream counterpart): a full-window
# PAGE — the Win11 Notepad settings-page idiom, used for in-app
# routing ("an options screen as a page, not a modal").
#
#   # the app owns the route — the framework never manages navigation
#   reactive settings_open = false
#
#   def update(ctx)
#     if settings_open
#       ctx.page("settings", title: "Settings",
#         on_back: -> { self.settings_open = false; nil }) do |ui|
#         ui.label("…page content fills the window…")
#       end
#     else
#       …the normal UI (menu bar, tabs, central panel)…
#     end
#   end
#
# The page claims the WHOLE remainder below the window caption (the
# backend draws WindowFrame before app frames, so the caption strip
# with its drag area and control buttons is already excluded) and
# covers everything else — menu bar, tabs, panels — for the frame(s)
# it is shown in. It is NOT deferred like central_panel: a page is an
# alternative UI, not another panel in the same layout.
#
# Look (Win11 settings page): an opaque panel_fill surface, a 44pt
# header with a round 32×32 back button (Lucide chevron-left glyph,
# hover
# fill) and an 18pt title; the content block runs in a child Ui below
# the header. `title:`/`on_back:` are both optional — no header is
# drawn when neither is given.

module Egui
  class Page
    HEADER_H = 44.0 # header row (back button + title)
    BACK_D   = 32.0 # round back button diameter
    BACK_PAD = 8.0  # back button inset from the page's left edge
    TITLE_PT = 18.0 # page title font

    def self.show(ctx : Context, id : String, title : String? = nil,
                  on_back : (-> Nil)? = nil, fill : Color32? = nil,
                  &block : Ui ->) : Rect
      rect = ctx.available_rect.dup
      return rect if rect.width <= 0.0 || rect.height <= 0.0

      painter = ctx.painter
      style = ctx.style
      visuals = style.visuals

      # Opaque surface, no stroke (a stroked strip reads as bright
      # lines — see the menu bar lesson).
      painter.layer = Order::Background
      painter.clip = rect
      painter.rect(rect, 0.0, fill || visuals.panel_fill, nil, 0.0)

      header_h = (title || on_back) ? HEADER_H : 0.0

      # Header: round back button + title, centered in the row.
      if header_h > 0.0
        cy = rect.top + header_h / 2.0
        if on_back
          back_rect = Rect.from_min_size(
            Pos2.new(rect.left + BACK_PAD, cy - BACK_D / 2.0),
            Vec2.new(BACK_D, BACK_D))
          back = ctx.interact(Id.from("page/#{id}/back"),
            back_rect, Sense::Click,
            LayerId.new(Order::Middle, Id.from("page/#{id}")), back_rect)
          painter.layer = Order::Middle
          painter.clip = back_rect
          if back.hovered?
            painter.circle_filled(back_rect.center, BACK_D / 2.0,
              visuals.button_hovered)
          else
            painter.circle_stroke(back_rect.center, BACK_D / 2.0 - 1.0,
              visuals.window_stroke, 1.0)
          end
          icon = back_rect.shrink(BACK_D * 0.3)
          # Optical centering: a chevron's ink mass sits right of its
          # tip, so the geometrically centered glyph reads a touch too
          # far right in the round button — nudge it left.
          icon = Rect.from_min_size(
            Pos2.new(icon.left - 2.0, icon.top), icon.size)
          Icons.draw(painter, :left, icon, visuals.text_color, 2.0)
          on_back.call if back.clicked?
          ctx.request_repaint if back.clicked?
        end
        if (t = title)
          painter.layer = Order::Background
          painter.clip = rect
          tx = on_back ? rect.left + BACK_PAD + BACK_D + 12.0 :
                         rect.left + style.spacing.window_padding.x
          painter.text(Pos2.new(tx, cy), t, TITLE_PT, visuals.text_color)
        end
      end

      # Content: a child Ui over the rest of the page.
      pad = style.spacing.window_padding
      content = Rect.from_min_size(
        Pos2.new(rect.left, rect.top + header_h),
        Vec2.new(rect.width, rect.height - header_h))
      painter.clip = rect
      painter.layer = Order::Background
      ui = Ui.new(ctx, Id.from("page/#{id}"),
        content.shrink(pad.x), Layout.top_down)
      ui.clip = content
      yield ui

      painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
      rect
    end
  end

  class Context
    # A full-window page below the caption (see `Egui::Page`). The
    # app owns navigation — this only renders the page it is asked
    # for. `title:` draws the header title; `on_back:` arms the round
    # back button and fires the callback on click. The page bites the
    # whole remainder, like any other panel — but only AFTER the
    # deferred central panel registered inside it is flushed, so a
    # page containing ctx-level panels behaves like a frame of its own.
    def page(id : String, title : String? = nil,
             on_back : (-> Nil)? = nil, fill : Color32? = nil,
             &block : Ui ->) : Rect
      rect = Page.show(ctx: self, id: id, title: title, on_back: on_back,
        fill: fill) { |ui| block.call(ui) }
      flush_central_panel
      @available_rect = Rect.new(
        Pos2.new(@available_rect.min.x, rect.bottom), @available_rect.max)
      rect
    end
  end
end
