# Minimal repro for the crystal-lang/crystal bug report (x86_64):
#
#   A `Proc(*T, R)` closure coerced to `Proc(*T, Nil)` (the implicit
#   return-covariance to Nil) keeps its original return convention,
#   but the `.call` site is compiled as if the proc returned nothing:
#
#   * struct of 4 x Float64  -> parts of the return travel on the x87
#     stack (fldl in the callee epilogue); the caller never pops them
#     (no fxch/fstp), leaking 1-2 x87 slots per call. The x87 stack is
#     8 slots deep, so after a handful of calls every later struct
#     return overflows it and reads back QNaN indefinite (0xFFF8...),
#     corrupting unrelated, perfectly finite geometry.
#   * struct with integer fields -> return goes through a hidden sret
#     pointer; the caller does not pass it, shifting every argument by
#     one register (see REPRO_SRET below) -> wrong values or SIGSEGV.
#
# Pure stdlib, deterministic. Expected output: "OK"; actual: "BUG".
#
#   crystal run tmp/crystal_bug_repro.cr            # dev
#   crystal run --release tmp/crystal_bug_repro.cr  # release
#
# Observed with:
#   Crystal 1.21.0 (self-built, LLVM 20.1.8)
#   Crystal 1.22.3 [3462c0774] (official, LLVM 22.1.3)
#   Default target: x86_64-unknown-linux-gnu

struct Quad
  property a : Float64
  property b : Float64
  property c : Float64
  property d : Float64

  def initialize(@a = 0.0, @b = 0.0, @c = 0.0, @d = 0.0)
  end
end

# The struct must cross a real call boundary for the return convention
# to matter; @[NoInline] keeps that from being optimized away.
@[NoInline]
def make_quad(a : Float64, b : Float64, c : Float64, d : Float64) : Quad
  Quad.new(a, b, c, d)
end

# --- repro 1: silent phantom NaN --------------------------------------
# Closures whose bodies implicitly return a Quad, stored as
# Proc(Int32, Nil) — exactly what happens whenever a struct-returning
# block/lambda is handed to a callback typed `Proc(X, Nil)`.
procs = [] of Proc(Int32, Nil)
8.times do
  procs << ->(x : Int32) {
    make_quad(x.to_f64 + 1.0, x.to_f64 + 2.0, x.to_f64 + 3.0, x.to_f64 + 4.0)
  }
end
procs.each_with_index { |proc, i| proc.call(i) }

check = make_quad(10.0, 20.0, 30.0, 40.0)
if check.a.nan? || check.b.nan? || check.c.nan? || check.d.nan?
  puts "BUG (repro 1): phantom NaN — make_quad(10,20,30,40) => #{check}"
else
  puts "OK  (repro 1): #{check}"
end

# Run with ENV REPRO_SRET=1 for the second manifestation (sret):
# an integer-field struct returned through the same Nil-covariance
# makes the callee read arguments shifted by the hidden return buffer,
# i.e. the closure observes wrong parameter values.
# --- repro 2 (run with ENV REPRO_SRET=1): sret argument shift --------
struct IQuad
  property a : Int64
  property b : Int64
  property c : Int64
  property d : Int64

  def initialize(@a = 0_i64, @b = 0_i64, @c = 0_i64, @d = 0_i64)
  end
end

@[NoInline]
def take_quad(x : Int32, y : Int32) : IQuad
  IQuad.new(x.to_i64, y.to_i64, 7_i64, 9_i64)
end

if ENV["REPRO_SRET"]?
  # The closure itself implicitly returns the sret struct; the Nil-typed
  # `.call` site does not pass the hidden return buffer, so the callee
  # reads every argument shifted by one register.
  procs2 = [] of Proc(Int32, Int32, Nil)
  2.times do
    procs2 << ->(x : Int32, y : Int32) { take_quad(x, y) }
  end
  procs2.each_with_index do |proc, i|
    puts "repro 2: call ##{i} — expect args (#{i * 10}, #{i * 10 + 1})"
    proc.call(i * 10, i * 10 + 1)
  end
  puts "OK  (repro 2): survived"
end
