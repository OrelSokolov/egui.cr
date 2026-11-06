# MVC-миграция tableview (plans/frontend-backend-split.md фаза 4,
# plans/mvc-examples-analysis.md §tableview): PackagesController с
# `resources "packages"`, ListStore — одноразовый кэш view-модель.
# Режим §9-1: бэкенд в лоб через роутер; режим §9-3: полный конвейер
# клик → контроллер → ответ → кадр через настоящий in-process
# транспорт в capybara-харнессе.

require "spec"
require "../src/egui"
require "../src/egui/capybara"
require "../examples/tableview_components/pkg_app"

def tv_mvc_handle(method : String, path : String,
                  body : String = "{}") : Egui::Mvc::Response
  # Прямой вызов конверта (без JSON-строки) — но контроллер ждёт
  # JSON::Any-тело; парсим строку ради спеки.
  body_any = JSON::Any.new(JSON::PullParser.new(body))
  PKG_ROUTES.handle(Egui::Mvc::Request.new(method, path, body: body_any))
end

# --- Режим 1: бэкенд в лоб -----------------------------------------------

describe "PackagesController (backend)" do
  before_each { PkgRepo.reset! }

  it "seeds deterministically and indexes all packages" do
    resp = tv_mvc_handle("GET", "/packages")
    resp.status.should eq 200
    resp.body["total"].as_i.should eq PkgRepo::NAMES.size
    rows = resp.body["rows"].as_a
    rows.size.should eq PkgRepo::NAMES.size
    r0 = rows.first
    r0.as_a.size.should eq 6 # status/name/installed/available/size/section
  end

  it "filters by the search query server-side" do
    resp = tv_mvc_handle("GET", "/packages?search=GCC")
    resp.body["search"].as_s.should eq "gcc"
    names = resp.body["rows"].as_a.map { |r| r.as_a[1].as_s }
    names.size.should eq 1 # только gcc-Nx из пула
    names.first.should start_with("gcc-")
  end

  it "toggles install/remove with the version business rule" do
    resp = tv_mvc_handle("GET", "/packages")
    row = resp.body["rows"].as_a.find { |r|
      r.as_a[0].as_s == "not installed"
    }.not_nil!.as_a
    name = row[1].as_s
    available = row[3].as_s

    installed = tv_mvc_handle("PATCH", "/packages/#{name}",
      %({"action": "toggle"}))
    installed.body["message"].as_s.should eq "Installed #{name}"
    pkg = PkgRepo.find(name).not_nil!
    pkg.status.should eq "installed"
    pkg.installed.should eq available # install берёт available-версию

    removed = tv_mvc_handle("PATCH", "/packages/#{name}",
      %({"action": "toggle"}))
    removed.body["message"].as_s.should eq "Removed #{name}"
    pkg.installed.should eq "" # remove чистит installed
  end

  it "404s unknown packages" do
    tv_mvc_handle("PATCH", "/packages/no-such-pkg-9z",
      %({"action": "toggle"})).status.should eq 404
  end

  it "bulk-applies an action over a name selection" do
    names = PkgRepo.packages.sample(3, Random.new(1)).map(&.name)
    body = %({"action": "remove", "names": #{names.to_json}})
    resp = tv_mvc_handle("POST", "/packages/bulk", body)
    resp.body["message"].as_s.should eq "3 packages updated"
    names.each do |n|
      pkg = PkgRepo.find(n).not_nil!
      pkg.status.should eq "not installed"
      pkg.installed.should eq ""
    end
  end
end

# --- Режим 3: полный конвейер через транспорт ----------------------------

describe "PkgApp (frontend + in-process transport)" do
  before_each { PkgRepo.reset! }

  it "renders the index response as table rows" do
    app = PkgApp.new
    old = Egui::Mvc.transport
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(PKG_ROUTES)
    begin
      session = Egui::Capybara::Session.new(app)
      app.store.row_count.should eq PkgRepo::NAMES.size
      session.expect_text("packages")
    ensure
      Egui::Mvc.transport = old
    end
  end

  it "narrows the table from a search-field request round trip" do
    app = PkgApp.new
    old = Egui::Mvc.transport
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(PKG_ROUTES)
    begin
      session = Egui::Capybara::Session.new(app)
      app.store.row_count.should eq PkgRepo::NAMES.size
      session.fill "TextEdit", "gcc" # единственный TextEdit — поиск
      session.idle(3)
      app.store.row_count.should eq 1
      app.store.get_string(0, PkgApp::NAME).should start_with("gcc-")
    ensure
      Egui::Mvc.transport = old
    end
  end

  it "double-click sends the toggle request and shows the message" do
    app = PkgApp.new
    old = Egui::Mvc.transport
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(PKG_ROUTES)
    begin
      session = Egui::Capybara::Session.new(app)
      row = (0...app.store.row_count).find { |r|
        app.store.get_string(r, PkgApp::STATUS) == "not installed"
      }.not_nil!
      name = app.store.get_string(row, PkgApp::NAME)

      # Строки таблицы — не интерактивные виджеты инспектора: двойной
      # клик — сырыми press/release-кадрами по позиции текста.
      pos = session.commands.select(Egui::TextCmd)
        .find { |c| c.text == name }.not_nil!.pos
      2.times do
        session.step([Egui::Event.pointer_moved(pos),
          Egui::Event.pointer_pressed(pos, :primary)])
        session.step([Egui::Event.pointer_released(pos, :primary)])
      end
      session.idle(3)

      PkgRepo.find(name).not_nil!.status.should eq "installed"
      session.expect_text("Installed #{name}")
    ensure
      Egui::Mvc.transport = old
    end
  end
end
