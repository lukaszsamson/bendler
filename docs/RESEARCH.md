# Integrating Bend with Elixir: research notes

Date: 2026-09-20. Bend 2.0.20 (`~/.bend`), compiler checkout at
`7561656155a4285c1e4ccfcb3505ab59524de973`, Rustler at
`36c147202504b31d0b7523df2948b224bc88a8e7`, Zigler at
`afb8a604e278a21717e73151eff078854f4c84ce`, Elixir 1.21.0-dev on OTP 28
(erts 16.4.0.1), Apple clang 21, macOS arm64.

Upstream knows about the gap: `WONTFIX.txt` entry #813, "A native library
target for pure defs", says the C output is one program with a `main`, and
that exporting chosen defs with a header and a lifecycle is planned, not
scheduled. Everything below works around that.

## 1. What Bend is today

Bend 2 is not the HVM-based Bend 1. The compiler is a ~11k-line TypeScript
program (`bend2/bend.ts` the language and checker, `bend2/comp.ts` the
compiler and the C/Metal/CUDA/JS runtimes, `bend2/main.ts` the CLI), shipped
as a single Bun-built executable. It is a dependently typed, affine,
Python-shaped language with mandatory termination, proofs (`law`/`def`),
fork-join parallelism (`a b = f(x) g(y)`) and a GPU lane (`f!(x)`).

The CLI matters most here:

```
bend x.bend            check, then run main (an IO main is compiled, a pure main normalised)
bend x.bend -o x       native binary via clang (-std=c11 -O3 -lpthread -lm)
bend x.bend -o x.c     emit the C source
bend x.bend -o x.js    emit JS
```

There is no `-o x.so`, no flag for a shared library, and no way to name
roots other than `main`. But `-o x.c` hands over one self-contained C file
(runtime plus program) which clang builds with `-shared -fPIC` without
complaint, so **emitting a shared library is trivial**. The question is what
you can call inside it.

## 2. The runtime, as far as embedding is concerned

Read from `comp.ts` (sections `RuntimeC`, `Corpus`, `Pool`, `Io`, `Main`) and
from emitted files.

- **Process-wide singleton.** `corpus_setup()` mmaps an 8 GiB
  `MAP_NORESERVE` arena at a high fixed hint (`1<<45`, halving until free),
  and all state (`CORPUS`, allocator lanes `ALC[]`, banks, the pool) is
  global static. Two shared objects each get their own copy (separate
  `static` symbols, separate arenas), so several NIF modules can coexist,
  each with its own runtime. One runtime cannot be instantiated twice.
- **Threads.** `pool_open()` lazily starts `--threads` worker pthreads at the
  first fork, and they never exit. IO helper threads (`io_work`) come and go.
  Each worker maps a 2 GiB virtual stack (`pool_stack`), installs a
  `sigaltstack` and, once, process-wide `SIGSEGV`/`SIGBUS` handlers
  (`err_trap`). `io_loop` also sets `SIGPIPE` to ignore.
- **Errors.** `err_fail()` prints and `_exit(1)`s. Runtime errors (a Nat past
  2^48-1, a reference-count on a closure, an alien request) reach it via
  `err_post`.
- **Entry.** `int main()` parses `--threads/--gpu`, calls `corpus_setup`,
  then `io_loop(H)`, which evaluates `main`'s task through `corpus_eval` and
  drives an event loop: each computation runs its pure code (in parallel) up
  to its next IO request, and the loop dispatches the request to a
  registered effect (`io_eff_rows[cid].run`).
- **Effects are the FFI.** A def whose body is `import "./x.c"` (plus a
  `.js` twin) is implemented by `Term x_run(Env e, Term* f, IoWork* w)`,
  registered from a C constructor. Arguments arrive as boxed `Term`s
  (`(u32)f[0]`, `io_cstr(e, f[0], &n)`), results are built with `io_str`,
  `io_node`, `term_pak`. An effect can park on an fd (`io_wait_on`) or run
  blocking work on a helper thread (`io_work`). Only the loop thread runs
  effects, so they never see the GPU or the checker. `guide/EFFECTS.md` and
  `bend2/effs/*.c` document this, with the caveat "no ABI promise". The
  guide is already slightly stale: its `io_node(e, CID_K, a, b, 0)` has a
  fifth argument the source does not take.
- **Terms and layout.** A term is a 64-bit word: tag (7 bits), aux (16 bits:
  a constructor or function id), loc (40 bits). Small constructors are
  *packed* into the word (`term_pak(CID, payload)`: a one-field constructor
  with a word field carries the field in its loc bits), larger ones are
  nodes allocated in a size class (`heap_alloc(e, cls_fit(n))`), and *flat*
  datatypes travel unboxed as several registers between segments. Base's
  `String` is a cons list of chars (`CID_SCON`/`CID_SNIL`), `List` is
  `CID_CON`/`CID_NIL` nodes, `Nat` is immediate up to 2^48-1, `Bool` and
  `Unit` are packed.
