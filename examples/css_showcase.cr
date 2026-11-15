# css_showcase — the single-feature CSS demos in one window (the merge
# of the former border_radius / clipping / clip_child_demo /
# composited_scroll / card_flip / spring / appear / oval_progress
# examples). A sidebar picks the section; each section keeps its own
# state and its own theme (light paper for the border probes, dark for
# the animation ones), applied on section switch:
#
#   crystal run examples/css_showcase.cr
#   rake build:dev[css_showcase] && bin/html/css_showcase
#
# Section-specific env knobs survive the merge:
#   EGUI_COMPOSITED_SCROLL=0|1  classic vs composited scroll replay
#   SCROLL_TO=N                 pre-set the composited scroll offset
#
# The browser-oracle twins (box_shadow, partial_border,
# transform_showcase, …) stay standalone examples — they are verified
# pixel-by-pixel against their .html references and must keep their
# own windows.

require "../src/egui/driver_selector"
require "./oval_progress_components/oval_progress"

# One showcase section. #enter runs on every activation (theme swap);
# #render runs every frame and opens its own panels (central panel
# next to the showcase sidebar, or a floating window).
abstract class CssSection
  abstract def label : String

  def enter(ctx : Egui::Context, base : Egui::Theme) : Nil
    ctx.theme = base # sections without a theme of their own
  end

  abstract def render(ctx : Egui::Context) : Nil
end

# ── border-radius ───────────────────────────────────────────────────────
# border-radius через двухконтейнерную модель — буквальный аналог
# вложенных div из CSS:
#
#   .first  { background: darkgray; width: 500px; height: 200px;
#             border-radius: 10px; }                  /* border color */
#   .second { background: gray; width: 490px; height: 190px;
#             position: relative; left: 5px; top: 5px;
#             border-radius: 10px; }                  /* real bg */
#
# Рамка НЕ рисуется штрихом: сначала внешний скруглённый rect цветом
# рамки, поверх — внутренний rect реального фона, смещённый внутрь на
# ширину border (аналог border-width: 5px). Внутренний radius пока не
# уменьшается (как в примере: оба 10px).

module Br
  BG        = Egui::Color32.rgb(0xec, 0xec, 0xec) # body
  DARKGRAY  = Egui::Color32.rgb(0x00, 0x00, 0x00) # .first — border color
  GRAY      = Egui::Color32.rgb(0x80, 0x80, 0x80) # .second
  TEXT      = Egui::Color32.rgb(0x33, 0x33, 0x33)

  # Пересечение двух rect или nil, когда оно пусто (никогда не
  # возвращает инвертированный Rect — нулевой/отрицательный клип это
  # то, из-за чего угловой патч ломался у кромки панели).
  def self.intersect(a : Egui::Rect, b : Egui::Rect) : Egui::Rect?
    x0 = {a.left, b.left}.max
    y0 = {a.top, b.top}.max
    x1 = {a.right, b.right}.min
    y1 = {a.bottom, b.bottom}.min
    Egui::Rect.new(Egui::Pos2.new(x0, y0), Egui::Pos2.new(x1, y1)) if x1 > x0 && y1 > y0
  end

  # Два наложенных rect: .first (цвет рамки) + .second (фон,
  # сдвинутый внутрь на per-side inset — аналог border-width).
  # Внутренний radius по CSS Backgrounds & Borders: радиус угла
  # внутренней кромки = внешний минус ширина границы, в ноль при
  # толстой рамке.
  #
  # Внутренний rect клипится внешней формой: угловой квадратик
  # radius × radius стирается фоном и пересобирается секторами
  # (внешняя дуга + внутренняя со сдвинутым центром). Патч рисуется
  # только в пересечении квадрата с ТЕКУЩИМ клипом художника — угол
  # за кромкой панели (пустое пересечение) просто пропускается,
  # инвертированный клип не возникает.
  def self.nested(ui : Egui::Ui, size : Egui::Vec2,
                  left : Float64, top : Float64,
                  right : Float64, bottom : Float64,
                  radius : Float64, label : String) : Nil
    outer = ui.allocate_at_least(size)
    ui.painter.rect(outer, radius, DARKGRAY)                    # .first
    inner = Egui::Rect.new(
      Egui::Pos2.new(outer.min.x + left, outer.min.y + top),
      Egui::Pos2.new(outer.max.x - right, outer.max.y - bottom))
    w_max = {left, top, right, bottom}.max
    ui.painter.rect(inner, {radius - w_max, 0.0}.max, GRAY)     # .second

    if radius > 0.0
      corners = {
        {Egui::Pos2.new(outer.min.x, outer.min.y), 1, 1, left, top},
        {Egui::Pos2.new(outer.max.x - radius, outer.min.y), -1, 1, right, top},
        {Egui::Pos2.new(outer.max.x - radius, outer.max.y - radius), -1, -1, right, bottom},
        {Egui::Pos2.new(outer.min.x, outer.max.y - radius), 1, -1, left, bottom},
      }
      prev_clip = ui.painter.clip
      corners.each do |sqo, sx, sy, w_h, w_v|
        sq = Egui::Rect.from_min_size(sqo, Egui::Vec2.new(radius, radius))
        # центр внешней дуги: на радиус внутрь от квадратика
        c_out = Egui::Pos2.new(
          sx > 0 ? sqo.x + radius : sqo.x,
          sy > 0 ? sqo.y + radius : sqo.y)
        # внутренний угол и его радиус: r − более сильная из смежных
        # рамок (угол без рамки: r_in = r, диск совпадает с внешним —
        # угол целиком серый; угол с одной стороной — полоса
        # толщины рамки по дуге)
        icx = sx > 0 ? outer.min.x + w_h : outer.max.x - w_h
        icy = sy > 0 ? outer.min.y + w_v : outer.max.y - w_v
        r_in = {radius - {w_h, w_v}.max, 0.0}.max

        eff = intersect(sq, prev_clip)
        # Патчить только ЦЕЛИКОМ видимые углы: частично обрезанный
        # клипом панели патч сам становится артефактом (полудиск).
        # У кромки угол остаётся в простом two-rect виде.
        next unless eff && eff.width >= sq.width && eff.height >= sq.height
        ui.painter.clip = eff
        ui.painter.rect(eff, 0.0, BG)                   # стереть угол
        ui.painter.circle_filled(c_out, radius, DARKGRAY)
        if r_in > 0.0
          c_in = Egui::Pos2.new(
            sx > 0 ? icx + r_in : icx - r_in,
            sy > 0 ? icy + r_in : icy - r_in)
          ui.painter.circle_filled(c_in, r_in, GRAY)
        else
          # толстая рамка: прямой внутренний угол лежит внутри дуги
          if (irect = intersect(inner, eff))
            ui.painter.rect(irect, 0.0, GRAY)
          end
        end
      end
      ui.painter.clip = prev_clip
    end

    font = ui.style.font_size
    tw = ui.ctx.fonts.measure(label, font).x
    ui.painter.text(Egui::Pos2.new(
      inner.min.x + (inner.width - tw) / 2.0, inner.center.y),
      label, font, TEXT)
  end
