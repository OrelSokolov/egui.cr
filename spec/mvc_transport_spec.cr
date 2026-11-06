# MVC-транспорт (plans/frontend-backend-split.md §5, тест-режим №3 из
# §9): InProcessTransport возит Request/Response по ссылке, обработка
# — в рабочем файбере, on_done доставляется МЕЖДУ кадрами (pump_pass),
# ошибки превращаются в 5xx, никогда не блокирует и не райзит.

require "spec"
require "../src/egui"

def mvc_pump_until_done(limit : Int32 = 50) : Nil
  limit.times do
    Egui::Mvc.pump_pass
    break unless Egui::Mvc.pending?
  end
end

class MvcTransportSpec::App < Egui::App
  property clicks : Int32 = 0

  def update(ctx) : Nil
  end
end

describe Egui::Mvc::InProcessTransport do
  it "never calls on_done synchronously — only after a scheduler pass" do
    router = Egui::Mvc::Router.new
    router.get "/hello" { "world" }
    transport = Egui::Mvc::InProcessTransport.new(router)

    got = [] of Egui::Mvc::Response
    transport.call(Egui::Mvc::Request.new("GET", "/hello")) { |r| got << r }
    # The request went into a worker fiber; nothing has delivered yet.
    got.should be_empty
    Egui::Mvc.pending?.should be_true

    mvc_pump_until_done
    Egui::Mvc.pending?.should be_false
    got.size.should eq 1
    got.first.body.as_s.should eq "world"
    # Счётчик глобальный, спеки одного прогона делят процесс (порядок
    # примеров случайен) — наш запрос учтён, и повторное чтение пусто.
    Egui::Mvc.take_delivered.should be >= 1
    Egui::Mvc.take_delivered.should eq 0 # consumed
  end

  it "carries query, params and body; 404s unknown routes" do
    router = Egui::Mvc::Router.new
    router.post "/echo/:kind" do |req|
      {"kind"    => req.params["kind"],
       "q"       => req.query["q"],
       "payload" => req.body["n"].as_i}
    end
    transport = Egui::Mvc::InProcessTransport.new(router)

    got = [] of Egui::Mvc::Response
    transport.call(Egui::Mvc::Request.new("POST", "/echo/x?q=1",
      body: JSON::Any.new({"n" => JSON::Any.new(7_i64)}))) { |r| got << r }
    transport.call(Egui::Mvc::Request.new("GET", "/missing")) { |r| got << r }
    mvc_pump_until_done

    got[0].ok?.should be_true
    got[0].body["kind"].as_s.should eq "x"
    got[0].body["q"].as_s.should eq "1"
    got[0].body["payload"].as_i.should eq 7
    got[1].status.should eq 404
  end

  it "turns handler exceptions into 500 responses (never raises)" do
    router = Egui::Mvc::Router.new
    router.get "/boom" { raise "kaput" }
    transport = Egui::Mvc::InProcessTransport.new(router)

    got = [] of Egui::Mvc::Response
    transport.call(Egui::Mvc::Request.new("GET", "/boom")) { |r| got << r }
    mvc_pump_until_done
    got.first.status.should eq 500
    got.first.body["error"].as_s.should eq "kaput"
  end
end

describe "Egui.request sugar" do
  it "serializes named args into the JSON body and routes through the default transport" do
    router = Egui::Mvc::Router.new
    router.post "/posts" do |req|
      {"title" => req.body["title"].as_s, "tags" => req.body["tags"].as_a.size}
    end
    old = Egui::Mvc.transport
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(router)
    begin
      got = [] of Egui::Mvc::Response
      Egui.request "POST", "/posts", title: "Привет", tags: ["a", "b"] do |resp|
        got << resp
      end
      mvc_pump_until_done
      got.first.ok?.should be_true
      got.first.body["title"].as_s.should eq "Привет"
      got.first.body["tags"].as_i.should eq 2
    ensure
      Egui::Mvc.transport = old
    end
  end

  it "accepts a ready JSON::Any body" do
    router = Egui::Mvc::Router.new
    router.post "/doc" { |req| req.body["op"].as_s }
    old = Egui::Mvc.transport
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(router)
    begin
      got = [] of Egui::Mvc::Response
      Egui.request "POST", "/doc",
        body: JSON::Any.new({"op" => JSON::Any.new("insert")}) do |resp|
        got << resp
      end
      mvc_pump_until_done
      got.first.body.as_s.should eq "insert"
    ensure
      Egui::Mvc.transport = old
    end
  end
end

describe "Capybara frame pump" do
  it "delivers request callbacks between frames, never mid-frame" do
    router = Egui::Mvc::Router.new
    router.get "/count" { {"n" => 1_i64} }
    old = Egui::Mvc.transport
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(router)
    begin
      app = MvcTransportSpec::App.new
      Egui.request "GET", "/count" do |resp|
        # Runs in the worker fiber — only advanceable through the
        # session's between-frames pump, never inside app.update.
        app.clicks += resp.body["n"].as_i
      end
      session = Egui::Capybara::Session.new(app, settle_frames: 0)
      app.clicks.should eq 0
      session.idle(2)
      app.clicks.should eq 1
    ensure
      Egui::Mvc.transport = old
    end
  end
end
