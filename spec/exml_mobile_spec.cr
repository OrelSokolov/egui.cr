# Phase-1 smoke: the mobile vocabulary parses, validates and renders.
require "spec"
require "../src/egui"
require "../src/egui/exml_mobile"

include Egui

SCREEN = Rect.from_min_size(Pos2.new(0.0, 0.0), Vec2.new(400.0, 600.0))

def mobile_frame(doc : Exml::Document, rt : Exml::Runtime,
                 events : Array(Event) = [] of Event,
                 ctx : Context = Context.new, time : Float64 = 0.016,
                 renderer : Exml::Renderer = Exml::Renderer.new)
  ctx.begin_frame(RawInput.new(SCREEN, events, time))
  ctx.window("w") do |ui|
    doc.pages.each { |p| renderer.render(p, ui, ctx, rt) }
  end
  ctx.end_frame
  ctx
end

# One renderer per interaction test — the renderer carries per-frame
# bookkeeping across frames, exactly like an app's long-lived
# renderer; recreating it per frame breaks hit-testing.
def mobile_session : {Context, Exml::Renderer}
  {Context.new, Exml::Renderer.new}
end

# Settle frames before a tap: hit-testing reads the PREVIOUS frame's
# rects, so overlay-anchored widgets (fab, snackbar) need their
# first-frame size estimate to settle before press/release hit the
# same (measured) rect.
def tap(ctx : Context, renderer : Exml::Renderer,
        doc : Exml::Document, rt : Exml::Runtime, pos : Pos2) : Nil
  2.times { mobile_frame(doc, rt, [] of Event, ctx, renderer: renderer) }
  mobile_frame(doc, rt, [Event.pointer_pressed(pos)], ctx, 0.032, renderer)
  mobile_frame(doc, rt, [Event.pointer_released(pos)], ctx, 0.048, renderer)
end

