require "../../src/egui"

# ═══ BACKEND ПРИЛОЖЕНИЯ ═══════════════════════════════════════════════
# MVC-разрез tableview (plans/frontend-backend-split.md фаза 4; анализ —
# plans/mvc-examples-analysis.md §tableview): модель-ресурс Package +
# репозиторий + `resources "packages"` 1:1. Файл driver-free: его
# гоняют и пример (examples/tableview.cr), и спеки напрямую.

# Модель-ресурс + демо-репозиторий (в памяти; реальное приложение
# держит ORM/файлы — фреймворку безразлично, Model — внешний слой).
class PkgRepo
  class Package
    property status : String
    property name : String
    property installed : String
    property available : String
    property size : Int32
    property section : String

    def initialize(@status, @name, @installed, @available, @size,
                   @section)
    end

    # Строка ответа index — ровно колонки ListStore фронтенда.
    def to_row : JSON::Any
      Egui::Mvc.to_json_any(
        [@status, @name, @installed, @available, @size, @section])
    end
  end

  @@packages = [] of Package
  @@seeded = false

  def self.packages : Array(Package)
    seed! unless @@seeded
    @@packages
  end

  def self.find(name : String) : Package?
    packages.find { |p| p.name == name }
  end

  # Спеки гоняют сценарии на чистых данных.
  def self.reset! : Nil
    @@packages.clear
    @@seeded = false
  end

  # Бизнес-правило пакета (вызывается только контроллером): install
  # берёт available-версию, remove чистит installed, toggle смотрит на
  # текущий статус. Возвращает сообщение для статус-строки.
  def self.apply_action(pkg : Package, action : String) : String
    case action
    when "remove"
      pkg.status = "not installed"
      pkg.installed = ""
      "Removed #{pkg.name}"
    when "upgrade", "install"
      pkg.status = "installed"
      pkg.installed = pkg.available
      "Installed #{pkg.name}"
    else # toggle — как исходный double-click
      if pkg.status == "installed"
        pkg.status = "not installed"
        pkg.installed = ""
        "Removed #{pkg.name}"
      else
        pkg.status = "installed"
        pkg.installed = pkg.available
        "Installed #{pkg.name}"
      end
    end
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

  # Tiny version string helpers (demo data generator, not the point).
  module Ver
    def self.gen(rng : Random) : String
      "#{rng.rand(3) + 1}#{('a'..'z').to_a[rng.rand(26)]}"
    end

    def self.bump(base : String, rng : Random) : String
      "#{base}.#{rng.rand(9) + 1}~backport"
    end
  end

  def self.seed! : Nil
    return if @@seeded
    rng = Random.new(42)
    NAMES.each do |name|
      roll = rng.rand
      installed = roll < 0.35
      upgradable = installed && rng.rand < 0.3
      broken = roll > 0.97
      status = broken ? "broken" : upgradable ? "upgradable" :
               installed ? "installed" : "not installed"
      ver = "#{rng.rand(8) + 1}.#{rng.rand(20)}.#{rng.rand(10)}"
      @@packages << Package.new(status, "#{name}-#{Ver.gen(rng)}",
        installed ? ver : "",
        upgradable ? Ver.bump(ver, rng) : ver,
        (rng.rand(90_000) + 24).to_i32,
        SECTIONS[rng.rand(SECTIONS.size)])
    end
    @@seeded = true
  end
end

# Контроллер ресурса: `resources "packages"` 1:1. Инстанс живёт один
# запрос (роутер аллоцирует через .allocate) — состояние только в
# репозитории. Бизнес-правила здесь, не в кнопках: install берёт
# available-версию, remove чистит installed.
class PackagesController < Egui::Mvc::Controller
  # GET /packages?search=needle — вся (отфильтрованная) таблица:
  # ListStore фронтенда — одноразовый кэш этого ответа.
  def index(request)
    search = (request.query["search"]? || "").strip.downcase
    rows = PkgRepo.packages.select do |p|
      search.empty? || p.name.downcase.includes?(search)
    end
    {"search" => search,
     "total"  => PkgRepo.packages.size,
     "rows"   => rows.map(&.to_row)}
  end

  # PATCH /packages/:id — действие над одним пакетом (двойной клик).
  def update(request)
    pkg = PkgRepo.find(request.params["id"])
    return Egui::Mvc::Response.new(404, Egui::Mvc::EMPTY_BODY) unless pkg
    action = request.body["action"]?.try(&.as_s) || "toggle"
    {"message" => PkgRepo.apply_action(pkg, action)}
  end

  # POST /packages/bulk — массовое действие над выделением.
  def bulk(request)
    action = request.body["action"]?.try(&.as_s) || "install"
    names = (request.body["names"]? ||
             JSON::Any.new([] of JSON::Any)).as_a
    count = 0
    names.each do |n|
      if (pkg = PkgRepo.find(n.as_s))
        PkgRepo.apply_action(pkg, action)
        count += 1
      end
    end
    {"message" => "#{count} package#{count == 1 ? "" : "s"} updated"}
  end

  actions
end

PKG_ROUTES = Egui::Mvc::Router.new.draw do |r|
  r.resources "/packages", PackagesController
  r.post "/packages/bulk", PackagesController, "bulk"
end
