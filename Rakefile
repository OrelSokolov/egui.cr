require "fileutils"
require "etc"
require "monitor"

WINDOWS    = Gem.win_platform?
DARWIN     = RUBY_PLATFORM.include?("darwin")
# Render backend for the Linux native lib (see VULKAN.md): "gl" (default,
# GLX through XWayland) or "vulkan" (X11 window + Vulkan swapchain —
# immune to the NVIDIA GLX userspace/kernel skew that breaks
# glXCreateContextAttribsARB after an apt upgrade). macOS (Cocoa/GL) and
# Windows (WGL) stay GL regardless.
#   BACKEND=vulkan rake build:release
BACKEND    = ENV.fetch("BACKEND", "gl").downcase
unless %w[gl vulkan].include?(BACKEND)
  raise "BACKEND must be gl or vulkan (got: #{BACKEND})"
end
if BACKEND == "vulkan" && (WINDOWS || DARWIN)
  raise "BACKEND=vulkan is Linux-only (macOS/Windows have no Vulkan sokol_app path here)"
end
VULKAN     = BACKEND == "vulkan"
# MSVC resolves @[Link("egui_cr_sokol")] to exactly egui_cr_sokol.lib —
# no lib prefix, no -l rewriting like cc (egui_cr_pty.lib likewise).
NATIVE_LIB = WINDOWS ? "lib/egui_cr_sokol.lib" : "lib/libegui_cr_sokol.a"
PTY_LIB    = WINDOWS ? "lib/egui_cr_pty.lib"   : "lib/libegui_cr_pty.a"
# Lottie (rlottie) feature flag — OFF by default: without it the build is
# exactly the pre-Lottie one (no cmake, no vendored C++ tree, no C++
# standard library on the link line). `LOTTIE=1` turns on the rlottie
# shim + archive, adds the `lottie` example and its link flags. The
# vendor tree itself lands via `rake download:rlottie` (network, once).
LOTTIE_FEATURE = ENV["LOTTIE"] == "1"
EXAMPLES   = ["hello", "widgets_gallery", "openfiledialog", "fontpreview", "fontbrowser", "logos", "counter_reactive", "notepad", "notepad_with_exml", "borderless", "splash", "terminal", "win_properties_demo", "box_shadow", "video", "inspector_demo", "icons_browser", "svg_rasterizer", "paint", "system_monitor", "markdown", "mdvsfonts", "formulas", "crystal3d", "rounded_window", "tableview", "text_input", "ios_demo", "multitouch_demo", "responsive_demo", "camera", "device_api", "audio", "remote_image", "tray", "voice_echo"] +
             (LOTTIE_FEATURE ? ["lottie"] : [])

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

# Backend stamp for the sokol shim object: the .o path is shared between
# the gl and vulkan builds, and timestamps alone can't see a -D change —
# a flip would silently link the old backend's object into the new
# archive. So a mismatching stamp drops both the stamp and the object,
# forcing a full recompile/re-archive through the normal file rules.
NATIVE_BACKEND_STAMP = "lib/.native-backend"
stamped = begin
  File.read(NATIVE_BACKEND_STAMP).strip
rescue StandardError
  nil
end
if stamped != BACKEND
  # drop the archive too: nothing may link a stale object of the OTHER
  # backend (build:dev/spec would otherwise silently pick it up)
  FileUtils.rm_f([NATIVE_BACKEND_STAMP, "lib/sokol_shim#{OBJ_EXT}", NATIVE_LIB])
end
file NATIVE_BACKEND_STAMP do
  FileUtils.mkdir_p("lib")
  File.write(NATIVE_BACKEND_STAMP, BACKEND)
end

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

# LOTTIE=1: the rlottie C shim (needs the vendored upstream tree). Its
# archive is separate — like the PTY lib, so apps that never require
# "egui/backend/rlottie" link no C++ runtime.
if LOTTIE_FEATURE
  SHIM_HEADERS["rlottie_shim"] = %w[
    vendor/rlottie/inc/rlottie_capi.h
    vendor/rlottie/inc/rlottiecommon.h
  ]
end

SHIM_HEADERS.each do |shim, headers|
  obj = "lib/#{shim}#{OBJ_EXT}"
  # the backend stamp gates the sokol shim: a BACKEND flip recompiles it
  prereqs = ["backend/#{shim}.c"] + headers
  prereqs << NATIVE_BACKEND_STAMP if shim == "sokol_shim"
  file obj => prereqs do
    FileUtils.mkdir_p("lib")
    if WINDOWS
      includes = case shim
        when "sokol_shim"        then "/Ivendor\\sokol /Ivendor\\fontstash /Ivendor"
        when "nanosvg_shim"      then "/Ivendor\\nanosvg"
        when "rlottie_shim"      then "/Ivendor\\rlottie\\inc"
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
          "#{DARWIN ? "-x objective-c" : ""} -Ivendor/sokol -Ivendor/fontstash -Ivendor" \
          "#{" -DSOKOL_VULKAN" if VULKAN}"
        when "nanosvg_shim"      then "-Ivendor/nanosvg"
        when "rlottie_shim"      then "-Ivendor/rlottie/inc"
        else ""
      end
      sh "cc -O2 #{args} -c backend/#{shim}.c -o #{obj}"
    end
  end
