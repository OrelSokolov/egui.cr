require "../../src/egui"

# OvalProgress — the pill progress bar rendered as TWO nested strips
# (see assets/components/oval_progress.exml): a full-width, fully
# rounded track, and a gradient fill of the same shape inside it.
# Both radii follow ONE rule: radius = strip height / 2 — the caps are
# perfect half-circles at any height, so the bar looks like two
# rounded strips no matter how thick.

# "#rgb", "#rrggbb" or "#rrggbbaa" → Color32 (nil = unparseable).
private def oval_color(s : String) : Egui::Color32?
  return nil unless s.starts_with?('#')
  hex = s[1..]
  hex = hex.chars.map { |c| "#{c}#{c}" }.join if hex.size == 3
  return nil unless hex.size == 6 || hex.size == 8
  r = hex[0, 2].to_u8?(16)
  g = hex[2, 2].to_u8?(16)
  b = hex[4, 2].to_u8?(16)
  a = hex.size == 8 ? hex[6, 2].to_u8?(16) : 255_u8
  Egui::Color32.new(r, g, b, a) if r && g && b && a
end

# A width attribute against `base` (the enclosing strip's width, or
# the available layout width): "62.5%" scales the base, a bare number
# is pixels, anything else falls back to the full base.
private def oval_width(spec : String, base : Float64) : Float64
  if spec.ends_with?('%') && (pct = spec.rchop('%').to_f?)
    pct / 100.0 * base
  elsif px = spec.to_f?
    px
  else
    base
  end
end

# <oval_strip> — one pill strip. Attributes (values interpolate from
# the store): width ("100%" | px), height (px), color ("#hex" solid
# fill) or from/to ("#hex" vertical gradient, top → bottom). A nested
# strip paints INTO its parent strip's rect (no layout space of its
# own), vertically centered — that is how the progress fill sits
# inside the track. The rect is handed down through `_strip_*` store
# slots, so nesting works to any depth and several <oval_strip> trees
# never see each other's state (set → children → cleared, all within
# one synchronous walk).
widget :oval_strip do |node, ui, ctx, rt, renderer|
  height = rt.interpolate(node.attrs["height"]? || "8.0").to_f? || 8.0
  width_spec = rt.interpolate(node.attrs["width"]? || "100%")

  rect =
    if base = rt.floats["_strip_w"]? # nested: inside the parent strip
      # `pad` insets the strip from the parent on every side — the
      # same value top/bottom (via the smaller height + centering)
      # and left/right (offset here + a narrower width base)
      pad = rt.interpolate(node.attrs["pad"]? || "0.0").to_f? || 0.0
      w = oval_width(width_spec, {base - 2.0 * pad, 0.0}.max)
      # a sliver of progress still shows both caps: clamp to a circle
      w = {w, height}.max if w > 0.0
      y = rt.floats["_strip_y"] +
          (rt.floats["_strip_h"] - height) / 2.0
      Egui::Rect.from_min_size(
        Egui::Pos2.new(rt.floats["_strip_x"] + pad, y),
        Egui::Vec2.new(w, height))
    else # top level: takes layout space, full width by default
      ui.allocate_space(
        Egui::Vec2.new(oval_width(width_spec, ui.available_width),
          height))
    end

  radius = height / 2.0 # the one rule: a full pill, whatever the height
  if rect.width > 0.5
    top = node.attrs["from"]?.try { |s| oval_color(rt.interpolate(s)) }
    bottom = node.attrs["to"]?.try { |s| oval_color(rt.interpolate(s)) }
    if top && bottom
      ui.painter.rect_gradient(rect, radius, top, bottom)
    else
      color = node.attrs["color"]?.try { |s| oval_color(rt.interpolate(s)) }
      ui.painter.rect(rect, radius, fill: color) if color
    end
  end

  rt.floats["_strip_x"] = rect.min.x
  rt.floats["_strip_y"] = rect.min.y
  rt.floats["_strip_w"] = rect.width
  rt.floats["_strip_h"] = rect.height
  renderer.render_each(node, ui, ctx, rt)
  {"_strip_x", "_strip_y", "_strip_w", "_strip_h"}.each do |k|
    rt.floats.delete(k)
  end
end

# The component: publishes the template's slots from the use-site
# props every frame. Rendered as <oval_progress frac="…" …/> through
# `renderer.component(OvalProgress.new)` — or any renderer, once this
# file is required and the app registers the component.
#
# The THREE colors are component parameters (set them at the
# construction site: comp = OvalProgress.new; comp.fill_from = …);
# a use-site attr of the same name (track/from/to) still wins over
# the component-level value.
class OvalProgress < Egui::Exml::Component
  exml "assets/components/oval_progress.exml"

  # Track color: nil (the default) = a neutral gray picked to match
  # the theme (dark → #43454c, light → #d0d0d0) — set a "#hex" to pin.
  property track_color : String? = nil
  property fill_from : String = "#7fd0f9"   # голубой (gradient top)
  property fill_to : String = "#1667d9"     # синий (gradient bottom)

  def setup(rt : Egui::Exml::Runtime) : Nil
    rt.strings["from"] ||= @fill_from
    rt.strings["to"] ||= @fill_to
  end

  # frac → the fill's width percent; height/pad → the two strips'
  # heights (the radius follows from them in the handler). The track
  # color resolves here — a use-site attr wins (it re-seeds every
  # frame before update), then the component parameter, then the
  # theme gray.
  def update(ctx : Egui::Context, rt : Egui::Exml::Runtime) : Nil
    rt.strings["track"] ||= @track_color ||
      (ctx.style.visuals.dark ? "#43454c" : "#d0d0d0")
    frac = (rt.string("frac").to_f? || 0.0).clamp(0.0, 1.0)
    height = rt.string("height").to_f? || 12.0
    pad = rt.string("pad").to_f? || 2.0
    rt.floats["height"] = height
    rt.floats["pad"] = pad
    rt.floats["fill"] = {height - 2.0 * pad, 2.0}.max
    rt.floats["pct"] = frac * 100.0
  end
end
