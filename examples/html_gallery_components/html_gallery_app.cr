# egui.cr html gallery app — the NativeHTML vocabulary demo (also
# driven headless by bench/html_bench.cr). The entry point is
# examples/html_gallery.cr.

require "../../src/egui"
require "../../src/egui/html"
require "../icon"

class HtmlGalleryApp < Egui::App
  # One demo card: the title doubles as the search key together with the
  # three code panels. `render` paints the live result into the card's
  # right column.
  class Demo
    getter title : String
    getter crystal : String
    getter ecss : String
    getter exml : String
    getter render : Egui::Ui ->

    def initialize(@title : String, @crystal : String, @ecss : String,
                   @exml : String, &@render : Egui::Ui ->)
    end

    def matches?(needle : String) : Bool
      needle.empty? ||
        "#{@title}\n#{@crystal}\n#{@ecss}\n#{@exml}".downcase.includes?(needle)
    end
  end

  class Section
    getter title : String
    getter demos : Array(Demo)

    def initialize(@title : String, @demos : Array(Demo))
    end
  end

  SWATCHES = %w[#e01b4c #f5c211 #33d17a #3584e4 #9141ac #ff7800]
  CHIPS    = ["chip one", "chip two", "chip three", "chip four",
              "chip five", "chip six", "chip seven"]

  # Search string (cards are filtered by it against their code text).
  @query = ""
  @rules_ready = false

  # Interactive demo state — Signals so values survive card filtering
  # (positional widget ids shift when cards drop out; signals don't).
  @name    = Egui::Signal(String).new("typed value")
  @ph      = Egui::Signal(String).new("")
  @sel     = Egui::Signal(String).new("Two")
  @ok      = Egui::Signal(Bool).new(true)
  @checked = Egui::Signal(Bool).new(true)
  @vol     = Egui::Signal(Float64).new(40.0)
  @ta      = Egui::Signal(String).new("line one\nline two\nline three\nline four")
  @radio   = 0
  @dlg_open = false

  # canvas2d gradient demos — ops recorded once, baked per version.
  @radial_canvas : Egui::Canvas2D?
  @linear_canvas : Egui::Canvas2D?
  # T-zero for the animated-progress card (Time::Instant diff → seconds).
  @t0 = Time.instant

  def update(ctx : Egui::Context) : Nil
    # The animated-progress and spinner cards need continuous frames.
    ctx.request_repaint
    setup_rules(ctx) unless @rules_ready

    needle = @query.strip.downcase
    total = sections.sum(&.demos.size)
    visible = sections.sum { |s| s.demos.count { |d| d.matches?(needle) } }

    # The HTML `#top` bar: a real search strip (~60px, not egui's thin
    # one-line default), the title at 16px, the input a 480px field
    # styled through the "search.text_edit" rule (registered in
    # #setup_rules), everything vertically centered.
    ctx.top_panel(id: "search", height: 60.0, resizable: false) do |bar|
      bar.seed_row_height(bar.available_height)
      # Side padding aligned with the card column below (the panel
      # already adds its own window_padding).
      bar.allocate_space(Egui::Vec2.new(16.0, 0.0))
      bar.rich(Egui::RichText.new("html gallery")
        .size(bar.style.font_size * 1.05))
      resp = bar.with_style_scope("search") do |s|
        s.add(Egui::TextEdit.new(@query,
          hint: "filter by code / ecss / exml / title…",
          focus_id: "html_gallery_search").width(480.0))
      end
      @query = resp.widget_text.not_nil! if resp.changed?
      bar.rich(Egui::RichText.new("#{visible}/#{total}")
        .weak(bar.style.visuals))
    end

    ctx.central_panel do |ui|
      # virtual: offscreen cards are not built at all (extent replay
      # from the row cache) — ~5 visible cards instead of 71 per frame.
      ui.scroll_area(virtual: true) do |scroll|
        # The HTML `main` box: 16px screen margins, content capped at
        # 1100px and centered. An UNPAINTED wrapper div (no fill/stroke,
        # so nothing draws at the viewport edges) — the overlay
        # scrollbar still rides the window edge like the browser's.
        pad = {(scroll.available_width - 1100.0) / 2.0, 16.0}.max
        scroll.div(style: "padding-x: #{pad}; padding-y: 16") do |page|
          any = false
          sections.each do |sec|
            demos = sec.demos.select { |d| d.matches?(needle) }
            next if demos.empty?
            any = true
            # The HTML `h2`: small, dim, uppercase — not a heading-scale
            # label with a separator-sized gap around it.
            page.allocate_space(Egui::Vec2.new(0.0, 8.0))
            page.rich(Egui::RichText.new(sec.title.upcase)
              .size(page.style.font_size * 0.9).weak(page.style.visuals))
            page.separator
            demos.each do |d|
              page.virtual_row(d.title) { |card| render_card(card, d) }
            end
          end
          page.label("(no cards match #{@query})") unless any
        end
      end
    end

    # The dialog card's modal — app level, like a browser <dialog>.
    if @dlg_open
      clicked = ui_dialog(ctx)
      @dlg_open = false if clicked == "Close"
    end
  end

  private def ui_dialog(ctx : Egui::Context) : String?
    ctx.modal(id: "html_gallery_dlg", title: "Modal",
      buttons: ["Close"]) do |m|
      m.p("everything else is blocked")
    end
  end

  # Demo-specific stylesheet rules, registered once — the cards with a
  # `classes:` surface (scoped rules, the cascade card, the hover pill).
  private def setup_rules(ctx : Egui::Context) : Nil
    sheet = ctx.stylesheet
    sheet.rule("lime", Egui::StyleVars{
      "background" => Egui::Color32.rgba(51, 209, 122, 85),
    })
    sheet.rule("lime.button", Egui::StyleVars{
      "background" => Egui::Color32.rgb(51, 209, 122),
    })
    sheet.rule("btnx.button", Egui::StyleVars{
      "text_color" => Egui::Color32.rgb(90, 142, 224),
    })
    sheet.rule("pill", Egui::StyleVars{
      "background" => Egui::Color32.rgb(51, 51, 60),
      "rounding"   => 6.0,
      "transition" => 180.0,
    })
    sheet.rule("pill:hover", Egui::StyleVars{
      "background" => Egui::Color32.rgb(53, 132, 228),
    })
    # The `#top input` from the HTML reference: dark field, hairline
    # border, 6px rounding, 8/12 padding. Scoped under "search" so the
    # demo inputs inside cards keep the default look.
    sheet.rule("search.text_edit", Egui::StyleVars{
      "fill"           => Egui::Color32.rgb(23, 23, 28),
      "stroke"         => Egui::Color32.rgb(58, 58, 68),
      "rounding"       => 6.0,
      "padding.top"    => 8.0,
      "padding.bottom" => 8.0,
      "padding.left"   => 12.0,
      "padding.right"  => 12.0,
    })
    # The textarea demo card: a scoped tint + mono face + softer box
    # (the `classes: "ta"` wrapper div, like `search.text_edit` above).
    sheet.rule("ta.textarea", Egui::StyleVars{
      "text_color"  => Egui::Color32.rgb(126, 231, 135),
      "font_family" => "monospace",
      "rounding"    => 6.0,
    })
    # The `.code textarea` trio from the HTML reference: one dark box
    # (#17171c fill, #3a3a44 hairline, 6px rounding), text color per
    # mode — Crystal green, ECSS lilac, EXML blue.
    {"code-cr"   => Egui::Color32.rgb(205, 227, 200),
     "code-ecss" => Egui::Color32.rgb(219, 199, 232),
     "code-exml" => Egui::Color32.rgb(200, 217, 240)}.each do |cls, color|
      sheet.rule("#{cls}.textarea", Egui::StyleVars{
        "text_color" => color,
        "fill"       => Egui::Color32.rgb(23, 23, 28),
        "stroke"     => Egui::Color32.rgb(58, 58, 68),
        "rounding"   => 6.0,
      })
    end
    # The float:right demo: the paragraph's own right padding reserves
    # the gutter the overlay block pins into ("fright" scope).
    sheet.rule("fright.label", Egui::StyleVars{
      "padding.right" => 84.0,
    })
    @rules_ready = true
  end

  # === card chrome =================================================

  # The HTML `.card`: filled, 1px line border, 8px rounding, tighter
  # y padding than x — and the result column gets the `.result` frame
  # (dashed in the browser; a thin solid line here) so the live demo
  # reads as a panel, not loose content.
  private def render_card(ui : Egui::Ui, demo : Demo) : Nil
    ui.div(style: "background: #26262d; stroke: #3a3a44; border-radius: 8; padding-x: 12; padding-y: 10") do |card|
      card.rich(Egui::RichText.new(demo.title)
        .size(card.style.font_size * 0.85).weak(card.style.visuals))
      card.columns(2) do |cols|
        code_panels(cols[0], demo)
        cols[1].div(style: "background: #232329; stroke: #3a3a44; border-radius: 6; padding: 10") do |res|
          demo.render.call(res)
        end
      end
    end
  end

  # The left side: the three code panels — Crystal, ECSS and EXML —
  # each a tiny dim caption over a readonly textarea, all open at once.
  # The wrapper class picks the per-mode text color from the sheet (the
  # `.code textarea` / `.code textarea.ecss` / `.code textarea.exml`
  # colors of the HTML reference).
  private def code_panels(ui : Egui::Ui, demo : Demo) : Nil
    [{"Crystal", demo.crystal, "code-cr"}, {"ECSS", demo.ecss, "code-ecss"},
     {"EXML", demo.exml, "code-exml"}].each_with_index do |(label, code, cls), i|
      ui.rich(Egui::RichText.new(label)
        .size(ui.style.font_size * 0.7).weak(ui.style.visuals))
      rows = {code.count('\n') + 1, 8}.min
      ui.div(classes: cls) do |d|
        d.add(Egui::TextArea.new(code, nil, rows, true,
          focus_id: "code:#{demo.title}:#{i}",
          cursor_blinks: false, readonly: true))
      end
    end
  end

  # A sized color swatch — the reference's flat `<div>`: a label with
  # a background style at an exact size. NOT `ui.p` — a paragraph's
  # breathing (0.35 line heights + spacing) would drop the block below
  # its anchor, e.g. ~13px low inside an overlay pin.
  private def swatch(ui : Egui::Ui, hex : String, w : Int32, h : Int32) : Nil
    block = Egui::Label.new(" ")
    block.style { |s| s.background = Egui::Html.color(hex).not_nil! }
    ui.add_sized(Egui::Vec2.new(w.to_f, h.to_f), block)
  end

  # A sized styled block that reports its rect — the canvas the
  # positioning demos re-base overlays on (#swatch discards it).
  private def sized_block(ui : Egui::Ui, style : String,
                          w : Int32, h : Int32) : Egui::Rect
    ui.p(" ", style: style, width: w, height: h).not_nil!.rect
  end

  # === the demo list ===============================================

  private def sections : Array(Section)
    @sections ||= [
      Section.new("Text", text_demos),
      Section.new("Lists", list_demos),
      Section.new("Fills & backgrounds", fill_demos),
      Section.new("Gradients", gradient_demos),
      Section.new("Layout & sizing", layout_demos),
      Section.new("Float & positioning", position_demos),
      Section.new("Containers", container_demos),
      Section.new("Forms", form_demos),
      Section.new("States & attributes", state_demos),
      Section.new("Animations", animation_demos),
      Section.new("Media & links", media_demos),
    ]
  end

  private def text_demos : Array(Demo)
    [
      Demo.new("h1..h6 — heading scale",
        %(ui.h1("Heading 1")\nui.h2("Heading 2")\nui.h3("Heading 3")\n# … h4, h5 down to h6 (2em…0.67em, bold)),
        %(/* one heading kind; the h1..h6 scale is Crystal-side */),
        %(<heading text="Heading 1"/>)) do |ui|
        ui.h1("Heading 1")
        ui.h2("Heading 2")
        ui.h3("Heading 3")
        ui.h4("Heading 4")
        ui.h5("Heading 5")
        ui.h6("Heading 6")
      end,
      Demo.new("p — paragraph",
        %(ui.p("A paragraph — a label with\nbreathing room above and below.")),
        %(/* p = label + 0.35 line-height margins (built in) */),
        %(<label text="A paragraph — margins are Crystal-side"/>)) do |ui|
        ui.p("A paragraph — a label with breathing room above and below.")
      end,
      Demo.new("p + color",
        %(ui.p("red text", style: "color: #e01b4c")),
        %(alert { text_color: #e01b4c }),
        %(<alert text="red text"/>)) do |ui|
        ui.p("red text", style: "color: #e01b4c")
      end,
      Demo.new("p + font-size: 24",
        %(ui.p("24px text", style: "font-size: 24")),
        %(big-text { font_size: 24 }),
        %(<big-text text="24px text"/>)) do |ui|
        ui.p("24px text", style: "font-size: 24")
      end,
      Demo.new("span — inline row",
        %(ui.span do |s|\n  s.strong("bold")\n  s.em("italic")\n  s.code("mono")\n  s.label("plain")\nend),
        %(/* strong/em/code are RichText runs, not style rules */),
        %(<row>\n  <b text="bold"/> <i text="italic"/>\n  <mono-run text="mono"/> <label text="plain"/>\n</row>)) do |ui|
        ui.span do |s|
          s.strong("bold")
          s.em("italic")
          s.code("mono")
          s.label("plain")
        end
      end,
      Demo.new("span + br — hard break",
        %(ui.span do |s|\n  s.label("before break")\n  s.br\n  s.label("after break")\nend),
        %(/* br is flow, not style */),
        %(<row><label text="before break"/></row>\n<row><label text="after break"/></row>)) do |ui|
        ui.span do |s|
          s.label("before break")
          s.br
          s.label("after break")
        end
      end,
      Demo.new("strong / em / code",
        %(ui.strong("strong text")\nui.em("emphasized text")\nui.code("code text")),
        %(mono-run { font_family: monospace }),
        %(<b text="strong text"/>\n<i text="emphasized text"/>\n<mono-run text="code text"/>)) do |ui|
        ui.strong("strong text")
        ui.em("emphasized text")
        ui.code("code text")
      end,
      Demo.new("mark — highlight",
        %(ui.mark("highlighted with the selection color")),
        %(mark { text_color: selection_fill }),
        %(<mark text="highlighted"/>)) do |ui|
        ui.mark("highlighted with the selection color")
      end,
      Demo.new("small",
        %(ui.small("small print, 0.83em")),
        %(small { font_size: 0.83rem }),
        %(<small text="small print, 0.83em"/>)) do |ui|
        ui.small("small print, 0.83em")
      end,
      Demo.new("sub / sup",
        %(ui.span do |s|\n  s.label("H"); s.sub("2")\n  s.label("O"); s.sup("2")\nend),
        %(sub, sup { font_size: 0.75em }),
        %(<row><label text="H"/><sub text="2"/>\n<label text="O"/><sup text="2"/></row>)) do |ui|
        ui.span do |s|
          s.label("H")
          s.sub("2")
          s.label("O")
          s.sup("2")
        end
        ui.small("(baseline is not shifted in the engine)")
      end,
      Demo.new("pre — preformatted + h-scroll",
        %(ui.pre(%[line one   stays\n    line two keeps spaces\n        line three — a very long line that overflows and scrolls horizontally])),
        %(pre { font_family: monospace }),
        %(<pre-run text="line one   stays"/>)) do |ui|
        ui.pre("line one   stays\n    line two keeps spaces\n" \
               "        line three — a very long line that overflows and scrolls horizontally")
      end,
      Demo.new("hr — horizontal rule",
        %(ui.p("above")\nui.hr\nui.p("below")),
        %(separator { separator_color: dim }),
        %(<label text="above"/>\n<separator/>\n<label text="below"/>)) do |ui|
        ui.p("above")
        ui.hr
        ui.p("below")
      end,
      Demo.new("blockquote — accent left stroke",
        %(ui.blockquote do |b|\n  b.p("Quoted text with a 3px accent\nstroke on the LEFT edge only.")\nend),
        %(quote { background: panel_fill;\n  stroke.left: 3; padding: 8 12 }),
        %(<quote>\n  <label text="Quoted text with a 3px accent stroke"/>\n</quote>)) do |ui|
        ui.blockquote { |b| b.p("Quoted text with a 3px accent stroke on the LEFT edge only.") }
      end,
    ]
  end

  private def list_demos : Array(Demo)
    [
      Demo.new("ul > li",
        %(ui.ul do |l|\n  l.li("first bullet")\n  l.li("second bullet")\n  l.li("third bullet")\nend),
        %(/* bullet markers are built into li */),
        %(<repeat in="items"><label text="• {item}"/></repeat>)) do |ui|
        ui.ul do |l|
          l.li("first bullet")
          l.li("second bullet")
          l.li("third bullet")
        end
      end,
      Demo.new("ol > li",
        %(ui.ol do |l|\n  l.li("numbered one")\n  l.li("numbered two")\n  l.li("numbered three")\nend),
        %(/* numbering rides the ol list scope */),
        %(<repeat in="items"><label text="{_i}. {item}"/></repeat>)) do |ui|
        ui.ol do |l|
          l.li("numbered one")
          l.li("numbered two")
          l.li("numbered three")
        end
      end,
      Demo.new("ol start: 5",
        %(ui.ol(start: 5) do |l|\n  l.li("five")\n  l.li("six")\nend),
        %(/* start is an attribute, not style */),
        %(<repeat in="items" start="5"><label text="{_i}. {item}"/></repeat>)) do |ui|
        ui.ol(start: 5) do |l|
          l.li("five")
          l.li("six")
        end
      end,
      Demo.new("nested ul inside ol",
        %(ui.ol do |l|\n  l.li("outer one")\n  l.li do |row|\n    row.ul do |inner|\n      inner.li("inner a")\n      inner.li("inner b")\n    end\n  end\nend),
        %(li { margin_left: 14 }),
        %(<repeat in="groups">\n  <label text="• {group.name}"/>\n  <repeat in="group.items">\n    <label text="  • {item}"/>\n  </repeat>\n</repeat>)) do |ui|
        ui.ol do |l|
          l.li("outer one")
          l.li do |row|
            row.ul do |inner|
              inner.li("inner a")
              inner.li("inner b")
            end
          end
        end
      end,
      Demo.new("nested ol inside ol",
        %(ui.ol do |l|\n  l.li("outer one")\n  l.li do |row|\n    row.ol do |inner|\n      inner.li("inner a")\n      inner.li("inner b")\n    end\n  end\n  l.li("outer two")\nend),
        %(/* a nested ol restarts at 1, like the browser */),
        %(<repeat in="groups">\n  <label text="{_g}. {group.name}"/>\n  <repeat in="group.items">\n    <label text="  {_i}. {item}"/>\n  </repeat>\n</repeat>)) do |ui|
        ui.ol do |l|
          l.li("outer one")
          l.li do |row|
            row.ol do |inner|
              inner.li("inner a")
              inner.li("inner b")
            end
          end
          l.li("outer two")
        end
      end,
    ]
  end

  private def fill_demos : Array(Demo)
    [
      Demo.new("div + background solid",
        %(ui.div(style: "background: #3584e4; padding: 12") do |d|\n  d.p("Solid fill")\nend),
        %(card {\n  background: #3584e4;\n  padding: 12; rounding: 6;\n}),
        %(<card><label text="Solid fill"/></card>)) do |ui|
        ui.div(style: "background: #3584e4; padding: 12") { |d| d.p("Solid fill") }
      end,
      Demo.new("fill palette strip",
        %(SWATCHES = %w[#e01b4c #f5c211 #33d17a\n                 #3584e4 #9141ac #ff7800]\nui.span do |s|\n  SWATCHES.each { |hex| swatch(s, hex) }\nend\n# swatch: block = Label.new(" ")\n#   block.style { |s| s.background = Html.color(hex) }\n#   ui.add_sized(Vec2.new(44, 26), block)),
        %(swatch { height: 26; rounding: 6 }\nswatch.red    { background: #e01b4c }\nswatch.yellow { background: #f5c211 }\nswatch.green  { background: #33d17a }),
        %(<row>\n  <repeat in="palette"><swatch class="{item.name}"/></repeat>\n</row>)) do |ui|
        ui.span do |s|
          SWATCHES.each { |hex| swatch(s, hex, 44, 26) }
        end
      end,
      Demo.new("rgba(…, 0.4) translucent",
        %(ui.div(style: "background: #1b6ef3") do |d|\n  d.div(style: "background: #ffffff66; padding: 10") do |t|\n    t.p("40% white over blue")\n  end\nend),
        %(over { background: #1b6ef3 }\nover .glass {\n  background: #ffffff66; padding: 10;\n}),
        %(<over><glass>\n  <label text="40% white over blue"/>\n</glass></over>)) do |ui|
        ui.div(style: "background: #1b6ef3") do |d|
          d.div(style: "background: #ffffff66; padding: 10") { |t| t.p("40% white over blue") }
        end
      end,
      Demo.new("div + stroke border",
        %(ui.div(style: "stroke: #e01b4c; padding: 10") do |d|\n  d.p("Border only")\nend),
        %(outlined {\n  stroke: #e01b4c; stroke-width: 1;\n  padding: 10; rounding: 6;\n}),
        %(<outlined><label text="Border only"/></outlined>)) do |ui|
        ui.div(style: "stroke: #e01b4c; padding: 10") { |d| d.p("Border only") }
      end,
      Demo.new("div + border-radius: 16",
        %(ui.div(style: "background: #33d17a;\n            border-radius: 16; padding: 12") do |d|\n  d.p("rounded")\nend),
        %(pill-green { background: #33d17a;\n  rounding: 16; padding: 12 }),
        %(<pill-green><label text="rounded"/></pill-green>)) do |ui|
        ui.div(style: "background: #33d17a; border-radius: 16; padding: 12") { |d| d.p("rounded") }
      end,
      Demo.new("radius ramp 0 / 8 / 16 / 28",
        %([0, 8, 16, 28].each do |r|\n  ui.div(style: "background: #9141ac;\n        border-radius: \#{r}; padding: 10") do |d|\n    d.small("r\#{r}")\n  end\nend),
        %(ramp { background: #9141ac; padding: 10 }\nramp.r0  { rounding: 0 }\nramp.r8  { rounding: 8 }\nramp.r16 { rounding: 16 }\nramp.r28 { rounding: 28 }),
        %(<row>\n  <repeat in="radii">\n    <ramp class="r{item}"><label text="r{item}"/>\n  </repeat>\n</row>)) do |ui|
        ui.span do |s|
          [0, 8, 16, 28].each do |r|
            s.div(style: "background: #9141ac; border-radius: #{r}; padding: 10") do |d|
              d.small("r#{r}")
            end
          end
        end
      end,
      Demo.new("div + padding: 16",
        %(ui.div(style: "stroke: #777; padding: 16") do |d|\n  d.div(style: "background: #3584e4; padding: 8") { |i| i.p("inner") }\nend),
        %(pad-demo { stroke: #777; padding: 16 }\npad-demo .inner {\n  background: #3584e4; padding: 8;\n}),
        %(<pad-demo><inner>\n  <label text="inner"/>\n</inner></pad-demo>)) do |ui|
        ui.div(style: "stroke: #777; padding: 16") do |d|
          d.div(style: "background: #3584e4; padding: 8") { |i| i.p("inner") }
        end
      end,
      Demo.new("padding-x vs padding-y",
        %(ui.div(style: "background: #f5c211;\n        padding-x: 24; padding-y: 4") do |d|\n  d.p("wide x, tight y")\nend),
        %(pad-xy {\n  background: #f5c211;\n  padding.left: 24; padding.right: 24;\n  padding.top: 4;  padding.bottom: 4;\n}),
        %(<pad-xy><label text="wide x, tight y"/></pad-xy>)) do |ui|
        ui.div(style: "background: #f5c211; padding-x: 24; padding-y: 4") { |d| d.p("wide x, tight y") }
      end,
      Demo.new("fill + stroke + radius combo",
        %(ui.div(style: "background: #1e1e24;\n        stroke: #3584e4; border-radius: 12;\n        padding: 12") do |d|\n  d.p("all three together")\nend),
        %(combo {\n  background: #1e1e24;\n  stroke: #3584e4; stroke-width: 1;\n  rounding: 12; padding: 12;\n}),
        %(<combo><label text="all three together"/></combo>)) do |ui|
        ui.div(style: "background: #1e1e24; stroke: #3584e4; border-radius: 12; padding: 12") do |d|
          d.p("all three together")
        end
      end,
      Demo.new("nested div fills",
        %(ui.div(style: "background: #3584e4; padding: 10") do |a|\n  a.div(style: "background: #33d17a; padding: 10") do |b|\n    b.div(style: "background: #f5c211; padding: 10") do |c|\n      c.p("three levels deep")\n    end\n  end\nend),
        %(nest-a { background: #3584e4; padding: 10 }\nnest-b { background: #33d17a; padding: 10 }\nnest-c { background: #f5c211; padding: 10 }),
        %(<nest-a><nest-b><nest-c>\n  <label text="three levels deep"/>\n</nest-c></nest-b></nest-a>)) do |ui|
        ui.div(style: "background: #3584e4; padding: 10") do |a|
          a.div(style: "background: #33d17a; padding: 10") do |b|
            b.div(style: "background: #f5c211; padding: 10") { |c| c.p("three levels deep") }
          end
        end
      end,
      Demo.new("box-shadow — outset",
        %(ui.div(style: "padding: 14") do |w|\n  w.div(style: "background: #26262d; border-radius: 8;\n        padding: 12;\n        box-shadow: 0 4px 12px rgba(0,0,0,.5)") do |d|\n    d.p("floating")\n  end\nend),
        %(floaty {\n  background: #26262d; rounding: 8; padding: 12;\n  shadow.color: #00000080;\n  shadow.blur: 12; shadow.y: 4;\n}),
        %(<floaty><label text="floating"/></floaty>)) do |ui|
        ui.div(style: "padding: 14") do |w|
          w.div(style: "background: #26262d; border-radius: 8; padding: 12; box-shadow: 0 4px 12px rgba(0,0,0,.5)") { |d| d.p("floating") }
        end
      end,
      Demo.new("box-shadow — inset",
        %(ui.div(style: "padding: 14") do |w|\n  w.div(style: "background: #1e1e24; border-radius: 8;\n        padding: 12;\n        box-shadow: inset 0 2px 8px rgba(0,0,0,.6)") do |d|\n    d.p("pressed in")\n  end\nend),
        %(well {\n  background: #1e1e24; rounding: 8; padding: 12;\n  shadow.color: #00000099;\n  shadow.blur: 8; shadow.y: 2; shadow.inset: true;\n}),
        %(<well><label text="pressed in"/></well>)) do |ui|
        ui.div(style: "padding: 14") do |w|
          w.div(style: "background: #1e1e24; border-radius: 8; padding: 12; box-shadow: inset 0 2px 8px rgba(0,0,0,.6)") { |d| d.p("pressed in") }
        end
      end,
    ]
  end

  private def gradient_demos : Array(Demo)
    [
      Demo.new("linear gradient (2 stops)",
        %(b = Egui::Button.new("Gradient")\n  .gradient(Egui::Color32.rgb(60,150,90),\n            Egui::Color32.rgb(24,80,48))\nui.add(b)),
        %(/* no ECSS gradient key yet */),
        %(<!-- no gradient element yet — engine: Button#gradient / canvas2d -->)) do |ui|
        ui.add(Egui::Button.new("Gradient")
          .gradient(Egui::Color32.rgb(60, 150, 90), Egui::Color32.rgb(24, 80, 48)))
      end,
      Demo.new("radial gradient",
        %(g = c2d.create_radial_gradient(60, 60, 0, 60, 60, 60*Math.sqrt(2))\ng.add_color_stop(0, Egui::Color32.rgb(255,255,255))\ng.add_color_stop(1, Egui::Color32.rgb(53,132,228))\nc2d.fill_style = g\nc2d.fill_rect(0, 0, 120, 120)),
        %(demo { background-gradient: radial-gradient(circle, #ffffff, #3584e4) }),
        %(<canvas-view id="glow" w="120" h="120"/>)) do |ui|
        ui.canvas2d(radial_canvas) { }
      end,
      Demo.new("multi-stop gradient",
        %(g = c2d.create_linear_gradient(0, 0, 200, 0)\ng.add_color_stop(0.0, Egui::Color32.rgb(224,27,76))\ng.add_color_stop(0.5, Egui::Color32.rgb(245,194,17))\ng.add_color_stop(1.0, Egui::Color32.rgb(51,209,122))\nc2d.fill_style = g\nc2d.fill_rect(0, 0, 200, 36)),
        %(/* no ECSS gradient key yet */),
        %(<canvas-view id="spectrum" w="200" h="36"/>)) do |ui|
        ui.canvas2d(linear_canvas) { }
      end,
    ]
  end

  private def layout_demos : Array(Demo)
    [
      Demo.new("block flow nesting",
        %(ui.div(style: "stroke: #777; padding: 8") do |d|\n  d.p("block one fills the width")\n  d.p("block two below it")\n  d.span { |s| s.p("span row: a"); s.p("b"); s.p("c") }\n  d.p("block after the row")\nend),
        %(/* linear block flow: top to bottom */),
        %(<column>\n  <label text="block one fills the width"/>\n  <label text="block two below it"/>\n  <row><label text="a"/> <label text="b"/> <label text="c"/></row>\n  <label text="block after the row"/>\n</column>)) do |ui|
        ui.div(style: "stroke: #777; padding: 8") do |d|
          d.p("block one fills the width")
          d.p("block two below it")
          d.span { |s| s.p("span row: a"); s.p("b"); s.p("c") }
          d.p("block after the row")
        end
      end,
      Demo.new("span no-wrap row",
        %(ui.span do |s|\n  s.div(style: "background: #e01b4c; padding: 8") { }\n  s.div(style: "background: #33d17a; padding: 8") { }\n  s.div(style: "background: #3584e4; padding: 8") { }\nend),
        %(chip-red   { background: #e01b4c; padding: 8 }\nchip-green { background: #33d17a; padding: 8 }\nchip-blue  { background: #3584e4; padding: 8 }),
        %(<row>\n  <chip-red/><chip-green/><chip-blue/>\n</row>)) do |ui|
        ui.span do |s|
          s.div(style: "background: #e01b4c; padding: 8") { |d| d.p(" ") }
          s.div(style: "background: #33d17a; padding: 8") { |d| d.p(" ") }
          s.div(style: "background: #3584e4; padding: 8") { |d| d.p(" ") }
        end
      end,
      Demo.new("width + height pinned",
        %(# a sized swatch: label + background style\nui.p("", style: "background: #9141ac",\n  width: 120, height: 60)),
        %(pinned {\n  background: #9141ac;\n  width: 120; height: 60;\n}),
        %(<pinned/>)) do |ui|
        swatch(ui, "#9141ac", 120, 60)
      end,
      Demo.new("wrapping row",
        %(CHIPS = ["chip one", "chip two", "chip three",\n         "chip four", "chip five", "chip six", "chip seven"]\nui.horizontal(wrap: true) do |s|\n  CHIPS.each { |c| s.small(c) }\nend),
        %(chips { wrap: true }\nchips .chip { background: #33333c; rounding: 6 }),
        %(<row wrap="true">\n  <repeat in="chips"><chip text="{item}"/>\n</row>)) do |ui|
        ui.horizontal(wrap: true) do |s|
          CHIPS.each { |c| s.div(style: "background: #33333c; border-radius: 6; padding: 4") { |d| d.small(c) } }
        end
      end,
      Demo.new("columns(3)",
        %(ui.columns(3) do |cols|\n  cols.each_with_index do |col, i|\n    col.p("column \#{i}")\n    col.p("second line")\n  end\nend),
        %(/* equal-width columns are layout, not style */),
        %(<row>\n  <column><label text="column 0"/><label text="second line"/></column>\n  <column><label text="column 1"/><label text="second line"/></column>\n  <column><label text="column 2"/><label text="second line"/></column>\n</row>)) do |ui|
        ui.columns(3) do |cols|
          cols.each_with_index do |col, i|
            col.div(style: "stroke: #777; padding: 6") do |d|
              d.p("column #{i}")
              d.p("second line")
            end
          end
        end
      end,
      Demo.new("page frame: header/nav/aside/main/footer",
        %(ui.header { |h| h.p("header") }\nui.nav { |n| n.p("nav") }\nui.aside { |a| a.p("aside") }\nui.main { |m| m.p("main content flows in\n  what is left between the panels") }\nui.footer { |f| f.p("footer") }),
        %(/* panels are app-level chrome; styled\n   through the theme/ECSS per panel class */\nnav-panel { background: #24242b; width: 84 }\naside-panel { background: #24242b; width: 70 }),
        %(<menubar><item label="header"/></menubar>\n<central><row>\n  <nav-panel><label text="nav"/>\n  <label text="main content"/>\n  <aside-panel><label text="aside"/>\n</row></central>\n<statusbar><label text="footer"/></statusbar>)) do |ui|
        # Panels frame the WHOLE window — inside the card a schematic
        # mock instead (the calls above are the real API).
        ui.div(style: "stroke: #3a3a44; padding: 0") do |m|
          m.div(style: "background: #2d2d36; padding: 4") { |h| h.small("header") }
          m.horizontal(wrap: false) do |row|
            row.div(style: "background: #24242b; padding: 4") { |n| n.small("nav") }
            row.div(style: "background: #1e1e24; padding: 4") { |c| c.small("main content") }
            row.div(style: "background: #24242b; padding: 4") { |a| a.small("aside") }
          end
          m.div(style: "background: #2d2d36; padding: 4") { |f| f.small("footer") }
        end
        ui.small("(mock — the real panels frame the whole window)")
      end,
    ]
  end

  # Float & positioning: the engine has no `float`/`position` style
  # keys (the flow is linear), so these demos show the two real
  # mechanisms: wrapped text beside a block in a row (float), and
  # `ui.overlay` — the region-anchored floating block with nine
  # anchors, margin and z (absolute / fixed / z-index).

  private def position_demos : Array(Demo)
    [
      Demo.new("float: left — text beside the block",
        %(# the flow is linear: the block goes FIRST in the\n# row, the wrapped text flows beside it\nui.horizontal(wrap: false) do |row|\n  swatch(row, "#3584e4", 64, 64)\n  row.rich(Egui::RichText.new(text), wrap: true)\nend),
        %(/* no float key — the row order IS the float */),
        %(<row>\n  <image src="block.png" w="64" h="64"/>\n  <label wrap="true" text="wraps beside the block"/>\n</row>)) do |ui|
        ui.horizontal(wrap: false) do |row|
          swatch(row, "#3584e4", 64, 64)
          row.rich(Egui::RichText.new(
            "The blue block is declared first in the row and this paragraph " \
            "wraps beside it, line after line — the magazine drop-cap column. " \
            "The engine's rows are linear, so the text keeps its own column " \
            "and never reflows below the block (a CSS float wraps back to " \
            "full width once past it)."), wrap: true)
        end
      end,
      Demo.new("float: right — pinned into a reserved gutter",
        %(# the paragraph's own padding reserves the gutter\nrect = ui.div do |d|\n  d.with_style_scope("fright") do |s|\n    s.rich(Egui::RichText.new(text), wrap: true)\n  end\nend.not_nil!\nui.overlay(:top_right, rect: rect,\n    margin: StyleBox.new(top: 4, right: 4),\n    pass_through: true) do |o|\n  swatch(o, "#33d17a", 72, 48)\nend),
        %(fright.label { padding.right: 84 }),
        %(<label wrap="true" style="padding-right: 84" text="wraps left of the gutter"/>\n<overlay anchor="top_right">\n  <image src="block.png" w="72" h="48"/>\n</overlay>)) do |ui|
        rect = ui.div do |d|
          d.with_style_scope("fright") do |s|
            s.rich(Egui::RichText.new(
              "The right gutter is the paragraph's own right padding; the " \
              "green block is pinned into it with an overlay anchor and the " \
              "text wraps along the left — the flow never sees the block, " \
              "like a CSS float taken out of the normal flow."), wrap: true)
          end
        end.not_nil!
        ui.overlay(:top_right, rect: rect,
          margin: Egui::StyleBox.new(top: 4.0, right: 4.0),
          pass_through: true, id: "html_gallery_fright") do |o|
          swatch(o, "#33d17a", 72, 48)
        end
      end,
      Demo.new("clear — the next block drops below",
        %(ui.horizontal(wrap: false) do |row|\n  swatch(row, "#f5c211", 56, 56)\n  row.rich(Egui::RichText.new("floated pair…"), wrap: true)\nend\n# every div is a block — it starts below, full width\nui.div(style: "stroke: #777; padding: 6") do |d|\n  d.small("cleared block")\nend),
        %(/* block flow clears implicitly — every div is\n   a block below the previous row */),
        %(<row>\n  <image src="block.png" w="56" h="56"/>\n  <label wrap="true" text="floated pair"/>\n</row>\n<box><label text="cleared block — full width"/></box>)) do |ui|
        ui.horizontal(wrap: false) do |row|
          swatch(row, "#f5c211", 56, 56)
          row.rich(Egui::RichText.new(
            "A floated pair — block and the text beside it. Whatever comes " \
            "next starts below the pair, spanning the full width again: " \
            "the engine's block flow clears by construction, no explicit " \
            "clear is needed."), wrap: true)
        end
        ui.div(style: "stroke: #777; padding: 6") do |d|
          d.small("cleared block — below the floats, full width")
        end
      end,
      Demo.new("position: absolute — corner badge",
        %(# rect: re-bases the overlay on the parent's own rect\nrect = ui.div(style: "background: #1e1e24; padding: 8") do |d|\n  d.p("the parent div is the positioning context")\nend.not_nil!\nui.overlay(:top_right, rect: rect,\n    margin: StyleBox.new(top: 6, right: 6)) do |o|\n  o.span do |s|  # span = shrink-to-fit (a bare div is a\n    s.div(style: "background: #e01b4c") { |b| b.small("NEW") }\n  end           # block — it would span the full width)\nend),
        %(overlay {\n  anchor: top_right;\n  margin: 6 6 0 0;\n}),
        %(<box style="position: relative">\n  <label text="the parent is the context"/>\n  <badge anchor="top_right" text="NEW"/>\n</box>)) do |ui|
        rect = ui.div(style: "background: #1e1e24; stroke: #3a3a44; padding: 8") do |d|
          d.p("the parent div is the positioning context (rect:)")
          d.small("the badge floats on top of it, six pixels off the corner")
        end.not_nil!
        ui.overlay(:top_right, rect: rect,
          margin: Egui::StyleBox.new(top: 6.0, right: 6.0),
          id: "html_gallery_badge") do |o|
          o.span do |s|
            s.div(style: "background: #e01b4c; border-radius: 4; padding-x: 8; padding-y: 2") do |b|
              b.small("NEW")
            end
          end
        end
      end,
      Demo.new("position: absolute — dead center",
        %(rect = ui.p(" ", style: "background: #101014",\n  width: 220, height: 96).not_nil!.rect\nui.overlay(:center, rect: rect) do |o|\n  o.button("▶ Play")\nend),
        %(overlay { anchor: center }),
        %(<player-box/>\n<overlay anchor="center">\n  <button text="▶ Play"/>\n</overlay>)) do |ui|
        rect = sized_block(ui, "background: #101014; stroke: #3a3a44", 220, 96)
        ui.overlay(:center, rect: rect, id: "html_gallery_center") do |o|
          o.button("▶ Play", id: "html_gallery_play")
        end
        ui.small("(the CSS top: 50% / left: 50% / translate(-50%, -50%) recipe)")
      end,
      Demo.new("position: fixed — pinned over scroll",
        %(rect = ui.scroll_area(max_height: 110) do |a|\n  a.p("scrolling content…")\nend\nui.overlay(:bottom_right, rect: rect,\n    margin: StyleBox.new(bottom: 10, right: 10),\n    pass_through: true) do |o|\n  o.button("↑ top")\nend),
        %(overlay {\n  anchor: bottom_right;\n  margin: 0 10 10 0;\n}),
        %(<scroll>\n  <label text="scrolling content…"/>\n</scroll>\n<overlay anchor="bottom_right">\n  <button text="↑ top"/>\n</overlay>)) do |ui|
        rect = ui.scroll_area(max_height: 110.0) do |a|
          {"line one — the content scrolls under the pinned button,",
           "line two — the overlay is anchored to the viewport,",
           "line three — not to the flowing content,",
           "line four — the position: fixed analog,",
           "line five — keep scrolling…",
           "line six — the button never moves."}.each { |l| a.p(l) }
        end
        ui.overlay(:bottom_right, rect: rect,
          margin: Egui::StyleBox.new(bottom: 10.0, right: 10.0),
          pass_through: true, id: "html_gallery_fixed") do |o|
          o.button("↑ top", id: "html_gallery_top")
        end
      end,
      Demo.new("z-index — stacking order",
        %(rect = ui.p(" ", style: "background: #1e1e24",\n  width: 220, height: 96).not_nil!.rect\n# span = shrink-to-fit: a bare div would span the\n# overlay's full width\nui.overlay(:center, rect: rect, z: 10,\n    pass_through: true) do |o|\n  o.span { |s| s.div(style: "background: #e01b4c;\n    padding-x: 18; padding-y: 14") { |d| d.small("z: 10") } }\nend\nui.overlay(:center, rect: rect, z: 20,\n    pass_through: true) do |o|\n  o.span { |s| s.div(style: "background: #3584e4bb;\n    padding-x: 10; padding-y: 6") { |d| d.small("z: 20 — on top") } }\nend),
        %(overlay.back  { anchor: center; z: 10 }\noverlay.front { anchor: center; z: 20 }),
        %(<overlay anchor="center" z="10">\n  <box text="z: 10"/>\n</overlay>\n<overlay anchor="center" z="20">\n  <box text="z: 20 — on top"/>\n</overlay>)) do |ui|
        rect = sized_block(ui, "background: #1e1e24; stroke: #3a3a44", 220, 96)
        ui.overlay(:center, rect: rect, z: 10, pass_through: true,
          id: "html_gallery_z10") do |o|
          o.span do |s|
            s.div(style: "background: #e01b4c; border-radius: 6; padding-x: 18; padding-y: 14") do |d|
              d.small("z: 10")
            end
          end
        end
        ui.overlay(:center, rect: rect, z: 20, pass_through: true,
          id: "html_gallery_z20") do |o|
          o.span do |s|
            s.div(style: "background: #3584e4bb; border-radius: 6; padding-x: 10; padding-y: 6") do |d|
              d.small("z: 20 — on top")
            end
          end
        end
      end,
      Demo.new("z-index — painted out of order",
        %(rect = sized_block(ui, "background: #1e1e24; stroke: #3a3a44", 220, 96)\n# the HIGHER overlay is painted FIRST, the lower\n# AFTER it — insertion order is not z order: the\n# painter's layer sort still puts red under blue\nui.overlay(:center, rect: rect, z: 20,\n    pass_through: true) do |o|\n  o.span { |s| s.div(style: "background: #3584e4bb;\n    padding-x: 10; padding-y: 6") { |d| d.small("z: 20") } }\nend\nui.overlay(:center, rect: rect, z: 10,\n    pass_through: true) do |o|\n  o.span { |s| s.div(style: "background: #e01b4c;\n    padding-x: 18; padding-y: 14") { |d| d.small("z: 10") } }\nend),
        %(/* the same stacking as z-index — the ECSS side\n   is order-independent, z decides */),
        %(<overlay anchor="center" z="20">\n  <box text="z: 20"/>\n</overlay>\n<overlay anchor="center" z="10">\n  <box text="z: 10"/>\n</overlay>)) do |ui|
        rect = sized_block(ui, "background: #1e1e24; stroke: #3a3a44", 220, 96)
        # The blue z:20 overlay is painted BEFORE the red z:10 one —
        # a mid-frame layer regression (0, 20, 10) that the painter
        # must resolve by z, not by insertion order: red still stacks
        # under blue. Exercises the general counting-sort path of
        # Painter#commands_in_layer_order (see the layers.unsorted
        # counter with EGUI_BENCH/PERFORMANCE_OVERLAY).
        ui.overlay(:center, rect: rect, z: 20, pass_through: true,
          id: "html_gallery_oo20") do |o|
          o.span do |s|
            s.div(style: "background: #3584e4bb; border-radius: 6; padding-x: 10; padding-y: 6") do |d|
              d.small("z: 20")
            end
          end
        end
        ui.overlay(:center, rect: rect, z: 10, pass_through: true,
          id: "html_gallery_oo10") do |o|
          o.span do |s|
            s.div(style: "background: #e01b4c; border-radius: 6; padding-x: 18; padding-y: 14") do |d|
              d.small("z: 10")
            end
          end
        end
      end,
    ]
  end

  private def container_demos : Array(Demo)
    [
      Demo.new("fieldset + legend",
        %(ui.fieldset("Legend caption") do |f|\n  f.p("content inside the frame")\n  f.checkbox(@ok, "an option") { |v| @ok = v }\nend),
        %(fieldset { stroke: dim;\n  padding: 8 10 }),
        %(<fieldset legend="Legend caption">\n  <label text="content inside the frame"/>\n  <checkbox bind="ok" text="an option"/>\n</fieldset>)) do |ui|
        ui.fieldset("Legend caption") do |f|
          f.p("content inside the frame")
          f.checkbox(@ok, "an option")
        end
      end,
      Demo.new("details closed",
        %(ui.details("Click to expand") do |d|\n  d.p("hidden body")\nend),
        %(/* collapsing header — no style surface yet */),
        %(<details summary="Click to expand">\n  <label text="hidden body"/></details>)) do |ui|
        ui.details("Click to expand") { |d| d.p("hidden body") }
      end,
      Demo.new("details open",
        %(ui.details("Expanded", open: true) do |d|\n  d.p("visible body from the start")\nend),
        %(/* collapsing header — no style surface yet */),
        %(<details summary="Expanded" open="true">\n  <label text="visible body from the start"/></details>)) do |ui|
        ui.details("Expanded", open: true) { |d| d.p("visible body from the start") }
      end,
      Demo.new("dialog — button opens modal",
        %(if ui.button("Open dialog").clicked?\n  @dlg_open = true\nend\nui.dialog("dlg", title: "Modal", buttons: ["Close"]) do |d|\n  d.p("everything else is blocked")\nend),
        %(modal { rounding: 8; padding: 16 }),
        %(<modal id="dlg" title="Modal"\n       buttons="Close" on_button="close">\n  <label text="everything else is blocked"/></modal>)) do |ui|
        @dlg_open = true if ui.button("Open dialog").clicked?
        ui.small("(the modal opens over the whole app)")
      end,
      Demo.new("iframe — embedded window",
        %(ui.iframe("frame", title: "Embedded",\n  width: 320) do |f|\n  f.p("a floating window over the content")\nend),
        %(/* window chrome comes from the theme */),
        %(<embedded id="frame" title="Embedded" width="320">\n  <label text="a floating window over the content"/></embedded>)) do |ui|
        # The live ui.iframe floats an INTERACTIVE window over the page —
        # its inner scroll sink steals the wheel wherever it hovers, so
        # the gallery shows a static mock (the snippet is the real API).
        ui.div(style: "stroke: #3a3a44; border-radius: 6") do |w|
          w.div(style: "background: #2d2d36; padding: 2 8") { |t| t.small("Embedded  ✕") }
          w.div(style: "padding: 8") { |b| b.p("a floating window over the content") }
        end
        ui.small("(mock — the live window intercepts the wheel over itself)")
      end,
    ]
  end

  private def form_demos : Array(Demo)
    [
      Demo.new("input text",
        %(ui.input(@name) { |t| @name = t }),
        %(text_edit { rounding: 6 }),
        %(<input bind="name"/>)) do |ui|
        ui.input(@name)
      end,
      Demo.new("input + placeholder",
        %(ui.input(@name, placeholder: "type here…") { |t| @name = t }),
        %(text_edit { rounding: 6 }),
        %(<input bind="name" hint="Search…"/>)) do |ui|
        ui.input(@ph, placeholder: "type here…")
      end,
      Demo.new("input disabled",
        %(ui.input(@name, disabled: true) { |t| @name = t }),
        %(/* disabled is an attribute, not a style state */),
        %(<input bind="name" if="editable"/>)) do |ui|
        ui.input("can't touch this", disabled: true) { |t| }
      end,
      Demo.new("select",
        %(ui.select("pick", @sel,\n  ["One", "Two", "Three"]) { |o| @sel = o }),
        %(combo { rounding: 6 }),
        %(<combo bind="sel" options="One,Two,Three"/>)) do |ui|
        ui.select("html_gallery_pick", @sel, ["One", "Two", "Three"])
      end,
      Demo.new("button",
        %(ui.button("Click me")),
        %(button { rounding: 6; padding: 6 14 }),
        %(<button text="Click me" on_click="save"/>)) do |ui|
        ui.button("Click me")
      end,
      Demo.new("button + background",
        %(ui.add(Egui::Button.new("Themed red")\n  .style { |s| s.background = red })),
        %(button.danger { background: #a02a2a }),
        %(<button class="danger" text="Themed red"/>)) do |ui|
        ui.add(Egui::Button.new("Themed red")
          .style { |s| s.background = Egui::Color32.rgb(160, 42, 42) })
      end,
      Demo.new("button gradient",
        %(ui.add(Egui::Button.new("Gradient")\n  .gradient(Egui::Color32.rgb(40,100,200),\n            Egui::Color32.rgb(16,42,92)))),
        %(/* no ECSS gradient key yet */),
        %(<!-- engine: Button#gradient only -->)) do |ui|
        ui.add(Egui::Button.new("Gradient")
          .gradient(Egui::Color32.rgb(40, 100, 200), Egui::Color32.rgb(16, 42, 92)))
      end,
      Demo.new("button disabled",
        %(ui.enabled(false) do |e|\n  e.button("Disabled")\nend),
        %(button:disabled { background: #2a2a31 }),
        %(<button text="Disabled" if="can_save"/>)) do |ui|
        ui.enabled(false) { |e| e.button("Disabled") }
      end,
      Demo.new("button + title tooltip",
        %(ui.button("Hover me")\n  .on_hover_text("a tooltip")),
        %(/* tooltip is an attribute, not style */),
        %(<button text="Hover me" title="a tooltip"/>)) do |ui|
        ui.button("Hover me").on_hover_text("a tooltip")
      end,
      Demo.new("checkbox",
        %(ui.checkbox(@checked, "Check me") { |v| @checked = v }),
        %(checkbox { text_color: text }),
        %(<checkbox bind="checked" text="Check me"/>)) do |ui|
        ui.checkbox(@checked, "Check me")
      end,
      Demo.new("radio",
        %(ui.radio(@sel == 0, "First")\nui.radio(@sel == 1, "Second")\n# state through changed? blocks),
        %(radio { text_color: text }),
        %(<combo bind="sel" options="First,Second"/>)) do |ui|
        ui.radio(@radio == 0, "First").tap { |r| @radio = 0 if r.changed? }
        ui.radio(@radio == 1, "Second").tap { |r| @radio = 1 if r.changed? }
      end,
      Demo.new("input[type=range] slider",
        %(ui.slider(@vol, 0.0..100.0, "Volume") { |v| @vol = v }),
        %(slider { selection_fill: accent }),
        %(<slider bind="vol" min="0" max="100"/>)) do |ui|
        ui.slider(@vol, 0.0..100.0, "Volume")
      end,
      Demo.new("textarea",
        %(ui.div(classes: "ta") { |d| d.textarea(@ta, rows: 4) }),
        %(ta textarea { color: #7ee787; font-family: monospace; rounding: 6 }),
        %(<div class="ta">\n  <textarea bind="text" rows="4"/>\n</div>)) do |ui|
        ui.div(classes: "ta") { |d| d.textarea(@ta, rows: 4) }
      end,
      Demo.new("progress 0.35",
        %(ui.progress(0.35)),
        %(progressbar { selection_fill: accent }),
        %(<progress bind="load"/>)) do |ui|
        ui.progress(0.35)
      end,
      Demo.new("progress with text",
        %(ui.progress(0.72, "72%")),
        %(progressbar { selection_fill: accent }),
        %(<progress bind="load" text="72%"/>)) do |ui|
        ui.progress(0.72, "72%")
      end,
      Demo.new("meter 0.7",
        %(ui.meter(0.7)),
        %(progressbar { selection_fill: green }),
        %(<progress bind="level"/>)) do |ui|
        ui.meter(0.7)
      end,
    ]
  end

  private def state_demos : Array(Demo)
    [
      Demo.new("p + title hover tooltip",
        %(ui.p("hover this line", title: "tooltip text")),
        %(/* tooltip is an attribute, not style */),
        %(<label text="hover this line" title="tooltip text"/>)) do |ui|
        ui.p("hover this line", title: "tooltip text")
      end,
      Demo.new("hidden",
        %(ui.p("visible")\nui.p("gone", hidden: true)\nui.p("visible again")),
        %(/* hidden is an attribute, not style */),
        %(<label text="visible"/>\n<label text="gone" if="false"/>\n<label text="visible again"/>)) do |ui|
        ui.p("visible")
        ui.p("gone", hidden: true)
        ui.p("visible again")
      end,
      Demo.new("classes + stylesheet rule",
        %(ctx.stylesheet.rule("card", StyleVars{\n  "background" => lime,\n})\nui.div(classes: "card") do |d|\n  d.button("scoped button")  # card.button\nend),
        %(card { background: #33d17a55 }\ncard button { background: #33d17a }),
        %(<card>\n  <button text="scoped button"/></card>)) do |ui|
        ui.div(classes: "lime") do |d|
          d.button("scoped button")
        end
      end,
      Demo.new("inline style: beats class (cascade)",
        %(# rule: btnx.button { text_color: blue }\nui.div(classes: "btnx") { |d|\n  d.button("Blue from rule")\n}\nui.add(Egui::Button.new("Red from inline")\n  .style { |s| s.text_color = red })),
        %(btnx button { text_color: #5a8ee0 }\n/* inline style: wins over the class rule\n   (inline > id > class > theme) */),
        %(<button class="btnx" text="Blue from rule"/>\n<button class="btnx" style="color: #ff0000" text="Red from inline"/>)) do |ui|
        ui.div(classes: "btnx") { |d| d.button("Blue from rule") }
        ui.add(Egui::Button.new("Red from inline")
          .style { |s| s.text_color = Egui::Color32.rgb(255, 0, 0) })
      end,
      Demo.new("data_testid",
        %(ui.p("hello", data_testid: "greeting")),
        %(/* recorded in ctx.data_testids for selectors */),
        %(<label text="hello" data-testid="greeting"/>)) do |ui|
        ui.p("hello", data_testid: "greeting")
        ui.small("testid recorded in ctx.data_testids[\"greeting\"]")
      end,
    ]
  end

  private def animation_demos : Array(Demo)
    [
      Demo.new("appear: fade",
        %(ui.box(appear: :fade) do |b|\n  b.p("fades in when first shown")\nend),
        %(fade-box {\n  appear: fade; /* named transition */\n}),
        %(<fade-box><label text="fades in when first shown"/></fade-box>)) do |ui|
        ui.box(appear: :fade, style_class: nil) { |b| b.p("fades in when first shown") }
      end,
      Demo.new("appear: drop",
        %(ui.box(appear: :drop) do |b|\n  b.p("drops in with a wobble")\nend),
        %(drop-box { appear: drop }),
        %(<drop-box><label text="drops in with a wobble"/></drop-box>)) do |ui|
        ui.box(appear: :drop) { |b| b.p("drops in with a wobble") }
      end,
      Demo.new("hover transition",
        %(ctx.stylesheet.rule("pill", StyleVars{\n  "background"      => base,\n  "transition"      => 180,\n})\nctx.stylesheet.rule("pill:hover", StyleVars{\n  "background"      => accent,\n})),
        %(pill { background: #33333c; transition: 180 }\npill:hover { background: #3584e4 }),
        %(<pill><label text="hover me"/></pill>)) do |ui|
        ui.div(classes: "pill", style: "padding: 8") { |d| d.p("hover me — background eases in 180ms") }
      end,
      Demo.new("animated progress",
        %(@load = 0.5 + 0.5 * Math.sin(\n  ctx_time_seconds)\nui.progress(@load) # value driven each frame),
        %(progressbar { selection_fill: accent }),
        %(<progress bind="load" live="true"/>)) do |ui|
        t = (Time.instant - @t0).total_seconds
        ui.progress(0.5 + 0.5 * Math.sin(t))
      end,
      Demo.new("spinner",
        %(ui.spinner),
        %(/* spinner visuals come from the theme */),
        %(<spinner/>)) do |ui|
        ui.spinner
      end,
    ]
  end

  private def media_demos : Array(Demo)
    [
      Demo.new("a link",
        %(ui.a("Docs", href: "https://example.com")\nui.a("https://example.com")  # bare url),
        %(a { hyperlink_color: #78aeed }),
        %(<link href="https://example.com" text="Docs"/>)) do |ui|
        ui.a("Docs", href: "https://example.com")
        ui.a("https://example.com")
      end,
      Demo.new("img natural size",
        %(ui.img("assets/icon.png")),
        %(img { rounding: 6 }),
        %(<image src="assets/icon.png"/>)) do |ui|
        ui.img("assets/icon.png")
      end,
      Demo.new("img width: 120 — aspect kept",
        %(ui.img("assets/icon.png", width: 120)\nui.img("assets/icon.png", height: 36)),
        %(img { width: 120; height: auto }),
        %(<image src="assets/icon.png" width="120"/>\n<image src="assets/icon.png" height="36"/>)) do |ui|
        ui.span do |s|
          s.img("assets/icon.png", width: 120)
          s.img("assets/icon.png", height: 36)
        end
      end,
      Demo.new("img + alt/title",
        %(ui.img("assets/icon.png", alt: "the app icon")),
        %(/* alt is the tooltip fallback */),
        %(<image src="assets/icon.png" alt="the app icon"/>)) do |ui|
        ui.img("assets/icon.png", alt: "the app icon")
      end,
    ]
  end

  # === canvas2d gradient demos (ops recorded once) ==================

  private def radial_canvas : Egui::Canvas2D
    @radial_canvas ||= begin
      c = Egui::Canvas2D.new("html_gallery_radial", 120, 120)
      # Outer r = 60√2 — the farthest corner, the CSS `circle` default
      # the HTML reference (`radial-gradient(circle, …)`) renders: the
      # ramp reaches the corners instead of saturating at the edge
      # midpoints (which reads as a circle on flat blue).
      r = 60.0 * Math.sqrt(2.0)
      g = c.create_radial_gradient(60.0, 60.0, 0.0, 60.0, 60.0, r)
      g.add_color_stop(0.0, Egui::Color32.rgb(255, 255, 255))
      g.add_color_stop(1.0, Egui::Color32.rgb(53, 132, 228))
      c.fill_style = g
      c.fill_rect(0.0, 0.0, 120.0, 120.0)
      c
    end
  end

  private def linear_canvas : Egui::Canvas2D
    @linear_canvas ||= begin
      c = Egui::Canvas2D.new("html_gallery_linear", 200, 36)
      g = c.create_linear_gradient(0.0, 0.0, 200.0, 0.0)
      g.add_color_stop(0.0, Egui::Color32.rgb(224, 27, 76))
      g.add_color_stop(0.5, Egui::Color32.rgb(245, 194, 17))
      g.add_color_stop(1.0, Egui::Color32.rgb(51, 209, 122))
      c.fill_style = g
      c.fill_rect(0.0, 0.0, 200.0, 36.0)
      c
    end
  end
end
