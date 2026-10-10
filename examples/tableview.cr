# TableView demo — a Synaptic-style package list: a GTK-model/view
# table over a ListStore of a few hundred fake packages, with a search
# filter (toolbar), click-to-sort columns, drag-resizable headers,
# multi-selection (Ctrl/Shift/arrows/Ctrl+A) and row activation on
# double-click (install/remove toggle).

require "../src/egui"
require "../src/egui/backend/sokol"

class PkgApp < Egui::App
  # Model columns: status / name / installed ver / available ver /
  # size (KiB) / section.
  STATUS = 0
  NAME = 1
  INSTALLED = 2
  AVAILABLE = 3
  SIZE = 4
  SECTION = 5

  getter store = Egui::ListStore.new(:string, :string, :string, :string,
    :int, :string)

  @view : Egui::TableView
  @search = ""
  @message = "Welcome — click headers to sort, drag their edges to resize"

  def initialize
    super
    seed_packages
    @view = Egui::TableView.new("packages", store)
    @view.selection.mode = :multiple
    @view.empty_text = "no packages match"
    @view.column("Status", STATUS, fraction: 0.13, min_width: 70.0)
    @view.column("Package", NAME, fraction: 0.27)
    @view.column("Installed", INSTALLED, fraction: 0.11)
    @view.column("Available", AVAILABLE, fraction: 0.11)
    @view.column("Size", SIZE, fraction: 0.10, align: :right)
      .format = ->PkgApp.human_size(Egui::ListStore::Value)
    @view.column("Section", SECTION, fraction: 0.16)
    # Status colors: the Synaptic package states.
    @view.column("Status", STATUS).color = ->status_color(Int32)
    @view.on_activate { |row| toggle(row) }
  end

  def self.human_size(v : Egui::ListStore::Value) : String
    kb = v.as(Int32)
    return "#{kb} KiB" if kb < 1024
    "#{"%.1f" % (kb / 1024.0)} MiB"
  end

  def status_color(row : Int32) : Egui::Color32
    v = Egui::Color32.rgb(0x9e, 0x9e, 0x9e) # not installed — dim
    case store.get_string(row, STATUS)
    when "installed"  then v = Egui::Color32.rgb(0x4e, 0xc9, 0x4e)
    when "upgradable" then v = Egui::Color32.rgb(0xe0, 0xa2, 0x3a)
    when "broken"     then v = Egui::Color32.rgb(0xe0, 0x5d, 0x5d)
    end
    v
  end

  # Deterministic fake pool: real-ish Ubuntu names across sections.
  NAMES = {"gcc", "g++", "make", "cmake", "python3", "python3-pip", "ruby",
           "crystal", "rustc", "cargo", "golang", "openjdk-17-jdk", "llvm",
           "clang", "gdb", "valgrind", "git", "mercurial", "subversion",
           "curl", "wget", "rsync", "openssh-client", "openssh-server",
           "nginx", "apache2", "caddy", "postgresql-16", "mariadb-server",
           "redis", "memcached", "sqlite3", "ffmpeg", "imagemagick",
           "gimp", "inkscape", "blender", "vlc", "mpv", "audacity",
           "libreoffice", "firefox", "chromium", "thunderbird", "neovim",
           "vim", "emacs", "nano", "htop", "btop", "tmux", "zsh", "fish",
           "bash-completion", "ripgrep", "fd-find", "fzf", "bat", "exa",
           "tree", "jq", "yq", "docker.io", "podman", "qemu-kvm",
           "virtualbox", "wireguard-tools", "openvpn", "network-manager",
           "firewalld", "ufw", "fail2ban", "clamav", "zstd", "xz-utils",
           "zip", "unzip", "tar", "htop", "strace", "ltrace", "sysstat",
           "lm-sensors", "acpi", "bluez", "cups", "sane-utils", "pipewire",
           "alsa-utils", "mesa-utils", "nvidia-driver-550", "steam",
           "wine", "bottles", "flatpak", "snapd", "appstream", "polkit",
           "systemd", "dbus", "cron", "anacron", "logrotate", "rsyslog"}

  SECTIONS = {"devel", "python", "ruby", "web", "editors", "net", "utils",
              "multimedia", "graphics", "admin", "libs", "x11", "science"}

  def seed_packages : Nil
    rng = Random.new(42)
    NAMES.each do |name|
      roll = rng.rand
      installed = roll < 0.35
      upgradable = installed && rng.rand < 0.3
      broken = roll > 0.97
      status = broken ? "broken" : upgradable ? "upgradable" :
               installed ? "installed" : "not installed"
      ver = "#{rng.rand(8) + 1}.#{rng.rand(20)}.#{rng.rand(10)}"
      store.append(status, "#{name}-#{Ver.gen(rng)}",
        installed ? ver : "",
        upgradable ? Ver.bump(ver, rng) : ver,
        (rng.rand(90_000) + 24).to_i32,
        SECTIONS[rng.rand(SECTIONS.size)])
    end
  end

  # Tiny version string helpers (kept nested-ish and small: this is a
  # demo data generator, not the point of the file).
  module Ver
    def self.gen(rng : Random) : String
      "#{rng.rand(3) + 1}#{('a'..'z').to_a[rng.rand(26)]}"
    end

    def self.bump(base : String, rng : Random) : String
      "#{base}.#{rng.rand(9) + 1}~backport"
    end
  end

  def toggle(row : Int32) : Nil
    status = store.get_string(row, STATUS)
    if status == "installed"
      store.set(row, STATUS, "not installed")
      store.set(row, INSTALLED, "")
      @message = "Removed #{store.get_string(row, NAME)}"
    else
      store.set(row, STATUS, "installed")
      store.set(row, INSTALLED, store.get_string(row, AVAILABLE))
      @message = "Installed #{store.get_string(row, NAME)}"
    end
  end

  def act_on_selection(&action : Int32 ->) : Nil
    rows = @view.selection.rows.to_a.sort!
    rows.each { |r| action.call(r) }
    @message = "#{rows.size} package#{rows.size == 1 ? "" : "s"} updated"
    @view.selection.clear
  end

  def update(ctx : Egui::Context) : Nil
    ctx.top_panel("toolbar", height: 44.0, resizable: false) do |ui|
      ui.label("Search")
      ui.text_edit_singleline(@search, hint: "package name…",
        focus_id: "search") do |text|
        @search = text
        needle = text.strip.downcase
        store.filter = needle.empty? ? nil : ->(r : Int32) {
          store.get_string(r, NAME).downcase.includes?(needle)
        }
      end
      if ui.button("Mark install").clicked?
        act_on_selection do |r|
          store.set(r, STATUS, "installed")
          store.set(r, INSTALLED, store.get_string(r, AVAILABLE))
        end
      end
      if ui.button("Mark remove").clicked?
        act_on_selection do |r|
          store.set(r, STATUS, "not installed")
          store.set(r, INSTALLED, "")
        end
      end
      if ui.button("Upgrade").clicked?
        act_on_selection do |r|
          store.set(r, STATUS, "installed")
          store.set(r, INSTALLED, store.get_string(r, AVAILABLE))
        end
      end
      if ui.button("Clear").clicked? && !@view.selection.rows.empty?
        @view.selection.clear
        @message = "Selection cleared"
      end
    end

    ctx.central_panel do |ui|
      @view.show(ui)
    end

    ctx.bottom_panel("status", height: 28.0, resizable: false) do |ui|
      ui.label("#{store.display_count} packages, " \
               "#{@view.selection.count} selected — #{@message}")
    end
  end
end

Egui::Backend::Sokol.run(PkgApp.new,
  title: "egui-cr — TableView (Synaptic-style package list)",
  width: 1100, height: 700)
