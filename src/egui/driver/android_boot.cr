# Android bootstrap (ANDROID_SUPPORT_PLAN.md): sokol_app on Android owns
# ANativeActivity_onCreate; its event loop runs on its own thread and
# delivers init/frame/event/cleanup callbacks there. The shim's
# sh_init_cb — the first code sokol runs on that thread — calls
# egui_cr_android_boot before anything else, so the Crystal runtime
# (scheduler fiber TLS, GC thread registration) binds to the thread every
# callback will run on (same pattern as android-ndk.cr's android_main).
# The boot runs the normal Crystal program startup (GC.init, scheduler,
# at_exit) — the user's top-level code calls Sokol.run, whose
# egui_cr_sapp_run registers the callbacks in the shim and returns
# without entering any loop.

{% if flag?(:android) %}
  fun egui_cr_android_boot : Void
    GC.init
    # Under ndk_translation (arm64 apps on x86_64 emulators) Boehm cannot
    # see the guest stack/register roots — every collection frees live
    # objects (nondeterministic NULL crashes). Detect the translator and
    # disable automatic collection BEFORE init_runtime: that allocates
    # (thread pool, fiber stacks) and a collection in that window is what
    # reliably crashes the process. On real arm64 devices the roots are
    # native and the GC stays on (see ANDROID_SUPPORT_PLAN.md).
    # File.exists? is safe here — a stat, no Crystal IO machinery (there
    # is no execution context before __crystal_main: File.read raises
    # NilAssertionError pre-main) and no allocation pressure.
    translated = File.exists?("/system/lib64/libndk_translation.so") ||
                  File.exists?("/system/lib/libndk_translation.so")
    GC.disable if translated
    Crystal.init_runtime
    # A valid argv is REQUIRED: the compiler initializes ARGC_UNSAFE /
    # ARGV_UNSAFE from __crystal_main's parameters, and the lazily-built
    # PROGRAM_NAME / ARGV constants dereference them on first use — with
    # (0, null) that is a NULL deref (SEGV) or an ArgumentError from
    # Array.new(ARGC_UNSAFE - 1). On a normal platform the generated
    # main() does this; a NativeActivity .so has no main.
    prog = "egui_cr"
    argv = Pointer(Pointer(UInt8)).malloc(1)
    argv[0] = prog.to_unsafe
    # __crystal_main directly, NOT Crystal.main: the latter runs at_exit
    # handlers and calls exit() — which would kill the NativeActivity
    # process the moment the top-level code (Sokol.run registration)
    # returns. __crystal_main runs the user code and returns normally;
    # the shim then continues into sokol's event loop on this thread.
    LibCrystalMain.__crystal_main(1, argv)
  end
{% end %}
