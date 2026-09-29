# Compile-time SVG icon embedding, organized as providers.
#
# A provider is a named folder under `icons/` holding one icon set
# plus its LICENSE (`icons/lucide` — Lucide, ISC license, ~1850
# stroke icons on a 24×24 grid; `icons/bootstrap` — Bootstrap Icons,
# MIT license, ~2000 fill icons on a 16×16 grid).
# `Icon.from_file(:lucide, :save)`
# resolves `icons/lucide/save.svg` AT COMPILE TIME through the macro
# `read_file`, so only the icons actually referenced are embedded in
# the binary — the provider folder on disk can hold thousands. A
# typo in the provider or icon name is a compile error, not a
# runtime surprise. Icon names map to file names with `_` → `-`
# (`:arrow_up` → arrow-up.svg).
#
# `tint:` resolves the set's `currentColor` (black by default); the
# parsed shapes are cached per (provider, name, tint), so a
# `from_file` call in a per-frame widget path parses each icon once
# per color, not once per frame.

module Egui
  module Icon
    @@cache = {} of String => Svg

    # The runtime half of `from_file`: memoize the parsed icon per
    # (provider, name, tint). A miss (fresh parse) happens once per
    # key for the life of the process.
    def self.cached(provider : String, name : String, tint : Color32?,
                    source : String) : Svg
      Egui::Bench.span("Icon.cached") do
        key = tint ? "#{provider}/#{name}/#{tint.not_nil!.r}/#{tint.not_nil!.g}/#{tint.not_nil!.b}"
                    : "#{provider}/#{name}/-"
        @@cache[key] ||= Svg.new(source, Vec2.new(24.0, 24.0),
          tint || Color32.rgb(0, 0, 0))
      end
    end

    # Embed `icons/<provider>/<name>.svg` at the call site. The
    # provider is always explicit — there is no default set.
    macro from_file(provider, name, tint = nil)
      {% p = provider.id.stringify %}
      {% n = name.id.stringify.gsub(/_/, "-") %}
      {% file = __DIR__ + "/../../icons/" + p + "/" + n + ".svg" %}
      {% source = read_file(file) %}
      Egui::Icon.cached({{ p }}, {{ n }}, {{ tint }}, {{ source }})
    end
  end
end
