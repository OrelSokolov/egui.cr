# Bug report — crystal-lang/crystal (English version)

Title: **Proc(*T, R) coerced to Proc(*T, Nil): call site doesn't match
the closure's return convention — x87 slots leak (silent NaN) or
arguments shift (SIGSEGV)**

## Environment

- Crystal 1.21.0 [57cf7da50] (2026-07-16), LLVM 20.1.8, self-built
- Crystal 1.22.3 [3462c0774] (2026-11-13), LLVM 22.1.3, official build
- Default target: x86_64-unknown-linux-gnu (Debian, glibc 2.4x)
- Both dev and `--release`

## Summary

A closure whose body returns a struct can be stored into a
`Proc(*T, Nil)` (the implicit return-covariance to `Nil`). The closure
function is compiled with its **real** return type, but the `.call`
site is compiled as if the proc returned nothing. For multi-field
structs the two conventions don't match:

1. **All-float struct (e.g. 4 × Float64): parts of the return travel
   on the x87 stack.** The callee's epilogue pushes st(0)/st(1)
   (`fldl`), the caller — expecting no return value — never pops them
   (`fxch`/`fstp` missing). Each call leaks 1–2 x87 slots; the x87
   stack is 8 slots deep, so after a handful of calls every subsequent
   struct return overflows it and reads back **QNaN indefinite
   (0xFFF8000000000000)** — silent corruption of unrelated, perfectly
   finite values.

2. **Struct returned via a hidden sret pointer (e.g. integer fields):
   the caller doesn't pass the return buffer**, so the callee reads
   every argument shifted by one register — wrong values or SIGSEGV.

Found in the wild as "phantom NaN" geometry crashes in a GUI
framework: a `CASES.each { … render.call(ui, i) }` loop over procs
typed `Proc(Ui, Int32, Nil)` whose bodies implicitly returned a
4×Float64 `Rect` died on the 5th row with
`Rect#width: non-finite value NaN` from finite inputs.

## Impact — why this is nasty to debug

The corruption is **silent and far removed from its cause**. The
leaked x87 slots belong to one function, but the resulting QNaN
indefinite surfaces in *completely unrelated code*: any later function
that returns a multi-field float struct gets `NaN` in some of its
fields — built from provably finite constants (`Rect.new(10.0, 20.0,
30.0, 40.0)` → `NaN, NaN`). To the victim it looks exactly like **a
math bug in whichever function produced the NaN**: you print its
inputs (finite), step through it in a debugger (finite), and it still
returns NaN — because the FPU stack was overflowed several calls
earlier by an unrelated closure. We lost days to this; guards at every
"NaN birthplace" (asserting `finite?` in struct constructors) are the
only way to even localize it, and a full instruction-level gdb session
(fstpl/fldl bookkeeping, x87 tag word) was needed to find the actual
culprit.

## Proposed fix

`proposed_fix_from_GLM.patch` (same directory; written by the GLM
model / H2Code agent — hence the name): reject the void-cast
covariance in `ProcInstanceType#compatible_with?` and in the
`restrict(other : Generic)` Nil-return path when the source return
type is struct-like. This turns the silent corruption into a clear
compile error (`expected argument … to be Proc(…, Nil), not Proc(…,
Quad)`) and keeps every register-safe return (primitives, enums,
unions, pointers, procs, references) working. Verified: compiler
bootstrap, `spec/compiler/semantic/proc_spec.cr` (194 examples), and
both repro variants now fail to compile instead of corrupting. The
proper long-term fix is synthesizing a wrapper closure at the coercion
site (like `Proc(*T, R) → Proc(*T, Nil)` conversion should); the patch
is the conservative stopgap.

## Reproduction

File: `crystal_bug_repro.cr` (same directory; run variant 2 with
`REPRO_SRET=1`). Deterministic, stdlib only.

```crystal
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

procs = [] of Proc(Int32, Nil)
8.times do
  procs << ->(x : Int32) {
    make_quad(x.to_f64 + 1.0, x.to_f64 + 2.0, x.to_f64 + 3.0, x.to_f64 + 4.0)
  }
end
procs.each_with_index { |proc, i| proc.call(i) }

check = make_quad(10.0, 20.0, 30.0, 40.0)
if check.a.nan? || check.b.nan? || check.c.nan? || check.d.nan?
  puts "BUG: phantom NaN => #{check}"
else
  puts "OK: #{check}"
end
```

Output (`crystal run`):

```
BUG: phantom NaN => Quad(@a=10.0, @b=20.0, @c=NaN, @d=NaN)
```

`--release` (one leaked slot per call instead of two):

```
BUG: phantom NaN => Quad(@a=10.0, @b=20.0, @c=30.0, @d=NaN)
```

### Variant 2 — sret argument shift (SIGSEGV)

```crystal
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

procs2 = [] of Proc(Int32, Int32, Nil)
2.times { procs2 << ->(x : Int32, y : Int32) { take_quad(x, y) } }
procs2.each_with_index { |proc, i| proc.call(i * 10, i * 10 + 1) }
puts "survived"
```

```
Invalid memory access (signal 11) at address 0x...
```

## Analysis (x86-64 disassembly of variant 1, dev build)

The closure keeps its real signature — it is `~procProc(Int32, Quad)`
— and returns the Quad as two XMM parts plus **two x87 pushes**:

```asm
~procProc(Int32, Quad):
  ...
  movsd  0x8(%rsp),%xmm0     ; a
  movsd  0x10(%rsp),%xmm1    ; b
  fldl   0x20(%rsp)          ; d -> st(0)
  fldl   0x18(%rsp)          ; c -> st(0), d -> st(1)
  ret
```

The `.call` site (compiled for `Proc(Int32, Nil)`) dispatches
indirectly and pops **nothing**:

```asm
__crystal_main:
  mov  0x58(%rsp),%rax
  mov  0x6c(%rsp),%edi       ; the argument
  call *%rax                 ; <- pushes st(0)/st(1) in the callee
  jmp  ...                   ; <- no fxch / fstp: slots leaked
```

Eight leaked slots later any struct return that uses x87 overflows the
stack; `fldl` then produces QNaN indefinite.

## Expected behavior

Either

- the implicit coercion `Proc(*T, R) -> Proc(*T, Nil)` emits a wrapper
  that calls the original closure and properly discards its return, or
- `.call` sites of Nil-returning procs pop whatever the callee's
  convention left behind.

At minimum this deserves a compile-time restriction: covariance to
`Proc(*T, Nil)` should be rejected (or handled) when `R` is a struct
that cannot be returned in registers under the platform convention.

## Notes

- Reproduces identically on self-built 1.21.0/LLVM 20 and official
  1.22.3/LLVM 22, so it is not an LLVM regression.
- The same hole is reachable with captured blocks: a `def foo(&block :
  X ->)` parameter silently accepts a block whose last expression
  returns a struct.
