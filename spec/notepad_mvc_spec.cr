# MVC-миграция notepad (plans/frontend-backend-split.md фаза 4):
# DocumentsController (CRUD + confirm-цепочка + quit-флоу) и
# SettingsController — режимом §9-1 (бэкенд в лоб); полный конвейер
# ввод → дебаунс-коммит → контроллер → конверт → кадр — режимом §9-3
# (capybara + настоящий in-process транспорт).

require "spec"
require "../src/egui"
require "../src/egui/capybara"
require "../examples/notepad_components/notepad_app"

def np_handle(method : String, path : String,
              body : String = "{}") : Egui::Mvc::Response
  NOTEPAD_ROUTES.handle(Egui::Mvc::Request.new(method, path,
    body: JSON::Any.new(JSON::PullParser.new(body))))
end

def np_doc_id(env : Egui::Mvc::Response, index : Int32 = 0) : Int64
  env.body["docs"].as_a[index]["id"].as_i64
end

# Quit-шпион: headless-дефолт — no-op, спека подменяет.
class NotepadSpec::QuitSpy < Egui::SystemPorts::Quit::Implementation
  property count = 0

  def quit : Nil
    @count += 1
  end
end

# --- Режим 1: бэкенд в лоб -------------------------------------------------

describe "NotepadBackend" do
  before_each { NotepadBackend.reset! }

  it "boots with the welcome document" do
    env = np_handle("GET", "/documents")
    env.status.should eq 200
    env.body["docs"].as_a.size.should eq 1
    env.body["docs"].as_a.first["title"].as_s.should eq "untitled"
    env.body["selected"].as_i.should eq 0
    env.body["status"].as_s.should eq "Ready."
    env.body["pending_close"].as_nil.should be_nil
    NotepadBackend.find(np_doc_id(env)).not_nil!.dirty?.should be_false
  end

  it "creates untitled tabs with sequential names" do
    np_handle("POST", "/documents")
    np_handle("POST", "/documents")
    docs = np_handle("GET", "/documents").body["docs"].as_a
    # Исходная нумерация сохранена байт-в-байт: счётчик стартует с 1,
    # имя «== 2 → untitled» — приветственный таб её не инкрементирует.
    docs.map(&.["title"].as_s).should eq(["untitled", "untitled 1", "untitled"])
  end

  it "commits edits (debounce lives on the frontend)" do
    id = np_doc_id(np_handle("GET", "/documents"))
    np_handle("PATCH", "/documents/#{id}", %({"text": "edited"}))
    doc = NotepadBackend.find(id).not_nil!
    doc.dirty?.should be_true
    np_handle("GET", "/documents").body["docs"].as_a.first["saved_text"].as_s
      .should eq(NotepadBackend::WELCOME) # истина файла не менялась
  end

  it "opens a startup file and drops the welcome tab" do
    File.write("/tmp/np_mvc_spec.txt", "file body\n")
    env = np_handle("POST", "/documents/open_paths",
      %({"paths": ["/tmp/np_mvc_spec.txt"]}))
    docs = env.body["docs"].as_a
    docs.size.should eq 1
    docs.first["title"].as_s.should eq "np_mvc_spec.txt"
    docs.first["saved_text"].as_s.should eq "file body\n"
    env.body["selected"].as_i.should eq 0
  end

  it "saves to the adopted path and clears dirty" do
    File.write("/tmp/np_mvc_spec2.txt", "original\n")
    env = np_handle("POST", "/documents/open_paths",
      %({"paths": ["/tmp/np_mvc_spec2.txt"]}))
    id = np_doc_id(env)
    np_handle("POST", "/documents/#{id}/save", %({"text": "changed\\n"}))
    File.read("/tmp/np_mvc_spec2.txt").should eq "changed\n"
    NotepadBackend.find(id).not_nil!.dirty?.should be_false
  end

  it "close of a dirty doc goes through pending_close; discard closes" do
    id = np_doc_id(np_handle("GET", "/documents"))
    env = np_handle("DELETE", "/documents/#{id}", %({"text": "dirty"}))
    env.body["pending_close"].should_not be_nil
    env.body["docs"].as_a.size.should eq 1 # ещё жив
    env = np_handle("POST", "/app/confirm",
      %({"choice": "discard", "id": #{id}, "text": "dirty"}))
    env.body["docs"].as_a.size.should eq 0
    env.body["pending_close"].as_nil.should be_nil
    env.body["status"].as_s.should eq "Closed: untitled"
  end

  it "close of a clean doc closes at once" do
    id = np_doc_id(np_handle("GET", "/documents"))
    env = np_handle("DELETE", "/documents/#{id}", %({"text": null}))
    env.body["docs"].as_a.size.should eq 0
    env.body["pending_close"].as_nil.should be_nil
  end

  it "quit flow: confirms each dirty doc, then quits once" do
    spy = NotepadSpec::QuitSpy.new
    old = Egui::SystemPorts::Quit.implementation
    Egui::SystemPorts::Quit.use(spy)
    begin
      np_handle("POST", "/documents") # untitled (dirty после правки)
      id2 = np_doc_id(np_handle("GET", "/documents"), 1)
      np_handle("PATCH", "/documents/#{id2}", %({"text": "work"}))

      env = np_handle("POST", "/app/quit")
      env.body["quitting"].as_bool.should be_true
      env.body["pending_close"].not_nil!["id"].as_i64.should eq id2
      spy.count.should eq 0

      env = np_handle("POST", "/app/confirm",
        %({"choice": "discard", "id": #{id2}, "text": "work"}))
      env.body["quitting"].as_bool.should be_false
      spy.count.should eq 1 # всё чисто — уходим
    ensure
      Egui::SystemPorts::Quit.use(old)
    end
  end

  it "cancel in the modal aborts the pending quit" do
    spy = NotepadSpec::QuitSpy.new
    old = Egui::SystemPorts::Quit.implementation
    Egui::SystemPorts::Quit.use(spy)
    begin
      id = np_doc_id(np_handle("GET", "/documents"))
      np_handle("PATCH", "/documents/#{id}", %({"text": "x"}))
      np_handle("POST", "/app/quit")
      env = np_handle("POST", "/app/confirm",
        %({"choice": "cancel", "id": #{id}, "text": "x"}))
      env.body["quitting"].as_bool.should be_false
      env.body["docs"].as_a.size.should eq 1 # таб остался
      spy.count.should eq 0
    ensure
      Egui::SystemPorts::Quit.use(old)
    end
  end

  it "settings round-trip without touching the disk (persist=false)" do
    resp = np_handle("PUT", "/settings", %({"theme": "Light", "persist": "false"}))
    resp.body["theme"].as_s.should eq "Light"
    np_handle("GET", "/settings").body["theme"].as_s.should eq "Light"
  end
end

# --- Режим 3: полный конвейер через транспорт ------------------------------

describe "NotepadApp (frontend + in-process transport)" do
  before_each do
    NotepadBackend.reset!
    # Глобальный капшен-хук — app-side состояние: сбросим и до, и после,
    # чтобы не течь в другие спеки (порядок примеров случайен).
    Egui::WindowFrame.caption!
  end

  after_each { Egui::WindowFrame.caption! }

  it "types, commits after the debounce, saves the tab title flow" do
    app = NotepadApp.new
    old = Egui::Mvc.transport
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(NOTEPAD_ROUTES)
    begin
      session = Egui::Capybara::Session.new(app)
      session.expect_text("Welcome to egui-cr notepad!")

      # Набор — эфемерное виджетное состояние; текст виден сразу.
      session.type("привет")
      session.expect_text("привет")
      # ...но в бэкенде ещё старая истина (коммит в дебаунсе).
      NotepadBackend.docs.first.text.should_not contain("привет")
      # ~0.33с симулированного времени — дебаунс истёк, PATCH уехал,
      # конверт вернулся между кадрами.
      session.idle(25)
      NotepadBackend.docs.first.text.should contain("привет")
    ensure
      Egui::Mvc.transport = old
    end
  end

  it "new tab via the caption + button, then close-with-confirm" do
    app = NotepadApp.new
    old = Egui::Mvc.transport
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(NOTEPAD_ROUTES)
    begin
      session = Egui::Capybara::Session.new(app)
      # Капшен с вкладками рисуется хром-прологом (как on_frame sokol /
      # скрипт скриншотов) — без него NewTab-кнопки нет на экране.
      session.before_update = ->(ctx : Egui::Context) {
        Egui::WindowFrame.show(ctx, "egui-cr — notepad",
          Egui::WindowFrame::Style::Windows)
      }
      session.idle(1)
      session.click("NewTab")
      session.idle(2)
      session.expect_text("untitled")
      NotepadBackend.docs.size.should eq 2
      NotepadBackend.selected.should eq 1

      # Правка делает новый таб dirty → закрытие идёт через модалку.
      session.type("draft")
      session.idle(25) # коммит уехал
      app.close_doc(app.docs[1])
      session.idle(2)
      session.expect_text("has unsaved changes")

      app.confirm("Don't save")
      session.idle(2)
      NotepadBackend.docs.size.should eq 1
      session.expect_text("Closed:")
    ensure
      Egui::Mvc.transport = old
    end
  end
end