end

# Which shim objects go into which archive. The PTY shim gets its own
# library so terminal embedders that never open a window link no
# sokol/GL/X11; nanosvg stays with sokol (sokol.cr itself requires it
# as the dev-only C rasterizer behind C_EXTENSIONS). Audio playback
# lives in the minaudio shard (lib/minaudio after `shards install`) —
# see the build:minaudio task below.
# The rlottie shim archive (LOTTIE=1): its own library so embedders
# that never require "egui/backend/rlottie" link no C++ runtime — the
# egui_cr_pty split applied to Lottie.
RLOTTIE_LIB = WINDOWS ? "lib/egui_cr_rlottie.lib" : "lib/libegui_cr_rlottie.a"
ARCHIVES = {
  NATIVE_LIB => %w[sokol_shim nanosvg_shim],
  PTY_LIB    => %w[pty_shim],
}
ARCHIVES[RLOTTIE_LIB] = %w[rlottie_shim] if LOTTIE_FEATURE

# minaudio.cr's static library (SystemPorts::Audio). Built by the
# shard's own Rakefile from its vendored single-header C; apps opt in
# with require "egui/backend/audio", the @[Link] attributes live in
# the shard. Plain `rake` there is incremental, so this is cheap.
MINAUDIO_LIB = "lib/minaudio/lib/libminaudio.a"
file MINAUDIO_LIB do
  sh "cd lib/minaudio && rake build"
end

# The upstream rlottie static library (LOTTIE=1), built by its own
# CMake from vendor/rlottie. Threads/cache off: render() runs
# synchronously on the UI thread and memoization lives on the Crystal
# side (the NanoSvgCr pattern). Artifact copied to a fixed path so the
# @[Link("rlottie")] + -Llib/rlottie link line never depends on the
# generator's layout (single-config Makefiles/Ninja put it directly in
# the build dir, multi-config ones under Release/).
RLOTTIE_A = WINDOWS ? "lib/rlottie/rlottie.lib" : "lib/rlottie/librlottie.a"
file RLOTTIE_A => ["backend/rlottie_stb_glue.c"] do
  unless File.directory?("vendor/rlottie")
    raise "vendor/rlottie missing — run `rake download:rlottie` first"
  end
  FileUtils.mkdir_p("lib/rlottie")
  built = WINDOWS ? "lib/rlottie/build/rlottie.lib" : nil
  if WINDOWS
    # Static rlottie defaults to /MT (CMakeLists), but the rest of the
    # vendor code is /MD — match it to avoid the LNK4098 two-CRT clash.
    msvc("cmake -G \"NMake Makefiles\" -S vendor\\rlottie -B lib\\rlottie\\build " \
         "-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DLOTTIE_MODULE=OFF " \
         "-DLOTTIE_THREAD=OFF -DLOTTIE_CACHE=OFF -DLOTTIE_TEST=OFF " \
         "-DCMAKE_CXX_FLAGS_RELEASE=\"/MD\" && " \
         "cmake --build lib\\rlottie\\build --target rlottie")
    # Strip rlottie's embedded jpeg/png-only stb_image (sokol_shim.obj
    # carries the full build — duplicate symbols otherwise) and splice
    # in the forwarding glue (backend/rlottie_stb_glue.c).
    msvc("cl /nologo /O2 /MD /std:c11 /c backend\\rlottie_stb_glue.c " \
         "/Fo#{File.join('lib', 'rlottie_stb_glue.obj').tr('/', '\\')} && " \
         "lib /nologo /REMOVE:stb_image.cpp.o lib\\rlottie\\build\\rlottie.lib")
    FileUtils.cp(built, RLOTTIE_A)
    sh "lib /nologo #{RLOTTIE_A.tr('/', '\\')} #{File.join('lib', 'rlottie_stb_glue.obj').tr('/', '\\')}"
  else
    # -U__ARM_NEON__: rlottie's arm64 path is broken upstream — the
    # NEON C++ helper (vdrawhelper_neon.cpp) calls 32-bit-only pixman
    # asm that its CMake never assembles (the guard variable ARCH is
    # set nowhere), and the asm itself is .arch armv7a anyway. Undefine
    # __ARM_NEON__ for the whole library so the generic draw helpers in
    # vdrawhelper.cpp compile in instead (their #if matches).
    sh "cmake -S vendor/rlottie -B lib/rlottie/build -DCMAKE_BUILD_TYPE=Release " \
       "-DBUILD_SHARED_LIBS=OFF -DLOTTIE_MODULE=OFF -DLOTTIE_THREAD=OFF " \
       "-DLOTTIE_CACHE=OFF -DLOTTIE_TEST=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 " \
       "-DCMAKE_CXX_FLAGS=\"-U__ARM_NEON__\""
    sh "cmake --build lib/rlottie/build --target rlottie"
    built = Dir.glob("lib/rlottie/build/**/librlottie.a").first
    # Strip rlottie's embedded jpeg/png-only stb_image — sokol_shim.o
    # already carries the full build, and the duplicate stbi_* symbols
    # are a hard error for Mach-O ld. The glue object re-provides
    # rlottie's lottie_image_* entry points by forwarding to the sokol
    # shim's stb (so GIF/PIC-bearing lotties decode too).
    sh "cc -O2 -c backend/rlottie_stb_glue.c -o lib/rlottie_stb_glue.o"
    sh "ar d #{built} stb_image.cpp.o"
    sh "ar r #{built} lib/rlottie_stb_glue.o"
    FileUtils.cp(built, RLOTTIE_A)
  end
