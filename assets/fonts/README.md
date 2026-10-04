# Demo fonts (markdown example)

| File | Source | License |
| --- | --- | --- |
| `NotoSans-Regular.ttf` | [noto-fonts](https://github.com/googlefonts/noto-fonts) (hinted) | SIL OFL 1.1 |
| `NotoSans-SemiBold.ttf` | [noto-fonts](https://github.com/googlefonts/noto-fonts) (hinted) | SIL OFL 1.1 |
| `NotoSans-Italic.ttf` | [noto-fonts](https://github.com/googlefonts/noto-fonts) (hinted) | SIL OFL 1.1 |
| `NotoSans-SemiBoldItalic.ttf` | [noto-fonts](https://github.com/googlefonts/noto-fonts) (hinted) | SIL OFL 1.1 |
| `LiberationMono-Regular.ttf` | [liberation-fonts 2.1.5](https://github.com/liberationfonts/liberation-fonts) | SIL OFL 1.1 |

Both loaded by `examples/markdown.cr` at startup; the example falls
back to system faces when the files are removed.

# MathJax TeX fonts (formulas example)

| File | Source | License |
| --- | --- | --- |
| `MathJax_Main-Regular.ttf` | [MathJax](https://github.com/mathjax/MathJax) v2 (`legacy-v2` branch, `fonts/HTML-CSS/TeX`), converted CFF→TrueType | Apache-2.0 |
| `MathJax_Main-Bold.ttf` | same | Apache-2.0 |
| `MathJax_Math-Italic.ttf` | same | Apache-2.0 |
| `MathJax_Size1-Regular.ttf` | same | Apache-2.0 |

The original WOFF files are CFF-flavoured (Type2 charstrings); the
egui-cr font backend (freetype-cr) reads TrueType outlines only, so
the cubic outlines were converted to quadratic `glyf` with
fonttools/cu2qu (max error 1/1000 em):

```sh
pip install fonttools
python - <<'PY'
from fontTools.ttLib import TTFont, newTable
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
src, dst = "MathJax_Main-Regular.woff", "MathJax_Main-Regular.ttf"
font = TTFont(src)
gs, glyphs = font.getGlyphSet(), {}
for name in font.getGlyphOrder():
    pen = TTGlyphPen(gs)
    gs[name].draw(Cu2QuPen(pen, 1.0, reverse_direction=True))
    glyphs[name] = pen.glyph()
glyf = newTable("glyf"); glyf.glyphOrder = font.getGlyphOrder(); glyf.glyphs = glyphs
glyf.compile(font)
loca = newTable("loca"); loca.table = glyf
font["loca"], font["glyf"] = loca, glyf
del font["CFF "]
font.sfntVersion = "\x00\x01\x00\x00"
font.flavor = None  # unwrap woff
font.save(dst)
PY
```

Loaded by `examples/formulas.cr`; the demo falls back to system faces
when the files are removed.
