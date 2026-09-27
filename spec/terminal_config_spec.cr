# Terminal config specs: profile JSON round-trips, defaults for a
# missing/corrupt file, active-profile fallback, and the ConfigStore
# adapters (platform selection + XDG override), all against a temp dir.

require "spec"
require "../src/egui"

class TempConfigAdapter < Egui::Terminal::ConfigStore::Adapter
  getter dir : String

  def initialize(@dir : String)
  end

  def config_dir : String
    @dir
  end
end

def with_temp_store(&) : Nil
  dir = File.join(Dir.tempdir, "egui-terminal-spec-#{rand(UInt64::MAX).to_s(16)}")
  Dir.mkdir_p(dir)
  previous = Egui::Terminal::ConfigStore.adapter
  Egui::Terminal::ConfigStore.use(TempConfigAdapter.new(dir))
  begin
    yield dir
  ensure
    Egui::Terminal::ConfigStore.use(previous)
    FileUtils.rm_rf(dir)
  end
end

describe Egui::Terminal::Profile do
  it "parses the saved background color" do
    profile = Egui::Terminal::Profile.from_json(%({"background": "#10ff20"}))
    color = profile.background_color
    color.r.should eq 0x10
    color.g.should eq 0xff
    color.b.should eq 0x20
    color.a.should eq 255
  end

  it "falls back to the theme default on a bad color, keeps other keys" do
    profile = Egui::Terminal::Profile.from_json(
      %({"background": "nope", "cursor_blinks": true}))
    profile.background_color.should eq Egui::Terminal::Theme.new.background
    profile.cursor_blinks.should be_true
  end

  it "serializes the background color back to #rrggbb" do
    profile = Egui::Terminal::Profile.new
    profile.background_color = Egui::Color32.rgb(1, 2, 3)
    profile.to_json.should contain(%("background":"#010203"))
  end
end

describe Egui::Terminal::Config do
  it "defaults when no file exists" do
    with_temp_store do |dir|
      config = Egui::Terminal::Config.load
      config.active.should eq "default"
      config.profiles.keys.should eq ["default"]
      config.active_profile.opacity.should eq 1.0
      config.active_profile.cursor_blinks.should be_false
      config.active_profile.background.should eq Egui::Terminal::Theme::DEFAULT_BG_HEX
    end
  end

  it "defaults when the file is corrupt JSON" do
    with_temp_store do |dir|
      File.write(Egui::Terminal::ConfigStore.path, "{ not json")
      Egui::Terminal::Config.load.profiles.keys.should eq ["default"]
    end
  end

  it "round-trips profiles through save → load" do
    with_temp_store do |dir|
      config = Egui::Terminal::Config.new
      config.profiles["solarized"] = Egui::Terminal::Profile.new(
        opacity: 0.85, background: "#002b36", cursor_blinks: true)
      config.active = "solarized"
      config.save

      loaded = Egui::Terminal::Config.load
      loaded.active.should eq "solarized"
      profile = loaded.active_profile
      profile.opacity.should eq 0.85
      profile.background.should eq "#002b36"
      profile.cursor_blinks.should be_true
      # the untouched default profile survived too
      loaded.profiles.has_key?("default").should be_true
    end
  end

  it "falls back to any survivor when the active name is stale" do
    config = Egui::Terminal::Config.new
    config.profiles.delete("default")
    config.profiles["only"] = Egui::Terminal::Profile.new
    config.active = "gone"
    config.active_profile.should be config.profiles["only"]
  end
end

describe Egui::Terminal::ConfigStore do
  it "selects the adapter for this platform" do
    {% if flag?(:win32) %}
      Egui::Terminal::ConfigStore.adapter.should be_a Egui::Terminal::ConfigStore::WindowsAdapter
    {% elsif flag?(:darwin) %}
      Egui::Terminal::ConfigStore.adapter.should be_a Egui::Terminal::ConfigStore::MacAdapter
    {% else %}
      Egui::Terminal::ConfigStore.adapter.should be_a Egui::Terminal::ConfigStore::LinuxAdapter
    {% end %}
  end

  {% unless flag?(:win32) || flag?(:darwin) %}
    it "honors XDG_CONFIG_HOME (Linux adapter)" do
      old = ENV["XDG_CONFIG_HOME"]?
      ENV["XDG_CONFIG_HOME"] = "/tmp/xdg-spec"
      begin
        path = Egui::Terminal::ConfigStore::LinuxAdapter.new.path
        path.should eq "/tmp/xdg-spec/egui-terminal/settings.json"
      ensure
        if old
          ENV["XDG_CONFIG_HOME"] = old
        else
          ENV.delete("XDG_CONFIG_HOME")
        end
      end
    end

    it "defaults to ~/.config (Linux adapter)" do
      old = ENV["XDG_CONFIG_HOME"]?
      ENV.delete("XDG_CONFIG_HOME")
      begin
        home = ENV["HOME"]? || Dir.current
        Egui::Terminal::ConfigStore::LinuxAdapter.new.config_dir
          .should eq File.join(home, ".config/egui-terminal")
      ensure
        ENV["XDG_CONFIG_HOME"] = old if old
      end
    end
  {% end %}

  it "places the settings file inside the adapter's dir" do
    adapter = TempConfigAdapter.new("/store")
    adapter.path.should eq "/store/settings.json"
  end
end