- **Defs compile to segments of a flat state machine**, reachable from
  `main` only. Small and tail-recursive defs are *inlined* into their
  callers: in a test program `fib`, `sum` and `range` got no function id at
  all, only a def that called `String.append` did. Function ids
  (`FID_NAME`), arities and result widths (`FID_ARITY_T`, `FID_RESW_T`) are
  emitted per program.

## 3. Ways to call Bend from the BEAM

### A. Direct calls to compiled defs (rejected for now)

Build a task node for `FID_F` with the arguments written into it, run
`corpus_eval`, read the result words. This is what `io_step` does for
`Clo.apply`, so it is technically supported. Problems:

1. Reachability and inlining: a def only gets a `FID` if something reachable
   from `main` calls it *and* the compiler chose not to inline it. A shim
   `main` that calls every export with runtime-dependent arguments keeps
   them reachable but not un-inlined. Fixing this needs a compiler change
   (`compile_book(book, roots)`, the way `js_lib(book, roots)` already
   works for the JS lane, plus a no-inline flag on roots). The compiler is
   Bun-only; Bun is not installed here, and the shipped binary embeds it.
2. Layout: arguments and results of flat datatypes are multi-word and
   register-passed, packed constructors depend on field shapes, `+` values
   must be reference-count sealed (`rfc_seal`). Building these by hand in C
   is exactly the fragile part, as the packed `IsBig{x}` case showed
   (`o_1 = term_loc(x)` instead of a node).
3. Reentrancy: `corpus_eval` assumes the loop thread's allocator lane and
   the runtime's single root. Calls would have to be serialised anyway.

The upside is real, though: a call would run on the dirty scheduler thread
itself with no hand-off, so latency would drop from ~10 µs to sub-µs. This
is the natural next step once the compiler can be patched; see §6.

### B. The program serves requests through effects (chosen)

Keep Bend's own `main` and event loop, and make the *program* the server.
A generated shim declares three foreign effects and loops:

```python
def Bendler.step(fn: U32) -> IO(Unit):
  match fn:
    case 0:
      do IO<Unit>:
        n : Nat <- Bendler.arg(Nat, "n")
        a : U32 <- Bendler.arg(U32, "u")
        +b : U32 <- Bendler.arg(U32, "u")
        Bendler.reply(U32, "u", M.fib(n, a, b))
    ...
def Bendler.serve(fuel: Nat) -> IO(Unit):   # a Nat fuel keeps termination honest
  match fuel:
    case 0n: IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        fn : U32 <- Bendler.fn()
        Bendler.step(fn)
        Bendler.serve(p)
```

Why this is robust: the user's def is called *by Bend code*, so inlining,
flat layouts and register passing are the compiler's business. Every value
that crosses the C boundary is a Base type built the way the runtime's own
effects build it (`IO.args` builds a `List<String>` with `io_node(CID_CON,
io_str(...))`). The one earlier attempt to hand-build a user request
constructor (`type Bendler.Req`) broke on packing and was dropped. The typed
`Bendler.arg(-A: Type, spec: String) -> IO(A)` effect lets one C function
serve every type: the spec string ("u", "n", "s", "b", "t", "L<elem>") tells
it what to build, and Bend's checker guarantees `A` matches the def.

Two transports share the shim and the codec:

- **Port**: frames on stdin/stdout, the reads parked with `io_wait_on(w, 0,
  POLLIN, ...)`. `{:packet, 4}` on the Elixir side matches the 4-byte
  prefix. The runtime option `--threads N` is passed as an argument.
- **NIF**: the emitted C is patched by regex (`main` → `bend_main`, the
  `sigaction`/`signal` lines removed so the VM keeps its handlers, `_exit(1)`
  → `bendler_die(1)`) and built with `-shared -fPIC -undefined
  dynamic_lookup` (macOS) together with a 40-line `erl_nif` glue. `load`
  spawns the runtime thread; the NIF (`ERL_NIF_DIRTY_JOB_CPU_BOUND`) copies
  the frame, writes a byte to a pipe the `Bendler.fn` effect is parked on,
  and waits on a condvar. `bendler_die` marks the runtime dead, wakes
  waiters, and parks the thread forever: a Bend runtime error becomes an
  Elixir exception, and the VM survives (tested: a `Nat` overflow in one
  module leaves another module working).

### C. Plain ports around a Bend executable (the fallback the user asked about)

This is transport B-port. It needs nothing from the NIF machinery and is the
one to use where loading foreign code into the VM is unwelcome; it costs a
process and, in this PoC, the same ~10 µs per call.

