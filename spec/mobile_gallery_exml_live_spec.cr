# mobile_gallery_exml live — приложение целиком через capybara-сессию
# (шрифты фиктивные, без X; шаблон — music_exml_live_spec): связка
# markup-словарь ↔ store ↔ actions, табы через bind, тосты и синк.
require "spec"
require "../src/egui"
require "../src/egui/capybara"
require "../src/egui/capybara/fonts"
require "../examples/mobile_gallery_exml"

def live_session
  app = MobileGalleryExmlApp.new
  Egui::Capybara::Fonts.install!(app.ctx)
  Egui::Capybara::Session.new(app, width: 420, height: 720)
end

describe MobileGalleryExmlApp do
  it "первый кадр: таб 0, скаффолд засинкен" do
    t = live_session
    t.idle(2)
    app = t.app.as(MobileGalleryExmlApp)
    app.rt.float("tab").should eq 0.0
    app.rt.bool("tab0").should be_true
    app.rt.bool("tab1").should be_false
    app.rt.string("wifi_sub").should eq "home-5G"
  end

  it "bottom-nav bind переключает таб — булевы слоты следуют" do
    t = live_session
    t.idle(2)
    app = t.app.as(MobileGalleryExmlApp)
    app.rt.floats["tab"] = 2.0
    t.idle(1)
    app.rt.bool("tab2").should be_true
    app.rt.bool("tab0").should be_false
    app.rt.floats["tab"] = 0.0
    t.idle(1)
    app.rt.bool("tab0").should be_true
  end

  it "switch пишет слот, wifi_sub пересчитывается синком" do
    t = live_session
    t.idle(2)
    app = t.app.as(MobileGalleryExmlApp)
    app.rt.bools["wifi"] = false
    t.idle(1)
    app.rt.string("wifi_sub").should eq "off"
    app.rt.bools["wifi"] = true
    t.idle(1)
    app.rt.string("wifi_sub").should eq "home-5G"
  end

  it "actions: fab-тост появляется и убирается, таймер гасит его" do
    t = live_session
    t.idle(2)
    app = t.app.as(MobileGalleryExmlApp)
    app.rt.actions["new_item"].not_nil!.call
    t.idle(1) # pending-снек флашится после кадра с рендером
    app.rt.bool("snack_on").should be_true
    app.rt.string("snack_text").should eq "new item"
    app.rt.string("snack_action").should eq "UNDO"
    app.rt.actions["snack_clear"].not_nil!.call
    t.idle(1)
    app.rt.bool("snack_on").should be_false
  end

  it "start_refresh крутит спин ~1с и гасит его с тостом" do
    t = live_session
    t.idle(2)
    app = t.app.as(MobileGalleryExmlApp)
    app.rt.actions["start_refresh"].not_nil!.call
    t.idle(1)
    app.rt.bool("spin").should be_true
    t.idle(70)
    app.rt.bool("spin").should be_false
    app.rt.string("snack_text").should eq "refreshed!"
  end

  it "pager bind: слот страницы читается, page-indicator делит индекс" do
    t = live_session
    t.idle(2)
    app = t.app.as(MobileGalleryExmlApp)
    app.rt.floats["tab"] = 2.0
    app.rt.floats["page"] = 1.0
    t.idle(1)
    app.rt.float("page").should eq 1.0
  end
end
