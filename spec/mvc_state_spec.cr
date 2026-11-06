# Стор приложения (plans/frontend-backend-split.md §7): dispatch =
# событие, чтение через StateView, запись физически только внутри
# обработчика действия (Writer), подписки на изменение, версии срезов,
# лог действий для инспектора.

require "spec"
require "../src/egui"

def mvc_state_fresh : Egui::Mvc::State
  Egui::Mvc::State.new
end

describe Egui::Mvc::State do
  it "writes inside a dispatched action and reads through StateView" do
    state = mvc_state_fresh
    state.on("posts/loaded") do |payload, w|
      w.set("posts", payload)
    end
    state.dispatch("posts/loaded",
      JSON::Any.new([JSON::Any.new("p1")] of JSON::Any))

    state["posts"].as_a.first.as_s.should eq "p1"
    state.version("posts").should eq 1
  end

  it "has no public setters — the only writer travels with dispatch" do
    state = mvc_state_fresh
    # Граница в типах: StateView (то, что дают фронту) умеет только
    # читать/подписываться; dispatch — метод State, не намерения.
    state.is_a?(Egui::Mvc::StateView).should be_true
    view : Egui::Mvc::StateView = state
    view["missing"] rescue nil # [] существует
    view.subscribe("k") { |_v| } # subscribe существует
    # (compile-time гарда: view.dispatch не существует — не скомпилировалось бы)
  end

  it "notifies subscribers on change, not on same-value writes" do
    state = mvc_state_fresh
    seen = [] of String
    state.subscribe("doc") { |v| seen << v.as_s }

    state.on("doc/set") { |p, w| w.set("doc", p) }
    state.dispatch("doc/set", JSON::Any.new("a"))
    state.dispatch("doc/set", JSON::Any.new("a")) # та же величина
    state.dispatch("doc/set", JSON::Any.new("b"))

    seen.should eq(["a", "b"])
    # Версия растёт только на ИЗМЕНЕНИЕ (та же величина — не событие):
    # прицельная перерисовка дедуплицируется бесплатно.
    state.version("doc").should eq 2
  end

  it "raises on missing keys in [], answers nil in []?" do
    state = mvc_state_fresh
    expect_raises(KeyError) { state["nope"] }
    state["nope"]?.should be_nil
  end

  it "logs dispatched actions (ring-capped) with payloads" do
    state = mvc_state_fresh
    state.on("noop") { |_p, _w| }
    300.times { |i| state.dispatch("noop", JSON::Any.new(i.to_i64)) }
    state.log.size.should eq(Egui::Mvc::State::LOG_CAP)
    state.log.last.should eq({"noop", JSON::Any.new(299_i64)})
    state.log.first[1].as_i.should eq(44) # 300 - 256
  end

  it "dispatches unknown actions as no-ops (event still logged)" do
    state = mvc_state_fresh
    state.dispatch("whatever")
    state.log.last.should eq({"whatever", Egui::Mvc::EMPTY_BODY})
  end

  it "deletes slices through the writer, notifying subscribers" do
    state = mvc_state_fresh
    state.on("seed") { |_p, w| w.set("k", JSON::Any.new("v")) }
    state.on("drop") { |_p, w| w.delete("k") }
    notifications = 0
    state.subscribe("k") { |_v| notifications += 1 }

    state.dispatch("seed")
    state.dispatch("drop")
    state["k"]?.should be_nil
    notifications.should eq 2 # set + delete
  end

  it "wakes the driver when present (jobs/ports write outside request delivery)" do
    # headless: current == nil — не падает; шпион-драйвер ловит wake.
    woke = 0
    spy = MvcStateSpec::DriverSpy.new(-> { woke += 1 })
    old = Egui::Driver::Base.current
    Egui::Driver::Base.current = spy
    begin
      state = mvc_state_fresh
      state.on("x") { |_p, w| w.set("x", JSON::Any.new(1_i64)) }
      state.dispatch("x")
      woke.should eq 1
    ensure
      Egui::Driver::Base.current = old
    end
  end
end

class MvcStateSpec::DriverSpy < Egui::Driver::Base
  def initialize(@wake_count : ->)
  end

  def run : Nil
  end

  def stop : Nil
  end

  def wake : Nil
    @wake_count.call
  end

  def gui_context? : Bool
    false
  end

  def run_on_main(& : ->) : Nil
  end
end
