# logo.svg variants for the Egui::Svg widget demos (examples/logos.cr
# and the gallery's Widgets → Logos tab). Every variant carries the
# letter E; LOGO_ICON mirrors assets/icon.svg 1:1.

LOGO_ICON = <<-SVG
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#4FA8E8"/>
      <stop offset="1" stop-color="#1668C4"/>
    </linearGradient>
  </defs>
  <rect x="16" y="16" width="480" height="480" rx="96" fill="url(#bg)"/>
  <text x="256" y="256" text-anchor="middle" dominant-baseline="central"
        font-family="Segoe UI, Arial, sans-serif" font-weight="700"
        font-size="330" fill="#FFFFFF">E</text>
</svg>
SVG

LOGO_OUTLINE = <<-SVG
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <rect x="28" y="28" width="456" height="456" rx="96"
        fill="none" stroke="#1668C4" stroke-width="24"/>
  <text x="256" y="256" text-anchor="middle" dominant-baseline="central"
        font-family="Segoe UI, Arial, sans-serif" font-weight="700"
        font-size="300" fill="#1668C4">E</text>
</svg>
SVG

LOGO_CIRCLE = <<-SVG
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#6BC46B"/>
      <stop offset="1" stop-color="#1E7A1E"/>
    </linearGradient>
  </defs>
  <circle cx="256" cy="256" r="240" fill="url(#g)"/>
  <text x="256" y="256" text-anchor="middle" dominant-baseline="central"
        font-family="Segoe UI, Arial, sans-serif" font-weight="700"
        font-size="300" fill="#FFFFFF">E</text>
</svg>
SVG

LOGO_MONO_DARK = <<-SVG
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <rect x="16" y="16" width="480" height="480" rx="96" fill="#2B2D31"/>
  <text x="256" y="256" text-anchor="middle" dominant-baseline="central"
        font-family="Segoe UI, Arial, sans-serif" font-weight="700"
        font-size="330" fill="#E8EAED">E</text>
</svg>
SVG

LOGO_PILL = <<-SVG
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <defs>
    <linearGradient id="o" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#F0A030"/>
      <stop offset="1" stop-color="#C05E10"/>
    </linearGradient>
  </defs>
  <rect x="16" y="96" width="480" height="320" rx="160" fill="url(#o)"/>
  <text x="256" y="256" text-anchor="middle" dominant-baseline="central"
        font-family="Segoe UI, Arial, sans-serif" font-weight="700"
        font-size="230" fill="#FFFFFF">E</text>
</svg>
SVG

LOGO_FLAT_ACCENT = <<-SVG
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <rect x="32" y="32" width="448" height="448" rx="64" fill="#4FA8E8"/>
  <text x="256" y="256" text-anchor="middle" dominant-baseline="central"
        font-family="Segoe UI, Arial, sans-serif" font-weight="700"
        font-size="300" fill="#0B3D6B">E</text>
</svg>
SVG

LOGO_SKETCH = <<-SVG
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <rect x="28" y="28" width="456" height="456" rx="48"
        fill="none" stroke="#9AA0A6" stroke-width="10"/>
  <text x="256" y="236" text-anchor="middle" dominant-baseline="central"
        font-family="Segoe UI, Arial, sans-serif" font-weight="700"
        font-size="280" fill="#1E7A1E">E</text>
  <line x1="120" y1="400" x2="392" y2="400" stroke="#F0A030" stroke-width="18"/>
</svg>
SVG

# Ordered (name, svg source) pairs.
LOGO_VARIANTS = {
  "icon"         => LOGO_ICON,
  "outline"      => LOGO_OUTLINE,
  "circle"       => LOGO_CIRCLE,
  "mono dark"    => LOGO_MONO_DARK,
  "pill"         => LOGO_PILL,
  "flat accent"  => LOGO_FLAT_ACCENT,
  "sketch"       => LOGO_SKETCH,
}
