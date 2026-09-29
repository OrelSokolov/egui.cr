require "fileutils"
require "etc"
require "monitor"

WINDOWS    = Gem.win_platform?
DARWIN     = RUBY_PLATFORM.include?("darwin")
# MSVC resolves @[Link("egui_cr_sokol")] to exactly egui_cr_sokol.lib —
# no lib prefix, no -l rewriting like cc.
NATIVE_LIB = WINDOWS ? "lib/egui_cr_sokol.lib" : "lib/libegui_cr_sokol.a"
EXAMPLES   = ["hello", "widgets_gallery", "openfiledialog", "fontpreview", "logos", "counter_reactive", "notepad", "borderless", "splash", "terminal", "win_properties_demo", "box_shadow", "video", "inspector_demo", "lucide_icons"]

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
  "stb_truetype_shim" => %w[vendor/fontstash/stb_truetype.h],
  "pty_shim" => [],
}

SHIM_HEADERS.each do |shim, headers|
  obj = "lib/#{shim}#{OBJ_EXT}"
  file obj => ["backend/#{shim}.c"] + headers do
    FileUtils.mkdir_p("lib")
    if WINDOWS
      includes = case shim
        when "sokol_shim"        then "/Ivendor\\sokol /Ivendor\\fontstash /Ivendor"
        when "stb_truetype_shim" then "/Ivendor\\fontstash"
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
        when "stb_truetype_shim" then "-Ivendor/fontstash"
        else ""
      end
      sh "cc -O2 #{args} -c backend/#{shim}.c -o #{obj}"
    end
  end
end

shim_objs = SHIM_HEADERS.keys.map { |shim| "lib/#{shim}#{OBJ_EXT}" }
file NATIVE_LIB => shim_objs do
  FileUtils.mkdir_p("lib")
  if WINDOWS
    # FreeType import lib + dll (scripts/fetch_freetype.bat is a no-op
    # once lib/freetype.lib and bin/freetype.dll are in place).
    sh "scripts\\fetch_freetype.bat"
    msvc("lib /nologo /OUT:#{NATIVE_LIB.tr('/', '\\')} #{shim_objs.join(' ').tr('/', '\\')}")
  else
    sh "ar rcs #{NATIVE_LIB} #{shim_objs.join(' ')}"
  end
end

desc "Build vendor C code (sokol_app/gfx/glue/gl + fontstash) into #{NATIVE_LIB}"
task "build:native" => NATIVE_LIB

desc "Build all examples into bin/"
task "build:examples" => ["build:native"] do
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
  # Parallel builds: a `crystal build --release` is effectively one CPU
  # (frontend + LLVM opt run in one process), so N concurrent compilers
  # scale ~N wall-clock. Capped at 8 to bound peak RAM (~1-2 GB each);
  # override with JOBS=.
  jobs = Integer(ENV.fetch("JOBS", [Etc.nprocessors, 8].min))
  # --release: these are the shipped demo binaries; a debug build is
  # 10-100x slower (the notepad-on-big-files lesson).
  # One cache slot per worker: concurrent `crystal build` processes race on
  # the shared ~/.cache/crystal (tmp-file renames), so each gets its own
  # persistent CRYSTAL_CACHE_DIR (.crystal-cache/jN, reused across runs).
  queue = EXAMPLES.dup
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
        puts "▶ crystal build #{name}"
        cmd = "crystal build examples/#{name}.cr -o bin/#{name} --release --link-flags \"#{lib_flag}\""
        unless system(env, cmd)
          lock.synchronize { failures << name }
        end
      end
    end
  end.each(&:join)
  raise "example build failed: #{failures.sort.join(', ')}" unless failures.empty?
end

# Debug build for iteration: same link flags as build:examples but without
# --release, so codegen is parallel and ~3x faster to compile (the release
# LLVM -O3 pass runs single-threaded over the whole ~22k-line src/egui).
# Runtime is 10-100x slower — for shipped binaries use build:examples.
#   rake build:dev[hello]       # one example
#   rake build:dev              # all examples
desc "Build example(s) into bin/ without --release (fast iteration)"
task "build:dev", [:name] do |_, args|
  names = args[:name] ? [args[:name]] : EXAMPLES
  unknown = names - EXAMPLES
  raise "unknown example(s): #{unknown.sort.join(', ')}" unless unknown.empty?
  FileUtils.mkdir_p("bin")
  libdir = File.expand_path("lib")
  lib_flag = WINDOWS ? "/LIBPATH:#{libdir}" : "-L#{libdir}"
  if DARWIN
    ft_libs = %x{pkg-config --libs-only-L freetype2 2>/dev/null}.strip
    ft_libs = "-L/opt/homebrew/lib" if ft_libs.empty?
    lib_flag = "#{lib_flag} #{ft_libs} -framework Cocoa " \
               "-framework OpenGL -framework QuartzCore"
  end
  # Same worker-pool shape as build:examples: concurrent compilers scale
  # ~N wall-clock, each with its own persistent CRYSTAL_CACHE_DIR to avoid
  # races on the shared cache.
  jobs = Integer(ENV.fetch("JOBS", [Etc.nprocessors, names.size, 8].min))
  queue = names.dup
  queue.extend(MonitorMixin)
  failures = []
  lock = Thread::Mutex.new
  Array.new(jobs) do |i|
    Thread.new do
      cache = File.expand_path(".crystal-cache/j#{i % 8}")
      env = {"CRYSTAL_CACHE_DIR" => cache}
      loop do
        name = queue.synchronize { queue.empty? ? nil : queue.shift }
        break unless name
        puts "▶ crystal build #{name} (dev)"
        cmd = "crystal build examples/#{name}.cr -o bin/#{name} --link-flags \"#{lib_flag}\""
        unless system(env, cmd)
          lock.synchronize { failures << name }
        end
      end
    end
  end.each(&:join)
  raise "example build failed: #{failures.sort.join(', ')}" unless failures.empty?
end

desc "Run the spec suite (headless — no GPU needed)"
task :spec do
  sh "crystal spec"
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