end

class BorderRadiusSection < CssSection
  def label : String
    "border-radius"
  end

  @theme : Egui::Theme? = nil

  def enter(ctx : Egui::Context, base : Egui::Theme) : Nil
    ctx.theme = (@theme ||= Egui::DefaultTheme.build("border_radius", dark: false) do |v|
      v.window_fill = Br::BG
      v.panel_fill = Br::BG
      v.text_color = Br::TEXT
      v.window_stroke = Br::BG # page has no window chrome
    end)
  end

  def render(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading(".first + .second (border-width: 5px, radius 10)")
      Br.nested(ui, Egui::Vec2.new(500.0, 200.0),
        5.0, 5.0, 5.0, 5.0, 10.0,
        "500×200, inner 490×190 at +5,+5")

      ui.separator
      ui.heading("border-width: 1px")
      Br.nested(ui, Egui::Vec2.new(500.0, 110.0),
        1.0, 1.0, 1.0, 1.0, 10.0, "1px")

      ui.separator
      ui.heading("border-width: 10px")
      Br.nested(ui, Egui::Vec2.new(500.0, 110.0),
        10.0, 10.0, 10.0, 10.0, 10.0, "10px")

      ui.separator
      ui.heading("per-side: left 3px, bottom 6px")
      Br.nested(ui, Egui::Vec2.new(500.0, 110.0),
        3.0, 0.0, 0.0, 6.0, 10.0, "left 3 / bottom 6")
    end
  end
end

# ── clipping ────────────────────────────────────────────────────────────
# Rounded per-side блок (left 3 / bottom 6, radius 10), два способа —
# БЕЗ клипа и БЕЗ маски-кольца, чистое наложение двух rect:
#
#   СЛЕВА — инвариант inner + borders = outer по каждой оси +
#     per-corner радиусы внутреннего: радиус угла = внешний радиус
#     минус смежная граница (сверху рамки нет → 10 и 10−3=7 сверху,
#     10−6=4 снизу). Внутренняя кривая целиком внутри внешней дуги.
#   СПРАВА — путь движка (RectCmd#stroke_sides). С переходом на
#     стандартный алгоритм рамок (Egui.border_overlay_layers) обе
#     стороны пиксельно совпадают — демка стала самопроверкой.

module Cl
  BLACK = Egui::Color32.rgb(0, 0, 0)
  GRAY  = Egui::Color32.rgb(0x80, 0x80, 0x80)
  BG    = Egui::Color32.rgb(0xec, 0xec, 0xec)
  TEXT  = Egui::Color32.rgb(0x33, 0x33, 0x33)

  # Rounded-блок с per-side рамкой — рамка маской-кольцом движка.
  def self.block(painter : Egui::Painter, outer : Egui::Rect) : Nil
    sides = Egui::StrokeSides.new(
      top: Egui::SideStroke.new(0.0, BLACK),
      right: Egui::SideStroke.new(0.0, BLACK),
      bottom: Egui::SideStroke.new(6.0, BLACK),
      left: Egui::SideStroke.new(3.0, BLACK))
    painter.rect(outer, 10.0, GRAY, BLACK, 1.0, stroke_sides: sides)
  end
end

class ClippingSection < CssSection
  def label : String
    "clipping"
  end

  @theme : Egui::Theme? = nil

  def enter(ctx : Egui::Context, base : Egui::Theme) : Nil
    ctx.theme = (@theme ||= Egui::DefaultTheme.build("clipping", dark: false) do |v|
      v.window_fill = Cl::BG
      v.panel_fill = Cl::BG
      v.text_color = Cl::TEXT
      v.window_stroke = Cl::BG
    end)
  end

  def render(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("rounded l3/b6: слева наложение с per-corner радиусами — справа маска-кольцо")
      ui.horizontal do |row|
        # ЛЕВЫЙ — простое наложение двух rect, без клипа: внутренний
        # по размеру = внешний минус границы (3 слева, 6 снизу), а его
        # угловые радиусы = внешний минус смежная граница:
        # TL 10−3=7, TR 10−0=10, BR/BL 10−6=4.
        left = row.allocate_at_least(Egui::Vec2.new(340.0, 90.0))
        row.painter.rect(left, 10.0, Cl::BLACK)
        inner = Egui::Rect.new(
          Egui::Pos2.new(left.min.x + 3.0, left.min.y),
          Egui::Pos2.new(left.max.x, left.max.y - 6.0))
        row.painter.rect(inner, 0.0, Cl::GRAY, corners: Egui::CornerRadii.new(
          top_left: 7.0, top_right: 10.0,
          bottom_right: 4.0, bottom_left: 4.0))

        row.label(" ")

        # ПРАВЫЙ — путь движка: тот же блок через RectCmd#stroke_sides —
        # теперь это тот же алгоритм наложения, совпадает со СЛЕВА.
        right = row.allocate_at_least(Egui::Vec2.new(340.0, 90.0))
        Cl.block(row.painter, right)
      end
    end
  end
end

# ── clip-child ──────────────────────────────────────────────────────────
# Engine-level rounded content clipping (border-radius +
# overflow:hidden semantics).
#
# A container with a non-zero border radius clips everything its
# subtree paints to the ROUNDED shape — not just the rect bounds.
# Scrolled/nested content no longer bleeds past the curved corners:
#
#   .card {
#     border-radius: 24px;   /* != 0 → the subtree is clip-bracketed */
#     overflow: hidden;      /* implied by the engine, not opt-in */
#   }
#
# The clip is recursive by construction: an inner box's commands are
# re-clipped by its own bracket first, then the outer bracket
# intersects again (per-corner radii merge). Popups riding the
# Foreground layer deliberately ESCAPE the bracket — a menu opened
# inside a rounded card must not be cut by the card.
#
# Scenes (drag the radius slider while they run): square plate,
# scroll under the curve, nested boxes, per-corner, popup escape.

module ClipChild
  BACKDROP = Egui::Color32.rgb(0x1b, 0x1b, 0x1e)
  CARD     = Egui::Color32.rgb(0x3f, 0x6b, 0x52) # sage green card
  PLATE    = Egui::Color32.rgb(0xb0, 0x5c, 0x4a) # terracotta square plate
  NESTED   = Egui::Color32.rgb(0x4a, 0x5f, 0x8a) # slate-blue inner box
  SCROLLBG = Egui::Color32.rgb(0x2b, 0x2b, 0x31)

  ZERO = Egui::Vec2.new(0.0, 0.0)
end

class ClipChildSection < CssSection
  def label : String
    "clip-child"
  end

  property radius = 24.0
  property picked = "option A"

  def render(ctx : Egui::Context) : Nil
    ctx.window("clip_child", Egui::Pos2.new(24.0, 24.0), width: 560.0) do |ui|
      ui.heading("rounded clip — border-radius ≠ 0 clips the subtree")
      ui.label("box(rounding: r) clips everything inside to the rounded " \
               "shape; nested elements recursively. Drag the slider:")
      ui.slider(@radius, 0.0..48.0, "radius") { |v| @radius = v }
      r = @radius
      ui.separator

      # 1. Square full-bleed plate: without the clip the red would
      # flood the corners the card curves away from.
      ui.heading("1. square child, rounded parent")
      ui.box(rounding: r, fill: ClipChild::CARD, margin: ClipChild::ZERO) do |b|
        rect = b.allocate_space(Egui::Vec2.new(b.available_width, 120.0))
        b.painter.rect(rect, 0.0, ClipChild::PLATE)
      end

      ui.separator
      # 2. A scroll whose rows run under the curve — the classic bug
      # scene (content escaping the rounded viewport while scrolling).
      ui.heading("2. scroll under the curve")
      ui.box(rounding: r, fill: ClipChild::SCROLLBG,
          margin: ClipChild::ZERO) do |b|
        Egui::ScrollArea.new(max_height: 120.0).show(b) do |scroll|
          60.times { |i| scroll.label("row #{i} — scrolls INSIDE the curve") }
        end
      end

      ui.separator
      # 3. Nested: the inner box is square (rounding 0), yet its blue
      # plate is cut by the OUTER curve — radii merge per corner.
      ui.heading("3. nested square box")
      ui.box(rounding: r, fill: ClipChild::CARD, margin: ClipChild::ZERO) do |b|
        b.box(rounding: 0.0, fill: ClipChild::NESTED,
            margin: ClipChild::ZERO) do |c|
          c.allocate_space(Egui::Vec2.new(c.available_width, 90.0))
        end
      end

      ui.separator
      # 4. Per-corner CSS shorthand: the clip follows the same shape
      # as the painted background (0 24 0 24 — two square corners).
      ui.heading("4. per-corner: 0 #{r.to_i} 0 #{r.to_i}")
      ui.box(rounding: 0.0, fill: ClipChild::CARD, margin: ClipChild::ZERO,
          corners: Egui::CornerRadii.new(0.0, r, 0.0, r)) do |b|
        rect = b.allocate_space(Egui::Vec2.new(b.available_width, 90.0))
        b.painter.rect(rect, 0.0, ClipChild::PLATE)
      end

      ui.separator
      # 5. Popups escape the bracket: the dropdown is Foreground-layer
      # content and must NOT be clipped by the card — open it and
      # watch it cover the rounded corner below.
      ui.heading("5. popup escapes the clip")
      ui.box(rounding: r, fill: ClipChild::SCROLLBG,
          margin: Egui::Vec2.new(12.0, 8.0)) do |b|
        b.label("the combo opens over the card, uncut:")
        b.combo_box("clip_demo_combo", @picked,
          (1..6).map { |i| "option #{'A' + i - 1}" }) { |opt| @picked = opt }
      end
    end
  end
end

# ── composited scroll ───────────────────────────────────────────────────
# Composited scroll A/B probe (plans/COMPOSITED_SCROLL.md): a long
# ScrollArea with `composited: true` — the content (text rows, rounded
# cards, buttons) renders into the overscan band and the render thread
# owns the scroll offset at replay time.
#
# Run the section twice for the pixel-identity invariant:
#
#   EGUI_COMPOSITED_SCROLL=0 css_showcase  # classic
#   EGUI_COMPOSITED_SCROLL=1 css_showcase  # composited
#
# With no wheel input the replay delta is 0 and both must be
# pixel-identical (twinshot-verifiable). SCROLL_TO=N pre-sets the
# offset so a scrolled state can be compared too.

class CompositedScrollSection < CssSection
  def label : String
    "composited scroll"
  end

  @scroll_to : Float64? = ENV["SCROLL_TO"]?.try(&.to_f)

  def render(ctx : Egui::Context) : Nil
    # SCROLL_TO: pin the offset cell every frame (the stable `id:`
    # pins it) — a continuous write keeps the probe deterministic for
    # the A/B screenshot (no kinetic settle races).
    if (to = @scroll_to)
      ctx.memory.data.set_vec2(Egui::Id.from("probe"), Egui::Vec2.new(0.0, to))
    end
    ctx.central_panel do |ui|
      Egui::ScrollArea.new(composited: true, id: Egui::Id.from("probe"))
        .content { |inner| build_rows(inner) }.ui(ui)
    end
  end

  def build_rows(ui : Egui::Ui) : Nil
    200.times do |i|
      ui.horizontal do |row|
        row.label("row %03d" % i)
        row.button("action #{i}") if i % 7 == 3
      end
      if i % 15 == 0
        # A rounded block: exercises the stencil clip path inside the
        # bracket (its rect must translate with the composited scroll).
        ui.scope do |card|
          x = card.cursor.x
          y = card.cursor.y
          card.painter.rect(Egui::Rect.from_min_size(
            Egui::Pos2.new(x - 4.0, y - 4.0),
            Egui::Vec2.new(card.available_width + 8.0, 34.0)),
            10.0, Egui::Color32.rgba(40, 44, 52, 255))
          card.label("card block #{i} — rounded clip inside the band")
        end
      end
    end
  end
end

# ── card flip ───────────────────────────────────────────────────────────
# Порт демо "3D card flip animation" (You-Dont-Need-JavaScript) на
# нативный движок.
#
# Оригинал крутит карту через CSS `perspective` + `rotateY(180deg)` +
# `backface-visibility: hidden` на checkbox-hack'е. Здесь то же самое
# на полном `transform` движка:
#
#   * флип  — scaleX 1 → 0 → 1 (горизонтальное сжатие, классический
#     "fake 3D" флип) + смена стороны на середине пролёта; слегка
#     scaleY для псевдо-наклона;
#   * стороны — div-структура: Джокер из кругов/капсул/букв (спереди),
#     рубашка с орнаментом + аватар (сзади);
#   * кнопка-«checkbox» — Crystal-стейт вместо :checked-hack'а.
#
# Всё через ui.box(transform:) — paint-only, layout на месте.

class CardFlipSection < CssSection
  BG      = Egui::Color32.rgb(0x24, 0x24, 0x24)
  GHOST   = Egui::Color32.rgb(0xf8, 0xf8, 0xff) # ghostwhite
  OLDLACE = Egui::Color32.rgb(0xfd, 0xf5, 0xe6)
  RED     = Egui::Color32.rgb(0xdc, 0x26, 0x26)
  BLACK   = Egui::Color32.rgb(0x0a, 0x0a, 0x0a)
  GREY    = Egui::Color32.rgb(0x9c, 0x9c, 0x9c)
  BURLY   = Egui::Color32.rgb(0xde, 0xb8, 0x87)
  TEXT    = Egui::Color32.rgb(0xe8, 0xe8, 0xe8)
  MUTED   = Egui::Color32.rgb(0x9a, 0x9a, 0xa2)

  CARD_W = 250.0
  CARD_H = 350.0

  def label : String
    "card flip"
  end

  @theme : Egui::Theme? = nil
  @flipped = false
  # Прогресс флипа 0..1 (1 = полностью перевёрнута). Двигается к цели
  # каждый кадр — ease-in-out по синусу половинки.
  @flip = 0.0
  @last_t : Float64? = nil

  def enter(ctx : Egui::Context, base : Egui::Theme) : Nil
    ctx.theme = (@theme ||= Egui::DefaultTheme.build("card-flip", dark: true) do |v|
      v.window_fill = BG
      v.panel_fill = BG
      v.text_color = TEXT
      v.window_stroke = BG
    end)
  end

  def render(ctx : Egui::Context) : Nil
    now = ctx.input.time
    # Анимация: шаг к цели со скоростью ~2.2 сек^-1 (независимо от FPS
    # грубо; для демо достаточно — request_repaint держит кадры живыми).
    target = @flipped ? 1.0 : 0.0
    if @flip != target
      dir = target > @flip ? 1.0 : -1.0
      step = (now - (@last_t ||= now)) * 2.2
      @flip = (@flip + dir * step).clamp(target < @flip ? target : 0.0,
        target > @flip ? target : 1.0)
      ctx.request_repaint
    end
    @last_t = now

    ctx.central_panel do |ui|
      ui.box(:column, fill: BG, margin: Egui::Vec2.new(16.0, 16.0),
        rounding: 0.0, stroke: nil) do |col|
        col.rich(Egui::RichText.new("3D card flip — transform demo")
          .size(20.0).color(TEXT))
        col.rich(Egui::RichText
          .new("scaleX 1 → 0 → 1 + face swap at the midpoint (fake perspective)")
          .size(11.0).color(MUTED))
        col.box(:row, margin: Egui::Vec2.new(0.0, 8.0)) { }

        col.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 0.0)) do |stage|
          the_card(stage)
        end

        # Кнопка-переключатель (бывший label checkbox-hack'а).
        col.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 24.0)) do |bar|
          label = @flipped ? "Front Side" : "Back Side"
          if bar.button(label, id: "flip").clicked?
            @flipped = !@flipped
          end
          bar.rich(Egui::RichText.new("  flip: #{@flip.round(2)}")
            .size(11.0).color(MUTED))
        end
      end
    end
  end

  # --- the card ----------------------------------------------------------

  private def the_card(stage : Egui::Ui) : Nil
    # Половина флипа: 0 → 1 → 0; лицо видно на первой половине.
    half = 1.0 - (@flip * 2.0 - 1.0).abs
    show_front = @flip < 0.5
    sx = 1.0 - 0.94 * half
    sy = 1.0 - 0.10 * half
    # Небольшой наклон вокруг середины пролёта для живости.
    rot = (@flip - 0.5) * 2.0
    tilt = -6.0 * (show_front ? half : -half)
    xf = "rotate(#{tilt.round(2)}deg) scale(#{sx.round(4)}, #{sy.round(4)})"

    stage.box(:column, transform: xf, transform_origin: "center",
      margin: Egui::Vec2.new(0.0, 0.0)) do |card|
      if show_front
        card_front(card)
      else
        card_back(card)
      end
    end
  end

  # Лицевая сторона: упрощённый Джокер из оригинала — буквы, «шляпа»
  # из кругов и капсул, «улыбка». cb-top/cb-bottom зеркальны.
  private def card_front(card : Egui::Ui) : Nil
    card.box(:column, fill: GHOST, rounding: 16.0, stroke: GREY,
      margin: Egui::Vec2.new(0.0, 0.0), width: CARD_W, height: CARD_H) do |face|
      face.box(:column, fill: nil, stroke: nil, rounding: 0.0,
        margin: Egui::Vec2.new(12.0, 12.0)) do |inner|
        joker_half(inner, RED)
        inner.box(:row, margin: Egui::Vec2.new(0.0, 8.0)) { }
        # Нижняя половина — как верхняя, но чёрная (в оригинале это
        # разворот на 180°; здесь просто вторая половина).
        joker_half(inner, BLACK)
      end
    end
  end

  private def joker_half(ui : Egui::Ui, color : Egui::Color32) : Nil
    # J-O-K-E-R вертикально
    ui.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 4.0)) do |row|
      "JOKER".each_char do |ch|
        row.rich(Egui::RichText.new(ch.to_s).size(19.0).color(color))
      end
    end
    # «Голова»: капсула-колпак + круг-лицо + глаз
    ui.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 4.0)) do |row|
      row.box(:column, fill: color, rounding: 3.0,
        margin: Egui::Vec2.new(14.0, 10.0)) do |hat|
        hat.box(:row, margin: Egui::Vec2.new(4.0, 8.0)) { }
      end
    end
    ui.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 2.0)) do |row|
      row.box(:column, fill: GHOST, stroke: color, rounding: 11.0,
        margin: Egui::Vec2.new(10.0, 10.0)) do |face|
        face.box(:row, margin: Egui::Vec2.new(2.0, 2.0)) do |eye|
          eye.box(:column, fill: color, rounding: 1.5,
            margin: Egui::Vec2.new(3.0, 3.0)) { }
        end
      end
    end
    # «Улыбка»: три капсулы
    ui.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 3.0)) do |row|
      row.box(:column, fill: color, rounding: 5.0,
        margin: Egui::Vec2.new(4.0, 7.0)) { }
      row.box(:column, fill: color, rounding: 5.0,
        margin: Egui::Vec2.new(4.0, 5.0)) { }
      row.box(:column, fill: color, rounding: 5.0,
        margin: Egui::Vec2.new(4.0, 7.0)) { }
    end
  end

  # Рубашка: oldlace-фон, орнамент из полос и точек, «аватар»-круг и
  # подпись (в оригинале — remote-аватар GitHub; здесь локальный круг).
  private def card_back(card : Egui::Ui) : Nil
    card.box(:column, fill: OLDLACE, rounding: 16.0, stroke: GREY,
      margin: Egui::Vec2.new(0.0, 0.0), width: CARD_W, height: CARD_H) do |face|
      # Орнамент: столбики-«точки» по верхней кромке
      face.box(:row, wrap: false, margin: Egui::Vec2.new(12.0, 12.0)) do |strip|
        16.times do
          strip.box(:column, fill: BURLY, rounding: 1.0,
            margin: Egui::Vec2.new(2.0, 6.0)) { }
        end
      end
      # Круг-«аватар»
      face.box(:row, wrap: false, margin: Egui::Vec2.new(12.0, 12.0)) do |circ|
        circ.box(:column, fill: RED, rounding: 38.0,
          margin: Egui::Vec2.new(38.0, 38.0)) do |c|
          c.rich(Egui::RichText.new("e").size(40.0).color(OLDLACE))
        end
      end
      face.box(:column, margin: Egui::Vec2.new(20.0, 8.0)) do |note|
        note.rich(Egui::RichText.new("egui.cr").size(24.0).color(BLACK))
        note.rich(Egui::RichText
          .new("If you have any suggestions please please let me know")
          .size(11.0).color(GREY))
      end
    end
  end
