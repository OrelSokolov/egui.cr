require "fileutils"

WINDOWS    = Gem.win_platform?
DARWIN     = RUBY_PLATFORM.include?("darwin")
# MSVC resolves @[Link("egui_cr_sokol")] to exactly egui_cr_sokol.lib —
# no lib prefix, no -l rewriting like cc.
NATIVE_LIB = WINDOWS ? "lib/egui_cr_sokol.lib" : "lib/libegui_cr_sokol.a"
EXAMPLES   = ["hello", "widgets_gallery", "openfiledialog", "fontpreview"]

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

desc "Build vendor C code (sokol_app/gfx/glue/gl + fontstash) into #{NATIVE_LIB}"
task "build:native" do
  FileUtils.mkdir_p("lib")
  if WINDOWS
    msvc(
      # /MD: match Crystal's windows-msvc binaries (dynamic CRT) — avoids
      # the LNK4098 LIBCMT clash and two-CRT havoc at runtime.
      "cl /nologo /O2 /MD /std:c11 /c backend\\sokol_shim.c " \
      "/Ivendor\\sokol /Ivendor\\fontstash /Ivendor /Folib\\sokol_shim.obj && " \
      "cl /nologo /O2 /MD /std:c11 /c backend\\stb_truetype_shim.c " \
      "/Ivendor\\fontstash /Folib\\stb_truetype_shim.obj && " \
      "lib /nologo /OUT:#{NATIVE_LIB.tr('/', '\\')} " \
      "lib\\sokol_shim.obj lib\\stb_truetype_shim.obj"
    )
  else
    # macOS: sokol_app's backend is Objective-C (Cocoa/NSOpenGL), so the
    # shim must be compiled as ObjC even though it is a .c file.
    shim_lang = DARWIN ? "-x objective-c" : ""
    sh <<-SH
      cc -O2 #{shim_lang} -c backend/sokol_shim.c \
        -Ivendor/sokol \
        -Ivendor/fontstash \
        -Ivendor \
        -o lib/sokol_shim.o
    SH
    sh <<-SH
      cc -O2 -c backend/stb_truetype_shim.c \
        -Ivendor/fontstash \
        -o lib/stb_truetype_shim.o
    SH
    sh "ar rcs #{NATIVE_LIB} lib/sokol_shim.o lib/stb_truetype_shim.o"
  end
end

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
  EXAMPLES.each do |name|
    sh "crystal build examples/#{name}.cr -o bin/#{name} --link-flags \"#{lib_flag}\""
  end
end

desc "Run the spec suite (headless — no GPU needed)"
task :spec do
  sh "crystal spec"
end

task default: ["build:examples"]
