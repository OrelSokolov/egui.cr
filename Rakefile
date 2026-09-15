require "fileutils"

NATIVE_LIB = "lib/libegui_cr_sokol.a"
EXAMPLES   = ["hello", "widgets_gallery", "openfiledialog"]

desc "Build vendor C code (sokol_app/gfx/glue/gl + fontstash) into #{NATIVE_LIB}"
task "build:native" do
  FileUtils.mkdir_p("lib")
  sh <<-SH
    cc -O2 -c backend/sokol_shim.c \
      -Ivendor/sokol \
      -Ivendor/fontstash \
      -Ivendor \
      -o lib/sokol_shim.o
  SH
  sh "ar rcs #{NATIVE_LIB} lib/sokol_shim.o"
end

desc "Build all examples into bin/"
task "build:examples" => ["build:native"] do
  FileUtils.mkdir_p("bin")
  libdir = File.expand_path("lib")
  EXAMPLES.each do |name|
    sh "crystal build examples/#{name}.cr -o bin/#{name} --link-flags '-L#{libdir}'"
  end
end

desc "Run the spec suite (headless — no GPU needed)"
task :spec do
  sh "crystal spec"
end

task default: ["build:examples"]