end

# ── spring ──────────────────────────────────────────────────────────────
# Демо-пруф spring-примитива (инкремент 1 плана
# plans/NATIVE_HTML_DEMO.md §3.2): значение `spring(…)` в `transition`
# вместо duration+easing.
#
# Три ряда чипов на hover:
#   1. фон — spring(bouncy) / spring(smooth);
#   2. фон — обычный ease-out 150ms (тот же контраст цветов);
#   3. ширина — spring(wobbly) против ease-out.
#
# Качайте указатель туда-сюда по ряду: easing-переход при каждом
# входе/выходе перезапускается с нулевой производной (скачок скорости),
# пружина продолжает с текущей скоростью — прерывание без рывка, у
# bouncy ещё и перелетает цель. Это и есть ключевое свойство
# «живости» Raven: непрерывность по скорости при смене цели mid-flight.

# Чип с собственным классом — правила ниже вешают переходы на класс.
class SpringChip < Egui::Button
  def initialize(text : String, @chip_class : String, id : String? = nil)
    super(text, id: id)
  end

  def style_class : String?
    @chip_class
  end
end

class SpringSection < CssSection
  BG   = Egui::Color32.rgb(0x16, 0x17, 0x1a)
  TEXT = Egui::Color32.rgb(0xe8, 0xe8, 0xe8)

  BASE = {
    "background" => Egui::Color32.rgb(0x2d, 0x6c, 0x46),
    "stroke"     => Egui::Color32.rgb(0x43, 0x9c, 0x64),
    "text_color" => TEXT,
    "rounding"   => 10.0,
  }
  HOVER = Egui::Color32.rgb(0x53, 0xb9, 0x77)
  GROW  = {
    "width"      => 120.0,
    "height"     => 36.0,
    "background" => Egui::Color32.rgb(0x39, 0x4b, 0x6d),
    "stroke"     => Egui::Color32.rgb(0x58, 0x74, 0xa4),
    "text_color" => TEXT,
    "rounding"   => 10.0,
  }

  def label : String
    "spring"
  end

  @theme : Egui::Theme? = nil
  @rules = false

  def enter(ctx : Egui::Context, base : Egui::Theme) : Nil
    ctx.theme = (@theme ||= Egui::DefaultTheme.build("spring", dark: true) do |v|
      v.window_fill = BG
      v.panel_fill = BG
      v.text_color = TEXT
      v.window_stroke = BG
    end)
    return if @rules
    @rules = true

    s = ctx.stylesheet

    # Ряд 1: фон на пружинах — bouncy перелетает, smooth приземляется.
    s.rule("chip-bouncy", Egui::StyleVars{
      "background" => BASE["background"].as(Egui::Color32),
      "stroke"     => BASE["stroke"].as(Egui::Color32),
      "text_color" => TEXT,
      "rounding"   => 10.0,
      "transition" => "spring(bouncy)",
    })
    s.rule("chip-bouncy:hover",
      Egui::StyleVars{"background" => HOVER})

    s.rule("chip-smooth", Egui::StyleVars{
      "background" => BASE["background"].as(Egui::Color32),
      "stroke"     => BASE["stroke"].as(Egui::Color32),
      "text_color" => TEXT,
      "rounding"   => 10.0,
      "transition" => "spring(smooth)",
    })
    s.rule("chip-smooth:hover",
      Egui::StyleVars{"background" => HOVER})

    # Ряд 2: тот же контраст, но классический ease-out — при
    # прерывании производная обнуляется, «дёргано» против ряда 1.
    s.rule("chip-ease", Egui::StyleVars{
      "background" => BASE["background"].as(Egui::Color32),
      "stroke"     => BASE["stroke"].as(Egui::Color32),
      "text_color" => TEXT,
      "rounding"   => 10.0,
      "transition" => 150.0,
      "easing"     => "ease-out",
    })
    s.rule("chip-ease:hover",
      Egui::StyleVars{"background" => HOVER})

    # Ряд 3: ширина — spring(wobbly) против ease-out. У spring-версии
    # compound-спеллинг: «width spring(…)» называет ключ.
    s.rule("grow-spring", Egui::StyleVars{
      "width"      => 120.0,
      "height"     => 36.0,
      "background" => GROW["background"].as(Egui::Color32),
      "stroke"     => GROW["stroke"].as(Egui::Color32),
      "text_color" => TEXT,
      "rounding"   => 10.0,
      "transition" => "width spring(wobbly)",
    })
    s.rule("grow-spring:hover", Egui::StyleVars{"width" => 220.0})

    s.rule("grow-ease", Egui::StyleVars{
      "width"           => 120.0,
      "height"          => 36.0,
      "background"      => GROW["background"].as(Egui::Color32),
      "stroke"          => GROW["stroke"].as(Egui::Color32),
      "text_color"      => TEXT,
      "rounding"        => 10.0,
      "transition.width" => 150.0,
      "easing.width"    => "ease-out",
    })
    s.rule("grow-ease:hover", Egui::StyleVars{"width" => 220.0})
  end

  def render(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("spring(…) в transition — прерывание без скачка")
      ui.label("Проведите указателем по ряду туда-сюда: пружина продолжает")
      ui.label("с текущей скоростью, easing перезапускается с нулевой.")
      ui.separator

      ui.heading("Фон: spring(bouncy) · spring(smooth) · ease-out 150ms")
      ui.horizontal do |h|
        h.add(SpringChip.new("bouncy", "chip-bouncy", id: "chip-bouncy"))
        h.add(SpringChip.new("smooth", "chip-smooth", id: "chip-smooth"))
        h.add(SpringChip.new("ease-out", "chip-ease", id: "chip-ease"))
      end
      ui.separator

      ui.heading("Ширина на hover: spring(wobbly) · ease-out 150ms")
      ui.horizontal do |h|
        h.add(SpringChip.new("spring", "grow-spring", id: "grow-spring"))
        h.add(SpringChip.new("ease-out", "grow-ease", id: "grow-ease"))
      end
      ui.separator

      ui.label("Спеллинги: transition: spring(bouncy) · transition: width")
      ui.label("spring(0.3, 0.8) 50ms · transition.width: spring(smooth)")
    end
  end
end

# ── appear ──────────────────────────────────────────────────────────────
# Демо-пруф appear-переходов (инкремент 2 плана
# plans/NATIVE_HTML_DEMO.md §3.2): свойства `appear:`/`appear-delay:`
# поверх painter-transform, порт именованных переходов Raven
# (examples/animations/animations.xml).
#
# Слева — кнопки переходов (как у Raven): нажатие перепроявляет
# центральную карточку выбранным переходом. «Play them all» — все три
# панели разом. Справа — приходящие/уходящие карточки со стэггером
# (appear-delay по индексу).
#
# Перепроявление: карточка скрывается на один кадр — end-frame
# pruning сносит её appear-состояние, и на следующем кадре переход
# играется заново (семантика «первого появления»).

class AppearSection < CssSection
  BG     = Egui::Color32.rgb(0x16, 0x17, 0x1a)
  PANEL  = Egui::Color32.rgb(0x1f, 0x21, 0x26)
  STROKE = Egui::Color32.rgb(0x33, 0x36, 0x3d)
  TEXT   = Egui::Color32.rgb(0xe8, 0xe8, 0xe8)
  ACCENT = Egui::Color32.rgb(0x3b, 0x82, 0xf6)

  TRANSITIONS = {"Fade", "Pop", "Zoom", "FlyUp", "FlyDown", "FlyLeft",
                 "FlyRight", "Drop", "SlideLeft", "SlideRight"}

  def label : String
    "appear"
  end

  @theme : Egui::Theme? = nil
  @current = "Pop"
  @cards = ["one", "two", "three"]
  @next_card = 4
  # Перепроявление: до этого момента карточка сцены не эмитится —
  # состояние сносится, следующий кадр играет переход заново.
  @hide_until = -1.0

  def enter(ctx : Egui::Context, base : Egui::Theme) : Nil
    ctx.theme = (@theme ||= Egui::DefaultTheme.build("appear", dark: true) do |v|
      v.window_fill = BG
      v.panel_fill = BG
      v.text_color = TEXT
      v.window_stroke = BG
    end)
  end

  def render(ctx : Egui::Context) : Nil
    now = ctx.input.time

    ctx.central_panel do |ui|
      # Три колонки (переключатель / сцена / карточки) — ui.columns,
      # чтобы боковые панели не растягивались на всю ширину ряда.
      ui.columns(3) do |cols|
        left, stage, right = cols

        # -- transition picker ----------------------------------------------
        left.box(:column, fill: PANEL, stroke: STROKE, rounding: 14.0,
          margin: Egui::Vec2.new(4.0, 4.0), appear: "fly-right") do |l|
          label(l, "Transitions", 17.0)
          TRANSITIONS.each do |name|
            if l.button(name, id: "btn-#{name}").clicked?
              @current = name
              @hide_until = now + 1.0 / 30.0
            end
          end
          if l.button("Play them all", id: "btn-all").clicked?
            @hide_until = now + 1.0 / 30.0
          end
        end

        # -- the stage --------------------------------------------------------
        stage.box(:column, fill: PANEL, stroke: STROKE, rounding: 14.0,
          margin: Egui::Vec2.new(4.0, 4.0), appear: "drop",
          appear_delay: 0.08) do |st|
          if now < @hide_until
            # один кадр пустоты — карточка ниже не эмитится
            label(st, "…", 22.0)
          else
            st.box(:column, fill: ACCENT, rounding: 22.0,
              margin: Egui::Vec2.new(18.0, 18.0),
              appear: kebab(@current)) do |card|
              card.rich(Egui::RichText.new(@current).size(26.0)
                .color(Egui::Color32.rgb(255, 255, 255)))
              card.rich(Egui::RichText
                .new("Choose a transition on the left")
                .color(Egui::Color32.rgba(255, 255, 255, 200)))
            end
          end
        end

        # -- cards that come and go ------------------------------------------
        right.box(:column, fill: PANEL, stroke: STROKE, rounding: 14.0,
          margin: Egui::Vec2.new(4.0, 4.0), appear: "fly-left",
          appear_delay: 0.16) do |r|
          r.box(:row, wrap: false,
            margin: Egui::Vec2.new(0.0, 0.0)) do |bar|
            bar.rich(Egui::RichText.new("Cards").size(17.0))
            if bar.button("Add", id: "btn-add").clicked?
              @cards << "card #{@next_card}"
              @next_card += 1
            end
            if bar.button("Remove", id: "btn-remove").clicked? &&
               !@cards.empty?
              @cards.pop
            end
          end
          r.box(:column, wrap: false,
            margin: Egui::Vec2.new(0.0, 0.0)) do |list|
            @cards.each_with_index do |name, i|
              # стэггер: каждая следующая карточка стартует позже
              list.box(:row, fill: Egui::Color32.rgb(0x27, 0x2a, 0x31),
                rounding: 10.0, margin: Egui::Vec2.new(4.0, 4.0),
                appear: "pop", appear_delay: i * 0.06) do |row|
                row.rich(Egui::RichText.new(name).size(13.0))
              end
            end
          end
        end
      end
    end
  end

  private def kebab(pascal : String) : String
    pascal.gsub(/([a-z\d])([A-Z])/, "\\1-\\2").downcase
  end

  private def label(ui : Egui::Ui, text : String, size : Float64) : Nil
    ui.rich(Egui::RichText.new(text).size(size))
  end
end

# ── oval progress ───────────────────────────────────────────────────────
# The pill progress bar component (assets/components/oval_progress.exml)
# driven from an exml document: a slider-bound instance, an animated
# one, static variants and a live color inspector (three color_edit32
# pickers driving the component's three color parameters through the
# store).

class OvalProgressSection < CssSection
  DEMO_EXML = <<-EXML
  <exml>
    <page id="root/root" title="OvalProgress">
      <central>
        <heading text="OvalProgress"/>
        <label text="slider-driven: {demo}"/>
        <oval_progress frac="{demo}" height="14"/>
        <separator/>
        <label text="animated wave: {wave}"/>
        <oval_progress frac="{wave}" height="22" pad="3"
                       from="#f9b8a8" to="#d9452b"/>
        <separator/>
        <oval_progress frac="0.25" height="10" pad="1"/>
        <oval_progress frac="0.55" height="18" pad="4"
                       track="#e8ecf2" from="#a2f0c1" to="#0f9d58"/>
        <oval_progress frac="0.8" height="30" pad="5"
                       from="#f7d794" to="#e8a020"/>
        <separator/>
        <label text="colors — live, from the inspector panel below"/>
        <oval_progress frac="0.72" height="20" pad="3"
                       track="{c_track}" from="{c_from}" to="{c_to}"/>
        <separator/>
        <slider bind="demo" min="0" max="1"/>
      </central>
    </page>
  </exml>
  EXML

  def label : String
    "oval progress"
  end

  @renderer = Egui::Exml::Renderer.new
  @rt = Egui::Exml::Runtime.new
  @exml : Egui::Exml::Document
  @t = 0.0

  def initialize
    @exml = Egui::Exml.parse(DEMO_EXML)
    # oval_strip is global (the `widget` registry); oval_progress is a
    # per-renderer component — the linter needs it listed.
    Egui::Exml.validate(@exml, known_custom: %w(oval_progress))
      .each { |issue| STDERR.puts "exml: #{issue}" }
    @renderer.component(OvalProgress.new)
    @rt.floats["demo"] = 0.35
    # the inspector panel's current colors (start at the defaults)
    @rt.strings["c_track"] = "#43454c"
    @rt.strings["c_from"] = "#7fd0f9"
    @rt.strings["c_to"] = "#1667d9"
  end

  def render(ctx : Egui::Context) : Nil
    # the animated wave needs frames even without input
    @t += ctx.input.dt
    @rt.floats["wave"] = (Math.sin(@t * 2.0) + 1.0) / 2.0
    ctx.request_repaint
    @renderer.render_routes(ctx, @exml, @rt)
    color_inspector(ctx)
  end

  # The three color parameters, editable live: pickers write "#hex"
  # slots, the markup interpolates them into the preview bar. The row
  # scrolls horizontally — a color edit is ~250px wide, three don't
  # always fit the window. No max_height: the viewport fills whatever
  # the panel gives it, re-measured every frame (drag the panel edge
  # and the scroll height follows).
  private def color_inspector(ctx : Egui::Context) : Nil
    ctx.bottom_panel("colors") do |ui|
      ui.scroll_area(hbar: :bottom) do |row|
        row.horizontal(wrap: false) do |h|
          {"c_track" => "track", "c_from" => "from",
           "c_to" => "to"}.each do |slot, name|
            h.label(name)
            h.color_edit32(demo_color(@rt.strings[slot]?)) do |c|
              @rt.strings[slot] = "##{c.r.to_s(16).rjust(2, '0')}" \
                                  "#{c.g.to_s(16).rjust(2, '0')}" \
                                  "#{c.b.to_s(16).rjust(2, '0')}"
            end
            h.label("  ")
          end
        end
      end
    end
  end

  private def demo_color(hex : String?) : Egui::Color32
    if (s = hex) && s.size == 7 &&
       (r = s[1, 2].to_u8?(16)) && (g = s[3, 2].to_u8?(16)) &&
       (b = s[5, 2].to_u8?(16))
      Egui::Color32.new(r, g, b, 255_u8)
    else
      Egui::Color32.rgb(0xd9, 0xd9, 0xd9)
    end
  end
end

# ── the showcase shell ──────────────────────────────────────────────────

class CssShowcaseApp < Egui::App
  @sections = [
    BorderRadiusSection.new,
    ClippingSection.new,
    ClipChildSection.new,
    CompositedScrollSection.new,
    CardFlipSection.new,
    SpringSection.new,
    AppearSection.new,
    OvalProgressSection.new,
  ] of CssSection
  @section = 0
  @entered = -1
  @base : Egui::Theme? = nil

  def update(ctx : Egui::Context) : Nil
    @base ||= ctx.theme
    ctx.side_panel(:left, "css_nav", width: 190.0, resizable: false) do |side|
      side.heading("CSS showcase")
      @sections.each_with_index do |section, i|
        side.selectable(@section == i, section.label) { |v| @section = i if v }
      end
    end

    # Activation step: each section swaps in its own theme, on section
    # change only (re-assigning a theme every frame would rebuild
    # presets and drop runtime style state).
    if @entered != @section
      @entered = @section
      @sections[@section].enter(ctx, @base.not_nil!)
    end
    @sections[@section].render(ctx)
  end
end

# Executed directly → run the windowed app; required from a probe →
# just define the classes (headless screenshots reuse them).
if PROGRAM_NAME.ends_with?("css_showcase")
  Egui.run(CssShowcaseApp.new, title: "egui.cr — CSS showcase",
    width: 1100, height: 800, inspector: :hidden)
end
