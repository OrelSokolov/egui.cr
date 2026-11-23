require "spec"
require "../src/egui"

describe Egui::DeviceType do
  it "parses the EGUI_DEVICE_TYPE values (mobile/ipad synonyms)" do
    Egui::DeviceType.parse("desktop").should eq(Egui::DeviceType::Desktop)
    Egui::DeviceType.parse("Phone").should eq(Egui::DeviceType::Phone)
    Egui::DeviceType.parse("mobile").should eq(Egui::DeviceType::Phone)
    Egui::DeviceType.parse("ipad").should eq(Egui::DeviceType::Tablet)
    Egui::DeviceType.parse("tv").should eq(Egui::DeviceType::Tv)
    Egui::DeviceType.parse("fridge").should be_nil
  end

  it "maps every type to a base size in its natural orientation" do
    Egui::DeviceType::Desktop.base_size.should eq(Egui::Vec2.new(1280.0, 800.0))
    Egui::DeviceType::Phone.base_size.should eq(Egui::Vec2.new(390.0, 844.0))
    Egui::DeviceType::Tablet.base_size.should eq(Egui::Vec2.new(820.0, 1180.0))
    Egui::DeviceType::Tv.base_size.should eq(Egui::Vec2.new(1920.0, 1080.0))
    Egui::DeviceType::Phone.natural_orientation
      .should eq(Egui::Orientation::Portrait)
    Egui::DeviceType::Tv.natural_orientation
      .should eq(Egui::Orientation::Landscape)
  end
end

describe Egui::Orientation do
  it "parses the EGUI_ORIENTATION values (axis synonyms included)" do
    Egui::Orientation.parse("portrait").should eq(Egui::Orientation::Portrait)
    Egui::Orientation.parse("vertical").should eq(Egui::Orientation::Portrait)
    Egui::Orientation.parse("landscape").should eq(Egui::Orientation::Landscape)
    Egui::Orientation.parse("horizontal").should eq(Egui::Orientation::Landscape)
    Egui::Orientation.parse("diagonal").should be_nil
  end
end

describe Egui::Device do
  it "finds presets case-insensitively (dashes/underscores equal)" do
    Egui::Device.find("iphone-15").should eq(Egui::Device.find("IPHONE_15"))
    Egui::Device.find("pixel-7").try(&.size)
      .should eq(Egui::Vec2.new(412.0, 915.0))
    Egui::Device.find("pixel-7").try(&.dpr).should eq(2.625)
    Egui::Device.find("nokia-3310").should be_nil
  end
end

describe Egui::Display do
  # Fresh process state: no env yet → NOT forced, the app's own run
  # size passes through untouched and the DPR follows the host. (Load
  # order matters — the tests below set state and never un-set it;
  # there is no reset API, the state is a process-wide singleton by
  # design.)
  it "passes the app's own run size through while not forced" do
    Egui::Display.forced?.should be_false
    Egui::Display.apply(800, 600).should eq({800, 600})
    Egui::Display.dpr.should be_nil
  end

  it "loads EGUI_DEVICE (preset) and forces size + DPR" do
    ENV["EGUI_DEVICE"] = "pixel-7"
    begin
      Egui::Display.load_env
      Egui::Display.forced?.should be_true
      Egui::Display.device.try(&.name).should eq("pixel-7")
      Egui::Display.size.should eq(Egui::Vec2.new(412.0, 915.0))
      Egui::Display.dpr.should eq(2.625)
      Egui::Display.apply(800, 600).should eq({412, 915})
    ensure
      ENV.delete("EGUI_DEVICE")
    end
  end

  it "loads EGUI_DEVICE_TYPE + EGUI_RETINA + EGUI_ORIENTATION" do
    # Reset the runtime state the previous test left behind — the state
    # is a process singleton, and load_env must see a preset-less mode
    # to honor EGUI_DEVICE_TYPE.
    Egui::Display.device = nil
    Egui::Display.dpr = nil
    Egui::Display.orientation = nil
    ENV["EGUI_DEVICE_TYPE"] = "phone"
    ENV["EGUI_RETINA"] = "1"
    ENV["EGUI_ORIENTATION"] = "landscape"
    begin
      Egui::Display.load_env
      Egui::Display.device.should be_nil
      Egui::Display.device_type.should eq(Egui::DeviceType::Phone)
      # landscape swaps the phone's portrait base
      Egui::Display.size.should eq(Egui::Vec2.new(844.0, 390.0))
      Egui::Display.dpr.should eq(2.0)
      # physical pixels = logical × DPR ÷ host scale
      Egui::Display.pixel_size(1.0).should eq({1688, 780})
      Egui::Display.pixel_size(2.0).should eq({844, 390})
    ensure
      ENV.delete("EGUI_DEVICE_TYPE")
      ENV.delete("EGUI_RETINA")
      ENV.delete("EGUI_ORIENTATION")
    end
  end

  # Runtime change (the inspector path): the setter re-computes the
  # size immediately — SystemPorts::Window#set_size is the headless
  # no-op here, so the call itself is the smoke test.
  it "applies a runtime device change" do
    Egui::Display.dpr = nil # drop the RETINA=1 override from above
    Egui::Display.orientation = nil # drop the landscape override too
    Egui::Display.device = Egui::Device.find("ipad-pro").not_nil!
    Egui::Display.size.should eq(Egui::Vec2.new(1024.0, 1366.0))
    Egui::Display.dpr.should eq(2.0)
    Egui::Display.device = nil
    Egui::Display.device_type = Egui::DeviceType::Tv
    Egui::Display.size.should eq(Egui::Vec2.new(1920.0, 1080.0))
    Egui::Display.dpr.should be_nil
    Egui::Display.orientation = Egui::Orientation::Portrait
    Egui::Display.size.should eq(Egui::Vec2.new(1080.0, 1920.0))
    Egui::Display.orientation = nil
  end
end