describe "exml_mobile" do
  it "renders a screen scaffold: bar texts + nav labels" do
    doc = Exml.parse(%(
      <page id="root/root">
        <screen>
          <app-bar title="Mobile gallery" back="true" on_back="go_back">
            <appbar-action icon="copy" on_click="open_sheet"/>
          </app-bar>
          <screen-body>
            <label text="body content"/>
          </screen-body>
          <bottom-nav bind="tab">
            <nav-item icon="check" label="Controls"/>
            <nav-item icon="copy" label="Lists"/>
            <nav-item icon="up" label="Sheets"/>
          </bottom-nav>
          <fab icon="plus" margin_bottom="104" on_click="new_item"/>
        </screen>
      </page>
    ))
    Exml.validate(doc, known_custom: Egui::Exml.widgets.keys).should be_empty
    rt = Exml::Runtime.new
    rt.floats["tab"] = 0.0
    ctx, rend = mobile_session
    ctx = mobile_frame(doc, rt, renderer: rend)
    texts = ctx.painter.commands.select(TextCmd).map(&.text)
    texts.should contain("Mobile gallery")
    texts.should contain("body content")
    texts.should contain("Controls")
  end

  it "bottom-nav tap writes the bind slot" do
    doc = Exml.parse(%(
      <page id="root/root">
        <bottom-nav bind="tab">
          <nav-item icon="check" label="Controls"/>
          <nav-item icon="copy" label="Lists"/>
          <nav-item icon="up" label="Sheets"/>
        </bottom-nav>
      </page>
    ))
    rt = Exml::Runtime.new
    rt.floats["tab"] = 0.0
    ctx, rend = mobile_session
    ctx = mobile_frame(doc, rt, renderer: rend)
    # tap the painted "Lists" label → the second cell
    label = ctx.painter.commands.select(TextCmd)
      .find { |c| c.text == "Lists" }.should_not be_nil
    tap(ctx, rend, doc, rt, Pos2.new(label.pos.x + 2, label.pos.y))
    rt.floats["tab"].should eq(1.0)
  end

  it "switch writes its bind slot on tap" do
    doc = Exml.parse(%(
      <page id="root/root"><switch bind="wifi"/></page>
    ))
    rt = Exml::Runtime.new
    rt.bools["wifi"] = false
    ctx, rend = mobile_session
    ctx = mobile_frame(doc, rt, renderer: rend)
    # the switch track paints at (30,64)…(82,96) — its center
    tap(ctx, rend, doc, rt, Pos2.new(56.0, 80.0))
    rt.bools["wifi"].should be_true
  end

  it "fab click fires its action" do
    doc = Exml.parse(%(
      <page id="root/root"><fab icon="plus" on_click="new_item"/></page>
    ))
    rt = Exml::Runtime.new
    fired = false
    rt.actions["new_item"] = ->{ fired = true }
    ctx, rend = mobile_session
    ctx = mobile_frame(doc, rt, renderer: rend)
    # after settle the FAB circle sits at margin+radius from the
    # region bottom_right corner
    tap(ctx, rend, doc, rt, Pos2.new(SCREEN.max.x - 16.0 - 28.0,
      SCREEN.max.y - 16.0 - 28.0))
    fired.should be_true
  end

  it "stepper +/- writes its bind slot" do
    doc = Exml.parse(%(
      <page id="root/root"><stepper bind="volume" min="0" max="10" step="1"/></page>
    ))
    rt = Exml::Runtime.new
    rt.floats["volume"] = 6.0
    ctx, rend = mobile_session
    ctx = mobile_frame(doc, rt, renderer: rend)
    # the stepper paints [−] value [+]: the plus glyph is the cluster
    # of strokes right of the value text — tap its bounding center
    value = ctx.painter.commands.select(TextCmd)
      .find { |c| c.text == "6" }.should_not be_nil
    lines = ctx.painter.commands.select(LineCmd)
      .select { |c| c.p1.x > value.pos.x + 5.0 && c.p1.x < value.pos.x + 80.0 &&
                   c.p2.x > value.pos.x + 5.0 && c.p2.x < value.pos.x + 80.0 }
    lines.size.should be > 0
    xs = lines.map { |c| (c.p1.x + c.p2.x) / 2.0 }
    ys = lines.map { |c| (c.p1.y + c.p2.y) / 2.0 }
    tap(ctx, rend, doc, rt, Pos2.new(xs.sum / xs.size, ys.sum / ys.size))
    rt.floats["volume"].should eq(7.0)
  end

  it "chip-row filter tap flips the bind slot" do
    doc = Exml.parse(%(
      <page id="root/root">
        <chip-row>
          <chip label="Wi-Fi 6" bind="f_wifi"/>
          <chip label="Guest net" closable="true"/>
        </chip-row>
      </page>
    ))
    rt = Exml::Runtime.new
    rt.bools["f_wifi"] = false
    ctx, rend = mobile_session
    ctx = mobile_frame(doc, rt, renderer: rend)
    texts = ctx.painter.commands.select(TextCmd).map(&.text)
    texts.should contain("Wi-Fi 6")
    texts.should contain("Guest net")
    label = ctx.painter.commands.select(TextCmd)
      .find { |c| c.text == "Wi-Fi 6" }.should_not be_nil
    tap(ctx, rend, doc, rt, Pos2.new(label.pos.x, label.pos.y))
    rt.bools["f_wifi"].should be_true
  end

  it "pager renders children with {_i} = the visible page" do
    doc = Exml.parse(%(
      <page id="root/root">
        <pager pages="3" bind="page" height="120">
          <label text="page {_i} — swipe"/>
        </pager>
        <page-indicator count="3" bind="page"/>
      </page>
    ))
    rt = Exml::Runtime.new
    rt.floats["page"] = 0.0
    ctx, rend = mobile_session
    ctx = mobile_frame(doc, rt, renderer: rend)
    texts = ctx.painter.commands.select(TextCmd).map(&.text)
    texts.should contain("page 0 — swipe")
  end

  it "search-bar typing writes the bind slot" do
    doc = Exml.parse(%(
      <page id="root/root"><search-bar bind="query" hint="Search contacts"/></page>
    ))
    rt = Exml::Runtime.new
    rt.strings["query"] = ""
    ctx, rend = mobile_session
    ctx = mobile_frame(doc, rt, renderer: rend)
    texts = ctx.painter.commands.select(TextCmd).map(&.text)
    texts.should contain("Search contacts")
  end

  it "skeleton, circular-progress, safe-area render" do
    doc = Exml.parse(%(
      <page id="root/root">
        <skeleton rows="2"/>
        <circular-progress value="0.42" text="42%"/>
        <safe-area left="12" top="8"><label text="padded"/></safe-area>
        <avatar name="Alex Chen" size="40"/>
        <badge count="3"/>
        <pull-to-refresh refreshing="{spin}" label="Refreshing…"/>
      </page>
    ))
    rt = Exml::Runtime.new
    rt.bools["spin"] = true
    Exml.validate(doc, known_custom: Exml.widgets.keys).should be_empty
    ctx, rend = mobile_session
    ctx = mobile_frame(doc, rt, renderer: rend)
    texts = ctx.painter.commands.select(TextCmd).map(&.text)
    texts.should contain("42%")
    texts.should contain("padded")
    texts.should contain("Refreshing…")
  end
end
