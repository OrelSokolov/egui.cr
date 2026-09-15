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

  def set_title(title : String) : Nil
    @title = title
  end

  def set_size(width : Int32, height : Int32) : Nil
    @size = {width, height}
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
    recorder.title.should eq("demo")
    recorder.size.should eq({640, 480})
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
    {% if flag?(:darwin) %}
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
