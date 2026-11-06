# MVC-миграция terminal (plans/frontend-backend-split.md фаза 4):
# контрольная плоскость сессий через контроллер, структурные слайсы —
# через State (подписка = repaint), порт-объект сессии — на полке
# репозитория, TermView держит его по ссылке (§4.1). Сессии — фейк
# (нативная PTY требует шим; спеки headless).

require "spec"
require "../src/egui"
require "../examples/terminal_components/terminal_app"

# Фейк Terminal::Backend: эмулятор настоящий, PTY нет.
class TerminalMvcSpec::FakeSession < Egui::Terminal::Backend
  property killed = false
  getter term : Egui::Terminal::Terminal
  @written = Bytes.empty

  def initialize(@alive_for_ever : Bool = true)
    @term = Egui::Terminal::Terminal.new(10, 4, 100)
  end

  def pump : Bool
    false
  end

  def write(bytes : Bytes) : Nil
    @written += bytes
  end

  def written : String
    String.new(@written)
  end

  def resize(cols : Int32, rows : Int32) : Nil
  end

  def alive? : Bool
    !@killed
  end

  def exit_code : Int32?
    @killed ? 0 : nil
  end

  def close : Nil
    @killed = true
  end
end

def term_mvc_handle(method : String, path : String,
                    body : String = "{}") : Egui::Mvc::Response
  TERMINAL_ROUTES.handle(Egui::Mvc::Request.new(method, path,
    body: JSON::Any.new(JSON::PullParser.new(body))))
end

def term_mvc_setup(last_alive : Bool = true) : Nil
  old_state = Egui::Mvc.state
  Egui::Mvc.state = Egui::Mvc::State.new
  Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(TERMINAL_ROUTES)
  # Репо — класс-состояние: между тестами сбрасываем целиком (он же
  # перерегистрирует слайс-обработчики на свежем сторе).
  TerminalRepo.reset!
  # Явный тип возврата: Proc ковариантностью не обладает — без
  # аннотации выводится Proc(… -> FakeSession).
  TerminalRepo.session_factory = ->(cwd : String?, wake : Proc(Nil)) : Egui::Terminal::Backend do
    TerminalMvcSpec::FakeSession.new
  end
  TerminalMvcSpec.last_state = old_state
end

def term_mvc_teardown : Nil
  if (old = TerminalMvcSpec.last_state)
    Egui::Mvc.state = old
    TerminalMvcSpec.last_state = nil
  end
end


describe "TerminalRepo (backend + state slices)" do
  before_each { term_mvc_setup }
  after_each { term_mvc_teardown }

  it "opens sessions through the controller and syncs the tabs slice" do
    TerminalMvcSpec::FakeSession # (класс загружен)
    id = TerminalRepo.open!
    TerminalRepo.open!
    Egui::Mvc.state["terminal/tabs"].as_a.map(&.as_i64).should eq([id, id + 1])
    Egui::Mvc.state["terminal/selected"].as_i.should eq 1
    # Порт-объект на полке — тем же объектом владеет виджет.
    TerminalRepo.session(id).should be_a(Egui::Terminal::Backend)
  end

  it "pick updates the selected slice" do
    TerminalRepo.open!
    TerminalRepo.open!
    term_mvc_handle("POST", "/sessions/pick", %({"index": 0}))
    Egui::Mvc.state["terminal/selected"].as_i.should eq 0
  end

  it "close drops the session from the shelf and the slice" do
    id = TerminalRepo.open!
    term_mvc_handle("DELETE", "/sessions/#{id}")
    Egui::Mvc.state["terminal/tabs"].as_a.should be_empty
    TerminalRepo.session(id).should be_nil
  end

  it "reaping dead sessions quits the app with the last tab (backend guard)" do
    spy = TerminalMvcSpec::QuitSpy.new
    old = Egui::SystemPorts::Quit.implementation
    Egui::SystemPorts::Quit.use(spy)
    begin
      TerminalRepo.open!
      id = Egui::Mvc.state["terminal/tabs"].as_a.first.as_i64
      (session = TerminalRepo.session(id)).should be_a(TerminalMvcSpec::FakeSession)
      session.as(TerminalMvcSpec::FakeSession).killed = true
      TerminalRepo.reap!
      Egui::Mvc.state["terminal/tabs"].as_a.should be_empty
      spy.count.should eq 1
    ensure
      Egui::SystemPorts::Quit.use(old)
    end
  end

  it "paste wraps the clipboard text with bracketed paste into the session" do
    id = TerminalRepo.open!
    session = TerminalRepo.session(id).as(TerminalMvcSpec::FakeSession)
    Egui::SystemPorts::Clipboard.text = "hello"
    term_mvc_handle("POST", "/sessions/#{id}/paste")
    session.written.should contain("hello")
  end

  it "profile updates flow through the profiles slice" do
    TerminalMvcSpec::FakeSession
    TerminalRepo.sync_profiles!
    Egui::Mvc.state["terminal/profiles"]["opacity"].as_f.should be > 0.0
    term_mvc_handle("PUT", "/profiles", %({"opacity": 0.55, "blink": true}))
    Egui::Mvc.state["terminal/profiles"]["opacity"].as_f.should eq 0.55
    Egui::Mvc.state["terminal/profiles"]["blink"].as_bool.should be_true
  end

  it "profile CRUD through routes (add copies active, delete keeps one)" do
    term_mvc_handle("POST", "/profiles", %({"name": "dim"}))
    Egui::Mvc.state["terminal/profiles"]["names"].as_a.map(&.as_s)
      .should contain("dim")
    term_mvc_handle("POST", "/profiles/pick", %({"name": "dim"}))
    Egui::Mvc.state["terminal/profiles"]["active"].as_s.should eq "dim"
    term_mvc_handle("DELETE", "/profiles")
    Egui::Mvc.state["terminal/profiles"]["names"].as_a.size.should eq 1
  end
end

describe "TerminalApp (state → frontend cache)" do
  it "subscribes the app's caches to the store slices" do
    term_mvc_setup
    old_transport = Egui::Mvc.transport
    begin
      app = TerminalApp.new
      TerminalRepo.open!
      # Открытие разъехалось через dispatch → подписка обновила кэш
      # фронта (без единого кадра — чистая реакция стора).
      app.tab_ids.should eq Egui::Mvc.state["terminal/tabs"].as_a.map(&.as_i64)
      app.profile_active.should_not be_empty
    ensure
      term_mvc_teardown
      Egui::Mvc.transport = old_transport
    end
  end
end

class TerminalMvcSpec::QuitSpy < Egui::SystemPorts::Quit::Implementation
  property count = 0

  def quit : Nil
    @count += 1
  end
end

module TerminalMvcSpec
  class_property last_state : Egui::Mvc::State? = nil
end

