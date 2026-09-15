require "spec"
require "../src/egui"

# Headless system-port specs. Ports that touch the real desktop (file
# dialogs, MessageBox, notifications, OpenUrl) are NOT invoked here —
# they would open real windows / spawn apps on a desktop machine. The
# injectable ports are exercised through their defaults and recorders.

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

  it "UserDirs resolves XDG paths with spec defaults" do
    home = Egui::SystemPorts::UserDirs.home
    home.should_not be_empty
    Egui::SystemPorts::UserDirs.config.should eq(File.join(home, ".config"))
    Egui::SystemPorts::UserDirs.data.should eq(File.join(home, ".local/share"))
    Egui::SystemPorts::UserDirs.cache.should eq(File.join(home, ".cache"))
  end
end
