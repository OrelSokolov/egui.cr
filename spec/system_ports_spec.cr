require "spec"
require "../src/egui"

# Headless system-port specs. Ports that touch the real desktop (file
# dialogs, MessageBox, notifications, OpenUrl) are NOT invoked here —
# they would open real windows / spawn apps on a desktop machine. The
# injectable ports are exercised through their defaults and recorders.
# AsyncDialogs IS exercised, with fake work procs instead of real
# dialog processes (same fiber path, no desktop needed).

class QuitRecorder < Egui::SystemPorts::Quit::Implementation
  getter count = 0

  def quit : Nil
    @count += 1
  end
end

class WindowRecorder < Egui::SystemPorts::Window::Implementation
  getter title = ""
  getter size = {0, 0}
  getter icon = Bytes.new(0)
  getter icon_size = {0, 0}

  def set_title(title : String) : Nil
    @title = title
  end

  def set_size(width : Int32, height : Int32) : Nil
    @size = {width, height}
  end

  def set_icon(rgba : Bytes, width : Int32, height : Int32) : Nil
    @icon = rgba
    @icon_size = {width, height}
  end
end

describe Egui::SystemPorts do
  it "Quit delegates to the installed implementation" do
    recorder = QuitRecorder.new
    Egui::SystemPorts::Quit.use(recorder)
    Egui::SystemPorts::Quit.quit!
    recorder.count.should eq(1)
  ensure
    Egui::SystemPorts::Quit.use(Egui::SystemPorts::Quit::Implementation.new)
  end

  it "default Quit implementation is a headless no-op" do
    Egui::SystemPorts::Quit.quit! # must not raise
  end

  it "Clipboard default implementation round-trips in memory" do
    Egui::SystemPorts::Clipboard.text = "hello"
    Egui::SystemPorts::Clipboard.text.should eq("hello")
  ensure
    Egui::SystemPorts::Clipboard.use(Egui::SystemPorts::Clipboard::Implementation.new)
  end

  it "Window delegates to the installed implementation" do
    recorder = WindowRecorder.new
    Egui::SystemPorts::Window.use(recorder)
    Egui::SystemPorts::Window.set_title("demo")
    Egui::SystemPorts::Window.set_size(640, 480)
    px = Bytes[1, 2, 3, 255]
    Egui::SystemPorts::Window.set_icon(px, 1, 1)
    recorder.title.should eq("demo")
    recorder.size.should eq({640, 480})
    recorder.icon.should eq(px)
    recorder.icon_size.should eq({1, 1})
  ensure
    Egui::SystemPorts::Window.use(Egui::SystemPorts::Window::Implementation.new)
  end

  it "default Window implementation is a headless no-op" do
    Egui::SystemPorts::Window.set_title("x")
    Egui::SystemPorts::Window.minimize
    Egui::SystemPorts::Window.maximize
    Egui::SystemPorts::Window.restore
    Egui::SystemPorts::Window.toggle_fullscreen
    Egui::SystemPorts::Window.fullscreen?.should be_false
  end

  it "default Screen implementation is headless" do
    Egui::SystemPorts::Screen.size.should be_nil
    Egui::SystemPorts::Screen.dpi_scale.should eq(1.0)
  end

  it "UserDirs resolves platform base dirs with spec defaults" do
    home = Egui::SystemPorts::UserDirs.home
    home.should_not be_empty
    {% if flag?(:win32) %}
      Egui::SystemPorts::UserDirs.config.should eq(ENV["APPDATA"]? || home)
      Egui::SystemPorts::UserDirs.data.should eq(ENV["LOCALAPPDATA"]? || Egui::SystemPorts::UserDirs.config)
      Egui::SystemPorts::UserDirs.cache.should eq(File.join(Egui::SystemPorts::UserDirs.data, "cache"))
    {% elsif flag?(:darwin) %}
      Egui::SystemPorts::UserDirs.config.should eq(File.join(home, "Library/Application Support"))
      Egui::SystemPorts::UserDirs.data.should eq(File.join(home, "Library/Application Support"))
      Egui::SystemPorts::UserDirs.cache.should eq(File.join(home, "Library/Caches"))
      Egui::SystemPorts::UserDirs.documents.should eq(File.join(home, "Documents"))
    {% else %}
      Egui::SystemPorts::UserDirs.config.should eq(File.join(home, ".config"))
      Egui::SystemPorts::UserDirs.data.should eq(File.join(home, ".local/share"))
      Egui::SystemPorts::UserDirs.cache.should eq(File.join(home, ".cache"))
    {% end %}
  end

  {% if flag?(:win32) %}
    it "file dialogs use the installed native runner (no subprocess)" do
      calls = [] of {Bool, String, Array(String), String?, String?}
      Egui::SystemPorts::Dialogs.use_native_dialogs do |save, title, filters, dir, name|
        calls << {save, title, filters, dir, name}
        save ? "C:\\saved.txt" : "C:\\opened.txt"
      end
      got = [] of String?
      Egui::SystemPorts::OpenFileDialog.show(
        title: "Pick", filters: ["*.png"], directory: "C:\\tmp") { |p| got << p }
      Egui::SystemPorts::SaveFileDialog.show(
        title: "Save", default_name: "out.png") { |p| got << p }
      drain_async_dialogs
      got.should eq(["C:\\opened.txt", "C:\\saved.txt"])
      calls.size.should eq(2)
      calls[0][0].should be_false
      calls[0][2].should eq(["*.png"])
      calls[0][3].should eq("C:\\tmp")
      calls[1][0].should be_true
      calls[1][4].should eq("out.png")
    ensure
      Egui::SystemPorts::Dialogs.use_native_dialogs
    end

    it "Dialogs.which finds PATHEXT executables on PATH" do
      Egui::SystemPorts::Dialogs.which("powershell").should_not be_nil
      Egui::SystemPorts::Dialogs.which("surely-not-a-real-tool-xyz").should be_nil
    end

    it "Dialogs.run_powershell round-trips stdout via EncodedCommand" do
      Egui::SystemPorts::Dialogs.run_powershell("Write-Output 'ok'").should eq("ok")
    end

    it "UserDirs.documents resolves a real known folder" do
      docs = Egui::SystemPorts::UserDirs.documents
      docs.should_not be_nil
      File.directory?(docs.not_nil!).should be_true
    end
  {% end %}

  it "Fonts lists per-platform candidates, best-first" do
    paths = Egui::SystemPorts::Fonts.search_paths
    paths.should_not be_empty
    paths.all? { |p| p.ends_with?(".ttf") }.should be_true
    # The platform list must be one coherent set, not a mix.
    {% if flag?(:win32) %}
      paths.first.should eq("C:\\Windows\\Fonts\\segoeui.ttf")
    {% elsif flag?(:darwin) %}
      paths.first.should eq("/System/Library/Fonts/SFNS.ttf")
    {% else %}
      paths.first.should eq("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
    {% end %}
  end
end

# A minimal JSON::Serializable config type for the AppConfig specs.
class SpecSettings
  include JSON::Serializable
  property theme : String = "dark"

  def initialize(@theme : String = "dark")
  end
end

def with_temp_base(&) : Nil
  dir = File.join(Dir.tempdir, "egui-appconfig-spec-#{rand(UInt64::MAX).to_s(16)}")
  Egui::SystemPorts::AppConfig.use(dir)
  begin
    yield dir
  ensure
    Egui::SystemPorts::AppConfig.use(nil)
    FileUtils.rm_rf(dir)
  end
end

describe Egui::SystemPorts::AppConfig do
  it "namespaces configs by app, key → .json" do
    with_temp_base do |dir|
      Egui::SystemPorts::AppConfig.path("notepad")
        .should eq File.join(dir, "notepad", "settings.json")
      Egui::SystemPorts::AppConfig.path("notepad", "profiles")
        .should eq File.join(dir, "notepad", "profiles.json")
      Egui::SystemPorts::AppConfig.path("notepad", "keep.json")
        .should eq File.join(dir, "notepad", "keep.json")
    end
  end

  it "places configs in the platform user config dir by default" do
    Egui::SystemPorts::AppConfig.path("notepad")
      .should eq File.join(Egui::SystemPorts::UserDirs.config,
        "notepad", "settings.json")
  end

  it "load yields the default for a missing file" do
    with_temp_base do |dir|
      Egui::SystemPorts::AppConfig.load("notepad",
        SpecSettings.new).theme.should eq "dark"
    end
  end

  it "load yields the default for corrupt JSON" do
    with_temp_base do |dir|
      path = Egui::SystemPorts::AppConfig.path("notepad")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{ not json")
      Egui::SystemPorts::AppConfig.load("notepad",
        SpecSettings.new).theme.should eq "dark"
    end
  end

  it "save → load round-trips through the user dir" do
    with_temp_base do |dir|
      settings = SpecSettings.new("light")
      Egui::SystemPorts::AppConfig.save("notepad", settings)
      File.exists?(Egui::SystemPorts::AppConfig.path("notepad")).should be_true
      Egui::SystemPorts::AppConfig.load("notepad",
        SpecSettings.new).theme.should eq "light"
    end
  end
end

# Drain any leftover async-dialog requests so worker fibers can't
# leak across tests.
def drain_async_dialogs : Nil
  50.times do
    Egui::SystemPorts::AsyncDialogs.pump
    break unless Egui::SystemPorts::AsyncDialogs.pending?
  end
end

describe Egui::SystemPorts::AsyncDialogs do
  it "delivers the result via callback on a later pump" do
    got = [] of String?
    Egui::SystemPorts::AsyncDialogs.start(-> { "picked.png" }, ->(path : String?) { got << path })
    Egui::SystemPorts::AsyncDialogs.pending?.should be_true
    got.should be_empty

    Egui::SystemPorts::AsyncDialogs.pump
    got.should eq(["picked.png"])
    Egui::SystemPorts::AsyncDialogs.pending?.should be_false
  end

  it "delivers nil for a cancelled/failed dialog" do
    got = [] of String?
    Egui::SystemPorts::AsyncDialogs.start(-> { nil.as(String?) }, ->(path : String?) { got << path })
    Egui::SystemPorts::AsyncDialogs.pump
    got.should eq([nil])
  end

  it "does not block the frame while the dialog is open" do
    got = [] of String?
    Egui::SystemPorts::AsyncDialogs.start(
      -> { sleep 50.milliseconds; "slow.png" },
      ->(path : String?) { got << path })

    # A pump while the worker fiber is still waiting must return in
    # ~1ms (the bounded scheduler pass), not after the worker.
    start = Time.instant
    Egui::SystemPorts::AsyncDialogs.pump
    (Time.instant - start).total_milliseconds.should be < 50
    got.should be_empty
    Egui::SystemPorts::AsyncDialogs.pending?.should be_true

    # Later pumps deliver as soon as the work finishes.
    100.times do
      Egui::SystemPorts::AsyncDialogs.pump
      break unless Egui::SystemPorts::AsyncDialogs.pending?
    end
    got.should eq(["slow.png"])
  ensure
    drain_async_dialogs
  end

  it "delivers multiple concurrent requests in completion order" do
    got = [] of String?
    Egui::SystemPorts::AsyncDialogs.start(-> { "a.png" }, ->(p : String?) { got << p })
    Egui::SystemPorts::AsyncDialogs.start(-> { "b.png" }, ->(p : String?) { got << p })
    100.times do
      Egui::SystemPorts::AsyncDialogs.pump
      break if got.size == 2
    end
    got.should eq(["a.png", "b.png"])
  end

  it "pump is a no-op (and instant) when idle" do
    Egui::SystemPorts::AsyncDialogs.pending?.should be_false
    Egui::SystemPorts::AsyncDialogs.pump # must not raise / block
  end
end
