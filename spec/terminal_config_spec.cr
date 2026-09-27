# Terminal config specs: profile JSON round-trips, defaults for a
# missing/corrupt file, active-profile fallback, and the ConfigStore
# path through the AppConfig system port, all against a temp dir.

require "spec"
require "../src/egui"

def with_temp_store(&) : Nil
  dir = File.join(Dir.tempdir, "egui-terminal-spec-#{rand(UInt64::MAX).to_s(16)}")
  Dir.mkdir_p(dir)
  Egui::SystemPorts::AppConfig.use(dir)
  begin
    yield dir
  ensure
    Egui::SystemPorts::AppConfig.use(nil)
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
      path = Egui::Terminal::ConfigStore.path
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{ not json")
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
  it "routes the settings file through the AppConfig port" do
    with_temp_store do |dir|
      Egui::Terminal::ConfigStore.path
        .should eq File.join(dir, "egui-terminal", "settings.json")
    end
  end

  it "falls back to the platform user config dir when no override is set" do
    Egui::Terminal::ConfigStore.path
      .should eq File.join(Egui::SystemPorts::UserDirs.config,
        "egui-terminal", "settings.json")
  end
end