end

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

desc "Build vendor C code into #{NATIVE_LIB} (sokol) + #{PTY_LIB} (pty shim) + minaudio shard lib"
task "build:native" => ARCHIVES.keys + [MINAUDIO_LIB] + (LOTTIE_FEATURE ? [RLOTTIE_A] : [])

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
  # lib/minaudio/lib: the audio shard's static lib (only pulled in when
  # an example requires "egui/backend/audio" — its @[Link] does the rest).
  ma_dir = File.join(libdir, "minaudio", "lib")
  lib_flag = WINDOWS ? "/LIBPATH:#{libdir} /LIBPATH:#{ma_dir}" : "-L#{libdir} -L#{ma_dir}"
  # GNU ld.bfd resolves a static archive's undefined symbols (X11, GL,
  # vulkan) only from libraries placed AFTER it, but Crystal emits the
  # @[Link("egui_cr_sokol")] -l flag after the -lX11/-lGL group — so the
  # archive is passed explicitly, before the shared libs. The later -l
  # stays harmless: its members are already pulled in by then.
  if !WINDOWS && !DARWIN
    lib_flag = "#{File.expand_path(NATIVE_LIB)} #{lib_flag}"
  end
  if LOTTIE_FEATURE
    # lib/rlottie: upstream librlottie.a + the C++ standard library it
    # needs (rlottie itself is -fno-exceptions -fno-rtti, but std::vector
    # / std::string still pull the runtime). Only the lottie example's
    # @[Link]s actually drag the archive in.
    lib_flag += " /LIBPATH:#{File.join(libdir, 'rlottie')}" if WINDOWS
    lib_flag += " -L#{File.join(libdir, 'rlottie')}" unless WINDOWS
    lib_flag += DARWIN ? " -lc++" : " -lstdc++" unless WINDOWS
  end
  if DARWIN
    # sokol_app needs the Cocoa/OpenGL frameworks; FreeType lives in the
    # brew prefix (-L only — @[Link("freetype")] already adds -lfreetype).
    # AVFoundation/CoreMedia: the shim's camera section (one big object)
    # references them, so every macOS example link pulls them in.
    ft_libs = %x{pkg-config --libs-only-L freetype2 2>/dev/null}.strip
    ft_libs = "-L/opt/homebrew/lib" if ft_libs.empty?
    lib_flag = "#{lib_flag} #{ft_libs} -framework Cocoa " \
               "-framework OpenGL -framework QuartzCore " \
               "-framework AVFoundation -framework CoreMedia " \
               "-framework IOKit"
  end
  # Vulkan backend (BACKEND=vulkan, Linux): sokol_app calls into
  # libvulkan directly — every example link needs it.
  lib_flag = "#{lib_flag} -lvulkan" if VULKAN
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
task "build:dev", [:name] => ["build:native"] do |_, args|
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

desc "Vendor rlottie (Samsung, MIT — animated vector/Lottie player) for LOTTIE=1 builds"
task "download:rlottie" do
  src = "/tmp/rlottie-src"
  FileUtils.rm_rf(src)
  system("git", "clone", "--no-checkout", "https://github.com/Samsung/rlottie.git", src) or abort "clone failed"
  # Pinned master commit — see vendor/VENDORED.md.
  system("git", "-C", src, "checkout", "--detach",
    "ea06d2f29ba01b8d06c00a838d107f5e484ae59b") or abort "checkout failed"
  dest = "vendor/rlottie"
  FileUtils.rm_rf(dest)
  FileUtils.mkdir_p(dest)
  # What the CMake build reaches: example/ is referenced by the root
  # CMakeLists (add_subdirectory), test/wasm are not. .git stays behind.
  %w[CMakeLists.txt cmake inc src example rlottie.pc.in rlottie.expmap
     LICENSE README.md]
    .each { |e| p = File.join(src, e); FileUtils.cp_r(p, dest) if File.exist?(p) }
  puts "vendor/rlottie: populated @ ea06d2f (MIT)"
end

desc "Run the spec suite (headless — no GPU needed)"
task spec: ["build:native"] do
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