## 4. Comparison with Rustler and Zigler

| | Rustler | Zigler | Bendler (PoC) |
|---|---|---|---|
| Build | Mix compiler runs `cargo`; crate exports NIFs via macros | `use Zig` compiles at Elixir compile time (`~Z` sigil or file), runs `zig` | `use Bendler` builds at compile time: `bend -o shim.c`, then `clang` |
| Load | `@on_load` + `:erlang.load_nif` | same | same (NIF) or a GenServer port |
| Function surface | you write `#[rustler::nif]` fns | you write Zig fns; Zigler parses Zig to generate stubs | parsed from Bend `def` signatures; every exportable def is a function |
| Term marshalling | `Encoder`/`Decoder` traits, direct `ERL_NIF_TERM` access | direct `beam.term` access | a frame codec; Bend never touches `ERL_NIF_TERM` |
| Threading | your code on the scheduler (dirty flags per fn) | same | always dirty; the work happens on Bend's own threads |
| Panics | caught and turned into exceptions | Zig errors mapped | runtime `_exit` intercepted; the runtime freezes, the VM lives |
| Reload | supported with care | supported | not supported |

The structural difference: Rust and Zig functions *are* C functions the
scheduler can call. Bend defs are segments of a state machine driven by a
runtime that owns its threads and heap, so the natural interface is
"message the running program", which is what a port does, and what the
NIF here does internally.

## 5. Measurements (Apple M-series, 24 schedulers, `mix run scratch/bench.exs`)

| call | NIF | port |
|---|---|---|
| `is_big(5)` (a word in, a Bool out) | 10.3 µs | 9.7 µs |
| `fib(90, 0, 1)` | 14.6 µs | 12.1 µs |
| `range(1000, [])` (a 1000-element list out) | 69 µs | 65 µs |
| `pow2(24)` (16M parallel leaf calls) | 9 ms | 8 ms |

`pow2(24)` as a standalone binary: 14 ms wall including process start on all
cores, 63 ms on one thread, so the parallel runtime really runs inside the
VM. The NIF and port are the same speed because both hand off through a
pipe and a wake-up. The port transport is not the bottleneck; the hand-off
is.

## 6. Independent review

The code was reviewed twice by an independent implementer who had built a
port-only integration from the same brief and reached the same facts about
the compiler and runtime. `REVIEW.md` lists every finding and its fix; the
two that changed the design were the reply-slot race under concurrent
callers and the move to validating a whole request against the export's
spec before it reaches the runtime.

## 7. Roadmap, if this is taken further

1. **Direct calls (fast NIF).** Patch `comp.ts` so `compile_book` takes
   roots that are never inlined and emit, per root, a C entry
   `Term bend_call_<name>(Env, Term* args)` plus a layout descriptor for
   its parameters and result (the `SHOW_DESC` machinery already describes
   result types for printing a pure `main`). Needs Bun to run the patched
   compiler, or a `node --experimental-strip-types` path. The runtime still
   has to be started once and calls serialised, but the dirty scheduler
   thread would do the work.
2. **Multiple in-flight requests.** Make `Bendler.serve` `IO.fork` each
   request so independent calls overlap on the loop (the pure parts already
   parallelise). Reply frames then need a request id.
3. **More types.** `F32`, `Char`, tuples (`A & B` is `CID_TUPLE`), `Maybe`
   and `Result` are all runtime-laid Base types and cheap to add. User
   datatypes could be marshalled by generating Bend-side converters to and
   from a generic tree, keeping C ignorant of layouts. Arrays (`Array<T>`)
   are blocks (`TAG_BUF/TAG_ARR`) and would map to binaries.
4. **Bignums**: Bend's `Nat` past 2^48 is an error today, so nothing to do
   until the runtime grows big naturals.
5. **GPU.** A `!` program needs clang 19+ with `#embed` and writes a
   `.gpu` companion; the shim just needs the build flags from `cli_build`
   and the `.gpu` file next to the artifact.
6. **Packaging.** The Mix compiler exists; still missing are precompiled
   artifacts, per-environment artifact paths, and a `mix bendler.check` that
   runs `bend --check-only` on `PROOF.bend` in CI, which is the proof-gated
   workflow Bend advertises.
8. **Cancellation.** A hard-kill launcher for the port (own the OS process,
   TERM then KILL on deadline) and, for the NIF, nothing short of a runtime
   hook: a frozen or runaway runtime cannot be reclaimed today.
7. **Linux**: drop `-undefined dynamic_lookup`, add `-lX11`/`-lasound` only
   if the program includes them (as `cli_build` does), verify the fixed-hint
   mmap coexists with the BEAM's allocators.
