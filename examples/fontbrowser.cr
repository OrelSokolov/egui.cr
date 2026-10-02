# Font specimen browser — the fonts.google.com/noto/specimen layout:
# type a preview string, dial the size (slider + preset dropdown), pick a
# family from the searchable catalog, and every style file of that family
# renders the string in a row of its own. Families/files come from the
# system font scan (SystemPorts::Fonts — `name`-table reads only, no
# parsing at startup); each style file loads lazily through the
# deferred-font registry (`Sokol.register_deferred_font`): one shared
# glyph atlas, LRU eviction, a re-pick just re-parses the file.

require "../src/egui"
require "../src/egui/backend/sokol"
require "../src/egui/backend/crystalfonts"

class FontBrowserApp < Egui::App
  # Dropdown presets alongside the free slider (both write @size).
  SIZES = [12.0, 16.0, 20.0, 24.0, 32.0, 48.0, 64.0, 96.0]

  # Weight axis of a style file's filename token — the Google Fonts
  # specimen labels ("Thin 100" … "Black 900 Italic"). `slant` carries
  # the Italic/Oblique suffix for both label and row order (roman
  # before slanted of the same weight); `known: false` marks width/
  # shape tokens (Condensed, Mono…) with no weight slot — they keep
  # their prettified filename token and sort after the weight axis.
  record WeightCut, name : String, num : Int32, slant : String, known : Bool

  WEIGHTS = {
    "thin"       => {"Thin", 100},
    "extralight" => {"ExtraLight", 200},
    "ultralight" => {"ExtraLight", 200},
    "light"      => {"Light", 300},
    ""           => {"Regular", 400},
    "regular"    => {"Regular", 400},
    "book"       => {"Regular", 400},
    "r"          => {"Regular", 400},
    "roman"      => {"Regular", 400},
    "medium"     => {"Medium", 500},
    "semibold"   => {"SemiBold", 600},
    "demibold"   => {"SemiBold", 600},
    "bold"       => {"Bold", 700},
    "extrabold"  => {"ExtraBold", 800},
    "ultrabold"  => {"ExtraBold", 800},
    "black"      => {"Black", 900},
    "heavy"      => {"Black", 900},
  }

  # Glued short codes ("Ubuntu-R.ttf") → long form before weight lookup.
  LONG_TOKENS = {
    "r"  => "regular", "b" => "bold", "i" => "italic", "bi" => "bold italic",
    "bd" => "bold", "it" => "italic", "z" => "bold italic",
  }

  # Parse the post-dash filename token into a WeightCut:
  # "BoldItalic" → Bold 700 Italic, "Italic" → Regular 400 Italic,
  # "SemiBold" → SemiBold 600 roman, "ExtraCondensedBold" → unknown
  # (a width shape, not a weight slot).
  private def parse_cut(token : String) : WeightCut
    t = (LONG_TOKENS[token.downcase]? || token.downcase)
    slant = ""
    if t.ends_with?("italic")
      slant = "Italic"
      t = t.rpartition("italic").first
    elsif t.ends_with?("oblique")
      slant = "Oblique"
      t = t.rpartition("oblique").first
    end
    if (w = WEIGHTS[t]?)
      WeightCut.new(w[0], w[1], slant, true)
    else
      pretty = token.gsub(/(?<=[A-Za-z])(?=[A-Z])/, " ").capitalize
      WeightCut.new(pretty + (slant.empty? ? "" : " #{slant}"),
        10_000, slant, false)
    end
  end

  @text = "reactive"
  @size = 32.0
  @family = ""
  @dark = true
  @applied_theme : Bool? = nil
  # family name → every style file found for it (several dirs can merge).
  @families = {} of String => Array(String)
  # Active family's rows: style label → file path.
  @variants = [] of {String, String}
  @variants_family = ""
  # Style files already in the deferred registry ("fb:<path>" stacks).
  @registered = Set(String).new

  def initialize
    super
    scan_families
    names = @families.keys.sort
    # The reference specimen (the Google Fonts default): Noto Sans when
    # installed, otherwise the first family the scan found.
    @family = names.find { |n| n == "Noto Sans" } || names.first? || ""
  end

  def update(ctx : Egui::Context) : Nil
    # Theme swap on change only — re-assigning every frame would
    # rebuild the preset and drop any runtime style state.
    unless @applied_theme == @dark
      ctx.theme = @dark ? Egui::Theme.dark : Egui::Theme.light
      @applied_theme = @dark
    end

    ctx.central_panel do |ui|
      # Controls stay pinned above the scroll area (it takes only the
      # remaining height): preview text, size slider + preset dropdown,
      # searchable family picker.
      ui.horizontal do |row|
        row.label("Preview text")
        row.text_edit_singleline(@text, hint: "type to preview…") { |t| @text = t }
        # Theme swap — the whole UI repaints next frame (widgets
        # re-read the theme style every frame, see theme.cr).
        row.combo_box("fb_theme", @dark ? "Dark" : "Light", %w(Dark Light)) do |opt|
          @dark = opt == "Dark"
        end
      end
      ui.horizontal do |row|
        # A bare Slider stretches to the row's full remaining width
        # (Spacing#slider_width is only a MINIMUM) and would push the
        # dropdown and the family picker off-screen — box it instead.
        # Values snap to whole pixels (the label shows them raw).
        resp = row.add_sized(
          Egui::Vec2.new(240.0, row.style.spacing.interact_size.y),
          Egui::Slider.new(@size, 8.0..96.0, "Size"))
        if resp.changed? && (v = resp.widget_value)
          @size = v.round
        end
        row.combo_box("fb_size", "#{@size.to_i} px",
          SIZES.map { |s| "#{s.to_i} px" }) do |opt|
          @size = opt.rpartition(' ').first.to_f
        end
        row.label("Family")
        row.select_box("fb_family", @family, @families.keys.sort, 240.0) do |f|
          @family = f
        end
      end
      ui.separator

      rebuild_variants
      ui.scroll_area do |scroll|
        scroll.heading(@family)
        files = @families[@family]? || [] of String
        scroll.rich(Egui::RichText
          .new("#{files.size} style file#{files.size == 1 ? "" : "s"}")
          .small(scroll.style.font_size).weak(scroll.style.visuals))
        scroll.separator
        @variants.each do |label, path|
          stack = register_variant(path)
          scroll.rich(Egui::RichText.new(label)
            .small(scroll.style.font_size).weak(scroll.style.visuals))
          # Route just the specimen through this style's stack; the
          # chrome (labels, scrollbars) stays on the UI font.
          ctx.style.font_family = stack
          text = @text.empty? ? label : @text
          scroll.rich(Egui::RichText.new(text).size(@size))
          ctx.style.font_family = nil
          scroll.separator
        end
      end
    end
  end

  # ------------------------------------------------------------------
  # Family / style discovery

  # One-time scan of the system font dirs: family name (the SFNT
  # `name` table, not the filename) → every loadable .ttf of that
  # family. Noto-style files register each WEIGHT as its own legacy
  # family ("Noto Sans Thin", "Noto Sans Black"…) — #normalize_family
  # folds them back into the base ("Noto Sans") so the specimen shows
  # the Google Fonts weight axis, not 18 one-file families. Files
  # nobody picks never get parsed — loading is deferred to the rows
  # that actually render.
  private def scan_families : Nil
    Egui::SystemPorts::Fonts.font_dirs.each do |dir|
      next unless Dir.exists?(dir)
      Dir.glob("#{dir}/**/*") do |path|
        next unless path.downcase.ends_with?(".ttf") && File.file?(path)
        name = Egui::SystemPorts::Fonts.family_name(path)
        next unless name
        (@families[normalize_family(name)] ||= [] of String) << path
      end
    end
  end

  # Strip trailing style words off a legacy family name: weight and
  # slant suffixes ("Noto Sans Thin" → "Noto Sans"), width families
  # ("Noto Sans ExtraCondensed") stay their own family, like Google's.
  # At least one word always remains.
  STYLE_WORDS = %w[thin extralight ultralight light medium semibold
                   demibold bold extrabold ultrabold black heavy italic
                   oblique regular book roman]

  private def normalize_family(name : String) : String
    words = name.split
    while words.size > 1 && STYLE_WORDS.includes?(words.last.downcase)
      words.pop
    end
    words.join(" ")
  end

  # Refresh @variants when the picked family changed: style label →
  # file, the weight axis first (100→900, roman before slanted), the
  # width/shape cuts after it alphabetically.
  private def rebuild_variants : Nil
    return if @variants_family == @family
    @variants_family = @family
    rows = (@families[@family]? || [] of String).map do |path|
      cut = parse_cut(style_token(path))
      label = cut.known ?
        "#{cut.name} #{cut.num}#{cut.slant.empty? ? "" : " #{cut.slant}"}" :
        cut.name
      key = {cut.num, cut.slant.empty? ? 0 : 1, label}
      {key, label, path}
    end.sort_by(&.[0])
    @variants = rows.map { |_, label, path| {label, path} }
  end

  # The style segment of a font filename: after the last '-'
  # ("NotoSans-BoldItalic.ttf" → "BoldItalic", "Ubuntu-R.ttf" → "R");
  # no dash at all → "" (the whole base is the family name).
  private def style_token(path : String) : String
    base = File.basename(path, ".ttf")
    base.includes?('-') ? base.rpartition('-').last : ""
  end

  # Push the file into the deferred registry once ("fb:<path>" — unique
  # per file, can't collide with the catalog's family names); the stack
  # itself parses on the row's first draw.
  private def register_variant(path : String) : String
    stack = "fb:#{path}"
    unless @registered.includes?(path)
      @registered << path
      Egui::Backend::Sokol.register_deferred_font(stack, [path])
    end
    stack
  end
end

Egui::Backend::Sokol.run(FontBrowserApp.new, title: "egui-cr — fonts",
  width: 1024, height: 800, inspector: :hidden)
