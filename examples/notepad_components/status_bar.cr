require "../../src/egui"

# StatusBar — the document stats line (chars/lines) as a component:
# markup in assets/components/status_bar.exml, the derivation here.
# The app publishes the raw buffer (`doc_text`) and the flags; the
# component computes the counts — memoized on buffer identity, the
# same trick the plain notepad's Doc#stats used (a multi-megabyte
# buffer must not re-count newlines every frame).

class StatusBar < Egui::Exml::Component
  exml "assets/components/status_bar.exml"

  @stats_text : String? = nil
  @chars = 0
  @lines = 1

  def update(ctx : Egui::Context, rt : Egui::Exml::Runtime) : Nil
    text = rt.string("doc_text")
    unless @stats_text.same?(text)
      @stats_text = text
      @chars = text.size
      @lines = text.count('\n') + 1
      rt.strings["chars"] = @chars.to_s
      rt.strings["lines"] = @lines.to_s
    end
  end
end
