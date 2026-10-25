# An image by URL — the fetch-decode-upload pipeline of
# `Context#load_image_url` behind an `Image`-shaped widget:
#
#   ui.remote_image("https://…/logo.png")
#   ui.remote_image("https://…/photo.jpg", Egui::Vec2.new(320, 200))
#
# While the fetch runs the widget shows a placeholder with a centered
# spinner (and keeps the runtime awake with repaint requests); a
# failed URL (network error, non-2xx, undecodable data) degrades to
# the same weak placeholder `Image` uses for failed loads — the error
# is on `ctx.url_images[url].error`.
#
# Sizing: an explicit `size` is the widget's BOX — the layout keeps it
# stable while the image loads. The decoded texture is fitted INTO it
# preserving the aspect ratio (`fit: true`, the default: contain,
# centered — a 544×184 logo in a 320×200 box draws 320×108), or
# stretched to fill the whole box (`fit: false`, upstream `Image`
# semantics). Without a size the widget adopts the decoded pixel
# size, falling back to a 100×100 placeholder until the bytes land.
#
# One fetch per URL per Context (the cache dedups); every widget
# showing the same URL shares the single texture.

module Egui
  class RemoteImage
    include Widget

    # Drawn size before the decoded size is known (no explicit size).
    PLACEHOLDER = Vec2.new(100.0, 100.0)

    def initialize(@url : String, @size : Vec2? = nil, @fit : Bool = true)
    end

    def inspector_label : String?
      "remote image #{@url}"
    end

    def ui(ui : Ui) : Response
      ctx = ui.ctx
      texture = ctx.load_image_url(@url)
      decoded = ctx.url_image_size(@url)
      size = @size || decoded || PLACEHOLDER
      rect = ui.allocate_at_least(size)
      id = ui.next_widget_id

      if texture > 0
        draw = @fit && decoded && !decoded.x.zero? && !decoded.y.zero? ?
          fitted_rect(rect, decoded) : rect
        ui.painter.image(draw, texture)
      else
        visuals = ui.style.visuals
        ui.painter.rect(rect, 3.0, visuals.button_weak)
        if loading?(ctx)
          spinner_size = {size.x, size.y}.min * 0.4
          cell = ui.child_ui(Rect.from_min_size(
            Pos2.new(rect.center.x - spinner_size / 2.0,
                     rect.center.y - spinner_size / 2.0),
            Vec2.new(spinner_size, spinner_size)))
          cell.add(Spinner.new)
          # Keep frames coming while the fetch is in flight (the
          # spinner animates; the delivered bytes repaint once).
          ctx.request_repaint
        end
      end

      ui.interact(rect, id, Sense.none)
    end

    # Contain-fit: the largest `decoded`-shaped rect inside `box`,
    # centered (letterboxed).
    private def fitted_rect(box : Rect, decoded : Vec2) : Rect
      scale = {box.width / decoded.x, box.height / decoded.y}.min
      draw = Vec2.new(decoded.x * scale, decoded.y * scale)
      Rect.from_min_size(
        Pos2.new(box.center.x - draw.x / 2.0,
                 box.center.y - draw.y / 2.0), draw)
    end

    private def loading?(ctx : Context) : Bool
      ctx.url_images[@url]?.try(&.loading?) || false
    end
  end
end
