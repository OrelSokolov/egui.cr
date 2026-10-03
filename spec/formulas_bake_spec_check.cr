# Headless check of the demo pipeline: the exact bake the Svg widget
# performs (NanoSvgCr.rasterize) on MathJax.to_svg(paths: true) output.
# Prints shape counts and ink coverage for every demo formula.
require "mathjax"
require "../src/egui"
require "../src/egui/nanosvg_cr"

FORMULAS = [
  {"Quadratic formula", %q(x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a})},
  {"Euler's identity", %q(e^{i\pi} + 1 = 0)},
  {"Gauss's summation", %q(\sum_{i=1}^{n} i = \frac{n(n+1)}{2})},
  {"Fundamental theorem of calculus", %q(\int_{a}^{b} f'(x)\,dx = f(b) - f(a))},
  {"Rotation matrix", %q(\begin{pmatrix} \cos\theta & -\sin\theta \\ \sin\theta & \cos\theta \end{pmatrix})},
  {"Cauchy–Schwarz", %q(\left( \sum_{k=1}^{n} a_k b_k \right)^2 \le \left( \sum_{k=1}^{n} a_k^2 \right) \left( \sum_{k=1}^{n} b_k^2 \right))},
]

INK = Egui::Color32.rgb(0x1a, 0x1a, 0x2e)

ok = 0
FORMULAS.each do |name, tex|
  svg = MathJax.to_svg(tex, display: true, paths: true)
  img = Egui::NanoSvgCr.image(svg, INK)
  if img.nil?
    puts "FAIL #{name}: no shapes"
    next
  end
  scale = 480.0f32 / img.width
  w = 480
  h = (img.height * scale).round.to_i32.clamp(1..)
  pixels = Egui::NanoSvgCr.rasterize(svg, INK, w, h)
  if pixels.nil?
    puts "FAIL #{name}: bake returned nil"
    next
  end
  ink = pixels.each_slice(4).count { |q| q[3] > 16 }
  puts "#{name}: #{img.shapes.size} shapes, bake #{w}x#{h}, ink #{ink}"
  ok += 1
end
puts "#{ok}/#{FORMULAS.size} formulas bake cleanly"
exit(ok == FORMULAS.size ? 0 : 1)
