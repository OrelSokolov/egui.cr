require "fileutils"
require "etc"
require "monitor"

WINDOWS    = Gem.win_platform?
DARWIN     = RUBY_PLATFORM.include?("darwin")
# MSVC resolves @[Link("egui_cr_sokol")] to exactly egui_cr_sokol.lib —
# no lib prefix, no -l rewriting like cc (egui_cr_pty.lib likewise).
NATIVE_LIB = WINDOWS ? "lib/egui_cr_sokol.lib" : "lib/libegui_cr_sokol.a"
PTY_LIB    = WINDOWS ? "lib/egui_cr_pty.lib"   : "lib/libegui_cr_pty.a"
EXAMPLES   = ["hello", "widgets_gallery", "openfiledialog", "fontpreview", "fontbrowser", "logos", "counter_reactive", "notepad", "borderless", "splash", "terminal", "win_properties_demo", "box_shadow", "video", "inspector_demo", "icons_browser", "svg_rasterizer", "paint", "system_monitor", "markdown", "mdvsfonts", "formulas", "crystal3d", "rounded_window"]

# Run `script` (cl/lib) inside the MSVC x64 environment. Crystal's
# windows-msvc target links against the MSVC/Windows-SDK runtimes, so the
# vendor C code must be built with cl.exe too — not MinGW gcc.
def msvc(script)
  vswhere = "C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe"
  unless File.exist?(vswhere)
    raise "vswhere.exe not found — install Visual Studio 2022 (or its Build " \
          "Tools) with the \"Desktop development with C++\" workload"
  end
  vs = %x{"#{vswhere}" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath}.strip
  raise "MSVC C++ tools not found (vswhere returned nothing)" if vs.empty?
  vcvars = File.join(vs, "VC", "Auxiliary", "Build", "vcvars64.bat")
  sh %Q{cmd /c ""#{vcvars}" >nul && #{script}"}
end

# Incremental native build: each shim object rebuilds only when its .c or
# the vendor headers it includes change, and the archive only when an
# object does. Plain tasks here would recompile everything on every
# `rake build:native` / `rake build:examples` (the latter depends on the
# former — crosspack runs both, so the shims were built twice per run).
OBJ_EXT = WINDOWS ? ".obj" : ".o"

# Headers each shim pulls in (see its #include block) — an edited vendor
# header must trigger a recompile, not just an edited backend/*.c.
SHIM_HEADERS = {
  "sokol_shim" => %w[
    vendor/sokol/sokol_app.h
    vendor/sokol/sokol_gfx.h
    vendor/sokol/sokol_glue.h
    vendor/sokol/sokol_log.h
    vendor/sokol/util/sokol_gl.h
    vendor/fontstash/fontstash.h
    vendor/stb_image.h
    vendor/sokol/util/sokol_fontstash.h
  ],
  "nanosvg_shim" => %w[
    vendor/nanosvg/nanosvg.h
    vendor/nanosvg/nanosvgrast.h
  ],
  "pty_shim" => [],
}

SHIM_HEADERS.each do |shim, headers|
  obj = "lib/#{shim}#{OBJ_EXT}"
  file obj => ["backend/#{shim}.c"] + headers do
    FileUtils.mkdir_p("lib")
    if WINDOWS
      includes = case shim
        when "sokol_shim"        then "/Ivendor\\sokol /Ivendor\\fontstash /Ivendor"
        when "nanosvg_shim"      then "/Ivendor\\nanosvg"
        else ""
      end
      msvc(
        # /MD: match Crystal's windows-msvc binaries (dynamic CRT) — avoids
        # the LNK4098 LIBCMT clash and two-CRT havoc at runtime.
        "cl /nologo /O2 /MD /std:c11 /c backend\\#{shim}.c #{includes} " \
        "/Fo#{obj.tr('/', '\\')}"
      )
    else
      # macOS: sokol_app's backend is Objective-C (Cocoa/NSOpenGL), so the
      # shim must be compiled as ObjC even though it is a .c file.
      args = case shim
        when "sokol_shim"
          "#{DARWIN ? "-x objective-c" : ""} -Ivendor/sokol -Ivendor/fontstash -Ivendor"
        when "nanosvg_shim"      then "-Ivendor/nanosvg"
        else ""
      end
      sh "cc -O2 #{args} -c backend/#{shim}.c -o #{obj}"
    end
  end
end

# Which shim objects go into which archive. The PTY shim gets its own
# library so terminal embedders that never open a window link no
# sokol/GL/X11; nanosvg stays with sokol (sokol.cr itself requires it
# as the dev-only C rasterizer behind C_EXTENSIONS).
ARCHIVES = {
  NATIVE_LIB => %w[sokol_shim nanosvg_shim],
  PTY_LIB    => %w[pty_shim],
}

ARCHIVES.each do |lib, shims|
  objs = shims.map { |shim| "lib/#{shim}#{OBJ_EXT}" }
  file lib => objs do
    FileUtils.mkdir_p("lib")
    # Recreate from scratch: `ar rcs` only adds/replaces members, so a
    # dropped shim would linger in an existing archive forever.
    FileUtils.rm_f(lib)
    if WINDOWS
      if lib == NATIVE_LIB
        # FreeType import lib + dll (scripts/fetch_freetype.bat is a no-op
        # once lib/freetype.lib and bin/freetype.dll are in place).
        sh "scripts\\fetch_freetype.bat"
      end
      msvc("lib /nologo /OUT:#{lib.tr('/', '\\')} #{objs.join(' ').tr('/', '\\')}")
    else
      sh "ar rcs #{lib} #{objs.join(' ')}"
    end
  end
end

desc "Build vendor C code into #{NATIVE_LIB} (sokol) + #{PTY_LIB} (pty shim)"
task "build:native" => ARCHIVES.keys

# Warm ONE compiler cache with a single small build, then clone it into
# every empty worker slot. On a fresh clone (or after a cache wipe) the
# parallel build would otherwise compile the whole dependency tree —
# egui core + the nanosvg shard — once PER WORKER (~30s each, release).
# The C shim's compile-once-.o analogy, done with CRYSTAL_CACHE_DIR:
# the warm-up pays the full compile once, the workers then mostly link
# (a cold logos build is ~30s, a warm one ~4s). No-op when every slot
# is already populated.
def warm_compiler_caches(jobs, opt_flags, lib_flag)
  slots = (0...jobs).map { |i| File.expand_path(".crystal-cache/j#{i % 8}") }
  return if slots.all? { |d| Dir.exist?(d) && !Dir.empty?(d) }
  warm = slots.first
  puts "▶ cache warm-up (hello, #{opt_flags.empty? ? "dev" : opt_flags.strip})"
  FileUtils.mkdir_p("tmp")
  system({"CRYSTAL_CACHE_DIR" => warm},
    "crystal build examples/hello.cr -o tmp/cache_warm #{opt_flags}--link-flags \"#{lib_flag}\"") or return
  slots.drop(1).each do |dst|
    next if Dir.exist?(dst) && !Dir.empty?(dst) # worker already warm
    FileUtils.rm_rf(dst) # half-empty clone target from an aborted run
    FileUtils.cp_r(warm, dst)
  end
ensure
  FileUtils.rm_f("tmp/cache_warm")
end

# Shared worker-pool build: concurrent `crystal build` processes scale
# ~N wall-clock (a --release build is effectively one CPU — frontend +
# LLVM opt run in one process), each with its own persistent
# CRYSTAL_CACHE_DIR (.crystal-cache/jN, reused across runs): concurrent
# compilers race on the shared ~/.cache/crystal (tmp-file renames).
# opt_flags: "" (dev), "-O3 " (optimized iteration), "--release ".
def build_examples(names, opt_flags, label)
  FileUtils.mkdir_p("bin")
  libdir = File.expand_path("lib")
  # MSVC Crystal resolves library search dirs from /LIBPATH:, not -L.
  lib_flag = WINDOWS ? "/LIBPATH:#{libdir}" : "-L#{libdir}"
  if DARWIN
    # sokol_app needs the Cocoa/OpenGL frameworks; FreeType lives in the
    # brew prefix (-L only — @[Link("freetype")] already adds -lfreetype).
    ft_libs = %x{pkg-config --libs-only-L freetype2 2>/dev/null}.strip
    ft_libs = "-L/opt/homebrew/lib" if ft_libs.empty?
    lib_flag = "#{lib_flag} #{ft_libs} -framework Cocoa " \
               "-framework OpenGL -framework QuartzCore"
  end
  # Capped at 8 to bound peak RAM (~1-2 GB per compiler); override with JOBS=.
  jobs = Integer(ENV.fetch("JOBS", [Etc.nprocessors, names.size, 8].min))
  warm_compiler_caches(jobs, opt_flags, lib_flag)
  queue = names.dup
  queue.extend(MonitorMixin) # pop from worker threads
  failures = []
  lock = Thread::Mutex.new
  Array.new(jobs) do |i|
    Thread.new do
      cache = File.expand_path(".crystal-cache/j#{i % 8}")
      env = {"CRYSTAL_CACHE_DIR" => cache}
      loop do
        name = queue.synchronize { queue.empty? ? nil : queue.shift }
        break unless name
        puts "▶ crystal build #{name}#{label.empty? ? "" : " (#{label})"}"
        cmd = "crystal build examples/#{name}.cr -o bin/#{name} #{opt_flags}--link-flags \"#{lib_flag}\""
        unless system(env, cmd)
          lock.synchronize { failures << name }
        end
      end
    end
  end.each(&:join)
  raise "example build failed: #{failures.sort.join(', ')}" unless failures.empty?
end

def example_names_for(args)
  names = args[:name] ? [args[:name]] : EXAMPLES
  unknown = names - EXAMPLES
  raise "unknown example(s): #{unknown.sort.join(', ')}" unless unknown.empty?
  names
end

# --release: these are the shipped demo binaries; a debug build is
# 10-100x slower (the notepad-on-big-files lesson).
desc "Build all examples into bin/ (--release)"
task "build:examples" => ["build:native"] do
  build_examples(EXAMPLES, "--release ", "")
end

# Debug build for iteration: same link flags as build:examples but without
# --release, so codegen is parallel and ~3x faster to compile (the release
# LLVM -O3 pass runs single-threaded over the whole ~22k-line src/egui).
# Runtime is 10-100x slower — for shipped binaries use build:release.
# OPT=-O3 is the middle ground ("Optimized iteration" in the README):
# per-unit LLVM opt keeps the shard/stdlib object cache alive across app
# edits (unlike --release's single-module merge), rebuilds stay ~2s while
# running only 2-3x slower than release.
#   rake build:dev[hello]       # one example
#   rake build:dev              # all examples
#   OPT=-O3 rake build:dev      # optimized iteration
desc "Build example(s) into bin/ without --release (fast iteration; OPT=-O3 for optimized)"
task "build:dev", [:name] do |_, args|
  # Empty for dev, e.g. "-O3 " for the optimized-iteration mode; passed to
  # the cache warm-up too — o3 units live under different cache names
  # (*.o3.o), so a dev-warmed slot does not warm them.
  opt = ENV.fetch("OPT", "").strip
  opt = "#{opt} " unless opt.empty?
  build_examples(example_names_for(args), opt, "dev#{opt.empty? ? "" : " #{opt.strip}"}")
end

# Release build scoped to what you need — the same --release path as
# build:examples, but one example when only one binary is wanted
# (a full release sweep is ~30s/warm example, one is ~30s cold).
#   rake build:release          # all examples
#   rake build:release[paint]   # one example
desc "Build example(s) into bin/ with --release (shipped binaries)"
task "build:release", [:name] => ["build:native"] do |_, args|
  build_examples(example_names_for(args), "--release ", "")
end

desc "Run the spec suite (headless — no GPU needed)"
task :spec do
  sh "crystal spec"
end

desc "Refresh icons/bootstrap from upstream (SVG set + MIT license)"
task "download:bootstrap" do
  src = "/tmp/bootstrap-src"
  FileUtils.rm_rf(src)
  system("git", "clone", "--depth", "1", "--filter=blob:none", "--sparse",
    "https://github.com/twbs/icons.git", src) or abort "clone failed"
  system("git", "-C", src, "sparse-checkout", "set", "icons") or abort "sparse checkout failed"
  dest = "icons/bootstrap"
  FileUtils.mkdir_p(dest)
  # Full re-sync: upstream renames/removals must not leave stale SVGs.
  FileUtils.rm(Dir.glob("#{dest}/*.svg"))
  FileUtils.cp(Dir.glob("#{src}/icons/*.svg"), dest)
  FileUtils.cp(File.join(src, "LICENSE"), File.join(dest, "LICENSE"))
  puts "icons/bootstrap: #{Dir.glob("#{dest}/*.svg").size} SVGs refreshed"
end

desc "Refresh icons/lucide from upstream (SVG set + ISC license)"
task "download:lucide" do
  src = "/tmp/lucide-src"
  FileUtils.rm_rf(src)
  system("git", "clone", "--depth", "1", "--filter=blob:none", "--sparse",
    "https://github.com/lucide-icons/lucide.git", src) or abort "clone failed"
  system("git", "-C", src, "sparse-checkout", "set", "icons") or abort "sparse checkout failed"
  dest = "icons/lucide"
  FileUtils.mkdir_p(dest)
  # Full re-sync: upstream renames/removals must not leave stale SVGs.
  FileUtils.rm(Dir.glob("#{dest}/*.svg"))
  FileUtils.cp(Dir.glob("#{src}/icons/*.svg"), dest) # .json sidecars stay behind
  FileUtils.cp(File.join(src, "LICENSE"), File.join(dest, "LICENSE"))
  puts "icons/lucide: #{Dir.glob("#{dest}/*.svg").size} SVGs refreshed"
end

task default: ["build:examples"]
