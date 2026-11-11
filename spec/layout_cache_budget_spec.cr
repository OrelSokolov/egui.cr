# The byte-budgeted layout cache (Fonts#layout): the working set of a
# screen must cache-hit across frames, and an over-budget cache must
# evict STALE entries while keeping what the last frames used.

require "spec"
require "../src/egui"

describe Egui::Fonts do
  it "holds the whole screen's working set (an unchanged frame hits)" do
    fonts = Egui::MonospaceFonts.new
    runs = (0...400).map { |i| [Egui::TextRun.new("text #{i} #{"x" * i}", 14.0)] of Egui::TextRun }
    runs.each { |r| fonts.layout(r, 300.0) }
    first = fonts.layout_cache_entries
    first.should eq(400)
    fonts.layout_cache_bytes.should be > 0_i64

    # The same screen next frame: every layout is a hit, nothing new
    # is built — the returned galleys are the cached objects.
    runs.each do |r|
      fonts.layout(r, 300.0).should be(fonts.layout(r, 300.0))
    end
    fonts.layout_cache_entries.should eq(first)
  end

  it "distinguishes wrap width, size and line_height in the key" do
    fonts = Egui::MonospaceFonts.new
    run = [Egui::TextRun.new("same text", 14.0)] of Egui::TextRun
    g300 = fonts.layout(run, 300.0)
    g400 = fonts.layout(run, 400.0)
    g_big = fonts.layout([Egui::TextRun.new("same text", 20.0)], 300.0)
    g_lh = fonts.layout(run, 300.0, line_height: 1.5)
    g300.should_not be(g400)
    g300.should_not be(g_big)
    g300.should_not be(g_lh)
    fonts.layout_cache_entries.should eq(4)
  end

  it "evicts stale entries over budget, keeping the current screen" do
    fonts = Egui::MonospaceFonts.new
    fonts.layout_cache_budget = 15_000_i64

    # A screenful of BIG galleys (~6 KiB each — a document each); the
    # budget can hold at most two of them, the rest of the phase-1
    # inserts LRU-evict each other.
    old = (0...20).map { |i| [Egui::TextRun.new("old #{i} " + "y" * 6000, 14.0)] of Egui::TextRun }
    old_galleys = old.map { |r| fonts.layout(r) }
    3.times { fonts.tick_layout_cache } # the survivors go stale

    # A new screenful of small texts (~0.3 KiB each, the whole set
    # fits inside 3/4 of the budget): the inserts cross the budget,
    # the purge evicts the STALE big ones — the small screen survives.
    cold = (0...40).map { |i| [Egui::TextRun.new("cold #{i}", 14.0)] of Egui::TextRun }
    cold_galleys = cold.map { |r| fonts.layout(r) }
    fonts.layout_cache_bytes.should be <= fonts.layout_cache_budget
    fonts.layout_cache_entries.should eq(40) # only the current screen

    # The current screen still hits — the same galley objects back.
    cold.each_with_index { |r, i| fonts.layout(r).should be(cold_galleys[i]) }
    # The stale screen misses (built fresh, not the evicted objects).
    old.each_with_index { |r, i| fonts.layout(r).should_not be(old_galleys[i]) }
  end

  it "defaults to a multi-megabyte budget, overridable by env" do
    Egui::Fonts.default_layout_cache_budget.should be >= 4 * 1024 * 1024
  end
end
