# Device emulation — the app's default window size / aspect / density,
# Chrome-DevTools style: a DeviceType (desktop/phone/tablet/tv base
# size), a concrete Device preset (iPhone/Pixel/iPad — size + DPR, like
# the DevTools device toolbar) and a forced DPR ("retina mode"). At
# startup the environment can force any of it (EGUI_DEVICE_TYPE,
# EGUI_DEVICE, EGUI_DPR, EGUI_RETINA, EGUI_ORIENTATION); after that the
# values live as in-memory application state — nothing is written to
# disk — and stay changeable at runtime: the runtime inspector's dock
# menu (the ⚙ button) edits them globally (Inspector#render_dock_menu).
# A forced mode drives the window through SystemPorts::Window and the
# frame's pixels_per_point through the backend (see Sokol.dpi_scale).

module Egui
  # Window orientation. nil (AUTO) follows the mode's natural one —
  # portrait for phones/tablets, landscape for desktop/tv.
  enum Orientation
    Portrait
    Landscape

    # EGUI_ORIENTATION value → enum; the axis synonyms are accepted too.
    def self.parse(raw : String) : Orientation?
      case raw.downcase
      when "portrait", "vertical"    then Portrait
      when "landscape", "horizontal" then Landscape
      end
    end
  end

  # Device class — each type maps to a base window size (in the type's
  # natural orientation) when no concrete device preset is picked.
  enum DeviceType
    Desktop
    Phone
    Tablet
    Tv

    def base_size : Vec2
      case self
      in .desktop? then Vec2.new(1280.0, 800.0)
      in .phone?   then Vec2.new(390.0, 844.0)
      in .tablet?  then Vec2.new(820.0, 1180.0)
      in .tv?      then Vec2.new(1920.0, 1080.0)
      end
    end

    # The orientation the base size is stored in.
    def natural_orientation : Orientation
      desktop? || tv? ? Orientation::Landscape : Orientation::Portrait
    end

    def self.parse(raw : String) : DeviceType?
      case raw.downcase
      when "desktop"         then Desktop
      when "phone", "mobile" then Phone
      when "tablet", "ipad"  then Tablet
      when "tv"              then Tv
      end
    end
  end

  # A concrete device preset — the Chrome DevTools device toolbar list:
  # viewport in POINTS (portrait form, like DevTools) + the device's
  # DPR. A picked preset drives the logical size AND the density.
  struct Device
    getter name : String
    getter size : Vec2
    getter dpr : Float64
    getter type : DeviceType

    def initialize(@name : String, @size : Vec2, @dpr : Float64,
                   @type : DeviceType)
    end

    # EGUI_DEVICE value → preset. The name matches case-insensitively,
    # underscores and spaces read as dashes.
    def self.find(raw : String) : Device?
      key = raw.downcase.strip.tr("_ ", "--").squeeze("-")
      ALL.find(&.name.==(key))
    end

    # Phones (Chrome DevTools viewport list), tablets, then the
    # desktop/tv bases. Extend here — every entry is menu-selectable in
    # the inspector and forceable through EGUI_DEVICE.
    ALL = [
      Device.new("iphone-se", Vec2.new(375.0, 667.0), 2.0,
        DeviceType::Phone),
      Device.new("iphone-15", Vec2.new(393.0, 852.0), 3.0,
        DeviceType::Phone),
      Device.new("iphone-15-pro-max", Vec2.new(430.0, 932.0), 3.0,
        DeviceType::Phone),
      Device.new("pixel-7", Vec2.new(412.0, 915.0), 2.625,
        DeviceType::Phone),
      Device.new("galaxy-s23", Vec2.new(360.0, 780.0), 3.0,
        DeviceType::Phone),
      Device.new("ipad-mini", Vec2.new(768.0, 1024.0), 2.0,
        DeviceType::Tablet),
      Device.new("ipad-air", Vec2.new(820.0, 1180.0), 2.0,
        DeviceType::Tablet),
      Device.new("ipad-pro", Vec2.new(1024.0, 1366.0), 2.0,
        DeviceType::Tablet),
      Device.new("desktop", Vec2.new(1280.0, 800.0), 1.0,
        DeviceType::Desktop),
      Device.new("tv", Vec2.new(1920.0, 1080.0), 1.0, DeviceType::Tv),
    ]
  end

  module Display
    @@device_type : DeviceType = DeviceType::Desktop
    @@orientation : Orientation? = nil
    @@device : Device? = nil
    @@dpr : Float64? = nil
    @@forced : Bool = false
    @@window_applied : Bool = false

    class_getter device_type : DeviceType
    class_getter device : Device?

    # The effective forced DPR: the explicit override (EGUI_DPR /
    # EGUI_RETINA / the inspector's DPR row), else the device preset's
    # DPR. nil = follow the host's own scale (not forced).
    def self.dpr : Float64?
      @@dpr || @@device.try(&.dpr)
    end

    # The effective orientation: the explicit override, or the active
    # mode's natural one.
    def self.orientation : Orientation
      @@orientation || (@@device ? @@device.not_nil!.type
        : @@device_type).natural_orientation
    end

    # The raw override — nil means AUTO (follow the mode). The
    # inspector's «Auto» item reads this.
    class_getter orientation_override : Orientation?

    # True when the mode was forced through the environment (or changed
    # at runtime) — a forced mode drives the window and the DPR.
    def self.forced? : Bool
      @@forced
    end

    # Startup: read EGUI_DEVICE / EGUI_DEVICE_TYPE / EGUI_DPR /
    # EGUI_RETINA / EGUI_ORIENTATION once (called from the GUI backend's
    # run). An unknown value warns and keeps the default; a known one
    # marks the mode FORCED. A concrete EGUI_DEVICE wins over
    # EGUI_DEVICE_TYPE (the preset implies its type).
    def self.load_env : Nil
      if (raw = ENV["EGUI_DEVICE"]?)
        if (d = Device.find(raw))
          @@device = d
          @@device_type = d.type
          @@forced = true
        else
          STDERR.puts "[egui] EGUI_DEVICE: unknown value #{raw.inspect} " \
                      "(known: #{Device::ALL.map(&.name).join(", ")})"
        end
      end
      unless @@device
        if (raw = ENV["EGUI_DEVICE_TYPE"]?)
          if (t = DeviceType.parse(raw))
            @@device_type = t
            @@forced = true
          else
            STDERR.puts "[egui] EGUI_DEVICE_TYPE: unknown value " \
                        "#{raw.inspect} (known: desktop, phone, tablet, tv)"
          end
        end
      end
      if (raw = ENV["EGUI_DPR"]?)
        if (v = raw.to_f64?) && v > 0.0
          @@dpr = v
          @@forced = true
        else
          STDERR.puts "[egui] EGUI_DPR: not a positive number " \
                      "#{raw.inspect}"
        end
      end
      if (raw = ENV["EGUI_RETINA"]?) && raw != "0"
        @@dpr = 2.0
        @@forced = true
      end
      if (raw = ENV["EGUI_ORIENTATION"]?)
        if (o = Orientation.parse(raw))
          @@orientation = o
          @@forced = true
        else
          STDERR.puts "[egui] EGUI_ORIENTATION: unknown value " \
                      "#{raw.inspect} (known: portrait, landscape)"
        end
      end
    end

    # The active mode's LOGICAL viewport in points (orientation
    # applied): the device preset's size, or the type's base size.
    def self.size : Vec2
      mode_type = @@device ? @@device.not_nil!.type : @@device_type
      base = @@device ? @@device.not_nil!.size : mode_type.base_size
      # Base sizes are stored in the type's NATURAL orientation —
      # a pick that differs from it swaps (phone/tablet bases are
      # portrait, desktop/tv landscape).
      orientation != mode_type.natural_orientation ?
        Vec2.new(base.y, base.x) : base
    end

    # The window footprint in PHYSICAL pixels for a host whose window
    # units are `host_scale` points-per-pixel: logical × DPR ÷ host.
    # The backend divides by sapp_dpi_scale, so the frame's
    # pixels-per-point (forced to DPR) resolves the logical size back
    # out exactly — on any host, retina or not.
    def self.pixel_size(host_scale : Float64) : {Int32, Int32}
      d = dpr || 1.0
      s = host_scale > 0.0 ? host_scale : 1.0
      v = size
      {(v.x * d / s).round.to_i, (v.y * d / s).round.to_i}
    end

    # The backend's startup size: the mode's logical viewport when
    # forced, the app's own run(width:, height:) otherwise. Exact on 1x
    # hosts; a retina host corrects the pixel footprint on the first
    # frame (#apply_window_size).
    def self.apply(width : Int32, height : Int32) : {Int32, Int32}
      return {width, height} unless @@forced
      v = size
      {v.x.round.to_i, v.y.round.to_i}
    end

    # One-shot, called from the frame path on a forced mode: snap the
    # window to the mode's pixel footprint now that the HOST scale
    # (sapp_dpi_scale) is known — the startup size could only guess it.
    # Once. Later frames don't touch the window — the user resizes
    # freely after that; a runtime mode change re-sizes explicitly.
    def self.apply_window_size : Nil
      return if @@window_applied
      @@window_applied = true
      resize_live
    end

    # --- runtime changes (the inspector's dock menu, App#device= …) --

    def self.device_type=(type : DeviceType) : DeviceType
      changed = type != @@device_type || !@@device.nil?
      @@device_type = type
      @@device = nil # the type pick clears the concrete preset
      @@forced = true
      changed_resize(changed)
      type
    end

    def self.device=(device : Device?) : Device?
      changed = device != @@device
      @@device = device
      @@device_type = device.type if device
      @@forced = true
      changed_resize(changed)
      device
    end

    # The explicit DPR override — nil = AUTO (device preset's DPR, else
    # the host's own scale).
    def self.dpr=(dpr : Float64?) : Float64?
      changed = dpr != @@dpr
      @@dpr = dpr
      @@forced = true if dpr
      changed_resize(changed)
      dpr
    end

    def self.orientation=(orientation : Orientation?) : Orientation?
      changed = orientation != @@orientation
      @@orientation = orientation
      @@forced = true if orientation
      changed_resize(changed)
      orientation
    end

    # Re-size on a real change and mark the one-shot done — the frame
    # path must not re-fight an explicit runtime resize.
    private def self.changed_resize(changed : Bool) : Nil
      return unless changed
      @@window_applied = true
      resize_live
    end

    private def self.resize_live : Nil
      w, h = pixel_size(SystemPorts::Screen.dpi_scale)
      SystemPorts::Window.set_size(w, h)
    end
  end
end
