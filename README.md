# Bendler

[![CI](https://github.com/lukaszsamson/bendler/actions/workflows/ci.yml/badge.svg)](https://github.com/lukaszsamson/bendler/actions/workflows/ci.yml)

Public repository: [github.com/lukaszsamson/bendler](https://github.com/lukaszsamson/bendler)

Call [Bend](https://www.bend-lang.org/) code from Elixir, the way Rustler calls
Rust and Zigler calls Zig. A Bend file becomes an Elixir module: every
exportable def is a function, and the Bend program runs either as a NIF
inside the VM or as a port executable beside it.

**Status: proof of concept.** It works end to end on macOS with Bend 2.0.20,
Elixir 1.21-dev and OTP 28. The port backend is the one to reach for; the
NIF backend is experimental (see "Limits and hazards"). Read
`docs/RESEARCH.md` for how the Bend compiler and runtime were explored and
why the design is what it is, `docs/REVIEW.md` for what two rounds of
independent review found and changed, and `docs/VALIDATION.md` for what
was verified.

### Support matrix

| Component | Status |
|---|---|
| Bend | 2.0.20 only |
| OTP | 28 baseline |
| macOS | arm64 locally tested and verified in macOS 15 CI (Metal API baseline) |
| Linux | x86_64 / Ubuntu 24.04 tested in CI |
| Windows | Not supported |

## Usage

```elixir
# bend/fib.bend
import Base

def fib(n: Nat, a: U32, +b: U32) -> U32:
  match n:
    case 0n:
      a
    case 1n+p:
      fib(p, b, (a + b : U32))

def pow2(+n: Nat) -> U32:
  match n:
    case 0n:
      1
    case 1n+p:
      a b = pow2(p) pow2(p)   # a parallel call: runs on every core
      (a + b : U32)
```

```elixir
defmodule Fib do
  use Bendler, otp_app: :my_app, source: "bend/fib.bend", timeout: 5_000
end

# the default backend is a port: start it under your supervisor
children = [Fib]
Supervisor.start_link(children, strategy: :one_for_one)

Fib.fib(30, 0, 1)   #=> 832040
Fib.pow2(20)        #=> 1048576
```

`bend` emits C and `clang` builds it. Both must be installed (`bend` is
looked up on `PATH`, then at `~/.bend/bin/bend`; `config :bendler, bend:
path` overrides). Only Bend 2.0.20 is accepted, because the C side depends
on runtime internals; `config :bendler, allow_any_bend: true` lifts the gate.
CI pins LLVM clang 21.1.8, OTP 28.1 and Elixir 1.20.3. When using upstream
LLVM on macOS, set `SDKROOT` to `xcrun --sdk macosx --show-sdk-path`; the CI
installer also selects its bundled Mach-O linker to avoid mixing LLVM's
C++ runtime with Apple's linker.

With the Mix compiler listed, the build runs after Elixir compilation:

```elixir
def project, do: [compilers: Mix.compilers() ++ [:bendler], ...]
```

`mix compile.bendler --force` rebuilds, `mix bendler.clean` removes the
artifacts. Without the compiler, `use Bendler` builds while the module
compiles. Either way the artifact lands in `priv/bendler/` and is rebuilt
only when its fingerprint changes: the source and the files it imports, the
generated shim and C, and the toolchain (bend and its Base, clang, the
target, OTP). A release ships the artifact and does not need `bend`.

### Options

| option | meaning |
|---|---|
| `otp_app` | the application whose `priv/bendler/` receives the artifact |
| `source` | the Bend file, relative to the project root |
| `backend` | `:port` (default) or `:nif` (experimental, opt-in) |
| `threads` | CPU threads for the Bend runtime (default: schedulers online) |
| `exports` | the defs to export (default: every exportable def) |
| `timeout` | milliseconds a call may wait (default `:infinity`); port: the owner closes the port and stops, a supervisor restarts it; NIF: the caller gives up, the reply is discarded when it comes |
| `max_queue` | port: callers allowed to wait behind the one in flight (default 8) |
| `max_waiting` | NIF: total staged, queued and running calls (default 4); callers wait in Elixir |
| `gpu` | port: where `!` calls run: `:off` (default, the CPU pool), `:on`, or a heap cap like `"4GB"`; a program with `!` is built with its GPU lane and ships `<name>.gpu` beside the executable |

The port module has `start_link/1` and `child_spec/1`; options given there
override the module's. Put it under a supervisor before calling it.

### What crosses the boundary

| Bend | Elixir |
|---|---|
| `U32` | integer in `0..2^32-1` |
| `Nat` | integer in `0..2^48-1` (the runtime's immediate range) |
| `String` | binary (UTF-8; invalid bytes become U+FFFD) |
| `Bool` | boolean |
| `Unit` | `:unit` |
| `List<T>` (also `+List<T>`, `List<&2, T>`) | list |
| `B.Bytes` (the prelude's) | binary |
| `A & B`, `A & B & C` | `{a, b}`, `{a, b, c}` (2–16 fields) |
| `Maybe<T>` | `:none` or `{:some, value}` |
| `Result<E, T>` | `{:error, error}` or `{:ok, value}` |
| `F32` | float, rounded to single precision; `:nan`, `:infinity`, `:neg_infinity` for the values the BEAM has no float for |
| `Char` | integer code point (`0..0x10FFFF`, no surrogates) |
| `Map<V>` (also `Map<&2, V>`), a whole parameter or result | map with valid UTF-8 binary keys |
| `type T is Data:` of the same file | `{:ctor, field, ...}` per constructor, `:ctor` without fields |
| `IO(T)` result, with `~emit: E -> IO(Bool)` | the value, plus a `_stream` yielding `{:event, e}` then `{:done, value}` |

These types compose recursively, including bytes inside tuples and variants;
only `Map` has to be a whole parameter or result, because it crosses as a
list of pairs that Base's `Map.from_list` and `Map.to_list` convert on the
Bend side. A user datatype crosses as the prelude's `Dyn` tree, converted
by defs the build generates into the shim, so `type Shape is Data:` with
`Circle{r: U32}` and `Dot{}` takes `{:circle, 3}` and `:dot`; recursive
types (a tree, a linked list) work, with the rules in `Bendler.Sig`. See
[type contracts](docs/TYPES.md) and [the accepted contract subset](docs/CONTRACTS.md) for nesting limits, parentheses, the float
policy, the datatype rules and the distinction between Result failures
(data) and transport exceptions.

`Bytes` comes from a small Bend prelude, `bendler.bend`, that the build
writes next to any source using it; import it as `import ./bendler.bend
as B`. A `Bytes{len, buf}` holds one byte per slot of an `Array<U32>`
buffer, so a binary crosses as one block instead of a list cell per byte
(30x faster for 64 KB in the Murmur3 demo). `B.Bytes.to_list/1`,
`B.Bytes.from_list/1` and `B.Bytes.at/2` are the helpers.

A def is exported when all its parameters and its result are of these types,
or when its result is `IO(T)` of one of them (see "Events out of Bend").
Erased (`-`) and template (`~`) parameters, closures, arrays and
unsupported types keep a def out (it is reported at debug level). `main` is
never exported: the shim supplies its own. Reusable (`+`) parameters are
honoured.

### Events out of Bend

A def that answers `IO(T)` may take a typed **emitter**, and then one call
can hand the BEAM a stream of values while it is still running:

```python
def fly(~emit: B.Bytes -> IO(Bool), scene: Scene, w: U32, h: U32,
        frames: U32, cx: F32, cz: F32) -> IO(U32):
  ...                      # render a frame, emit it, stop early on False
```

```elixir
Raytrace.fly_stream(scene, 320, 240, 48, 0.0, 5.0)
|> Stream.each(fn
  {:event, rgb} -> write_frame(rgb)   # each frame as Bend finishes it
  {:done, n} -> IO.puts("#{n} frames")
end)
|> Stream.run()
```

The emitter is not a wire argument: the shim supplies a lambda over a
fourth foreign effect, `Bendler.emit`, which encodes the value with the
same codec a reply uses, writes it as an EVENT frame and then parks on the
host's one-byte acknowledgement. That acknowledgement is the whole
backpressure and cancellation story: at most one event is outstanding, the
worker cannot run ahead of the consumer, and an acknowledgement of `False`
is a typed, cooperative "stop" that the def sees as an ordinary value.

Every export with an emitter gets two functions: `fun(...)`, which refuses
the events at once (the def's first emit is answered `False`, so it
finishes early), and `fun_stream(...)`, a lazy `Enumerable` of
`{:event, value}` ending in `{:done, result}`. Demand drives the
acknowledgements: the one for an event goes out when the next is asked
for, so a paused consumer holds one event and the worker waits. Halting
early (`Enum.take/2`), an exception in the consumer, and the consumer's
death all end the turn and free the port. Events are type-checked like
replies. Write the emitter with `~` (Bend's template marker) whenever the
def emits more than once: a Bend function type is Type-kinded, so a
closure binder can never be reusable. Events are a **port** feature; under
`backend: :nif` an `IO(T)` export is refused at build time.

The [raytracer demo](demos/raytrace/README.md)'s `fly` is the worked
example: one call renders a whole camera turn and each frame arrives in
Elixir as it finishes, assembled into an animated PNG while the render is
still running.

Arguments are checked on the Elixir side and raise `ArgumentError`. A call
returns the value or raises `Bendler.Error`, whose `reason` is `:busy`
(admission limit hit), `:timeout`, `:exited` (the port died; a supervisor
restarts it), `:dead` (the NIF runtime hit a fatal error and is frozen) or
`:refused` (the program rejected the frame).

## How it works

```
  Elixir                          Bend program (one C file from `bend -o x.c`)
  ──────                          ──────────────────────────────────────────
  Fib.fib(30, 0, 1)
    │ Bendler.Codec: <<idx::32, args>>
    ▼
  NIF admission → dirty validation ─▶ Bendler.fn()    (foreign effect: waits for a frame)
   or Port ({:packet, 4}) ────────▶    Bendler.arg(T)  (foreign effect: decodes one argument)
                                        M.fib(n, a, b)  (the user's def, on every core)
  ◀── event frame (tag 16) ◀────────   Bendler.emit(T, x)  (port only: writes, then waits
    ── ack byte (1 go on / 0 stop) ─▶                        for the host's answer as a Bool)
  ◀──────────── reply frame ◀────────  Bendler.reply(T, x) (foreign effect: encodes the result)
```

Bendler generates a *shim*: a Bend file that imports yours, declares the
foreign effects (`Bendler.fn`, `Bendler.arg`, `Bendler.reply`, and
`Bendler.emit` when an export has an emitter) and a `main` that loops: read
a function index, pull each argument, call the def, reply.
Bend's own compiler emits the C; the effects are ordinary Bend foreign C
files (`priv/c/`), spliced into that C by the compiler. The same shim serves
both backends, only the transport header differs:

- **port**: length-prefixed frames on stdin/stdout, the reads parked on
  Bend's event loop (`io_wait_on`), so the loop never blocks.
- **NIF**: the emitted C is patched (`main` → `bend_main`, the runtime's
  signal handlers dropped, `_exit` → `bendler_die`) and linked as a shared
  library with a small `erl_nif` entry table. Checked initialization pins
  the library for the VM lifetime, then runs `bend_main` with `--threads N`.
  Normal-scheduler admission precedes dirty validation/copying; native
  completion sends a message. Waiting uses an ordinary Elixir `receive`.

Every value that crosses is a Base type the runtime lays out itself
(`io_str`, `io_node(CID_CON, ...)`, packed `Bool`), which is why the C side
never has to know the layout of a user constructor.

## Limits and hazards

- **One request at a time per module.** The shim's loop is sequential;
  admission is bounded (`max_queue`, `max_waiting`) and the rest are told
  `:busy` at once. Inside a call, Bend still uses every core. An event
  belongs to the one request in flight, and its acknowledgement round trip
  is a whole pipe round trip, so events are for meaningful units of work
  (a rendered frame), not for streaming small values.
- **Events are cooperative.** `False` is a value the Bend def must act on.
  A def that ignores it keeps being answered `False` until it returns;
  only the total deadline is involuntary, and it discards the whole worker.
  Events are not available on the NIF backend.
- **Batch small calls.** With the launcher, telemetry and codec budgets,
  a short Levenshtein port call averaged 48 µs locally. A 64-pair medium
  batch averaged 9.6 µs/pair versus Elixir's 37.8 µs/pair. Earlier ~10 µs
  transport-only measurements are not current end-to-end latency promises.
- **Port deadlines stop the worker.** The owner closes the port and stops;
  a separate POSIX launcher sends TERM to the worker process group, then
  KILL after 200 ms, and reaps the child. Owner death is covered too. This
  discards the whole worker, not just one computation. NIF cancellation
  still does not exist: the computation finishes and its reply is dropped.
- **A Bend runtime error freezes that module's NIF runtime**: the runtime's
  `_exit` is routed to `bendler_die`, so later calls raise `Bendler.Error`
  with reason `:dead` instead of taking the VM down. The frozen runtime keeps
  its threads and memory until the VM exits. A crash in the C runtime proper
  (a segfault) still kills the VM, as with any NIF. The port backend has the
  process boundary instead: a runtime error exits the worker (1), a protocol
  error exits 65, a transport error 74, and a supervisor restarts it.
- **NIF admission precedes dirty scheduling.** `max_waiting` counts staged,
  queued and running requests. Abandoning running work does not free its
  slot until it finishes; queued work can be removed.
- **NIF runtimes are pinned until VM exit.** A retained callback-bearing
  resource prevents code purge from unloading code beneath live threads.
  It deliberately retains the library, threads and memory; this is not
  graceful runtime unload. Upgrade is refused. Replacing a loaded artifact
  or repeatedly reloading modules is unsupported.
- **The NIF deadline** is absolute and starts before encoding. Scheduler
  queueing and validation consume the same budget, but scheduling can still
  delay delivery of the timeout. This is not a hard real-time guarantee.
- **The emitted C is patched by regex.** The build asserts each patch
  matched exactly as expected and that no `sigaction`, `signal`, `_exit` or
  `abort` call survives; a Bend release that changes the runtime fails the
  build rather than hosting something unexpected.
- **A malformed request never reaches a def.** Every request is validated
  against the export's type spec, without allocating, before it is handed
  to the runtime: the NIF does it on the calling thread and answers
  `:refused`; the port worker answers an error frame and goes on. Frames
  are capped at 64 MiB (`-DBENDLER_MAX_FRAME`), list items per request at
  16M (`-DBENDLER_MAX_ITEMS`), type-spec nesting at 32 and value nesting
  at 2048. Decoded allocation admission defaults to 64 MiB; this is not
  an OS RSS cap. Replies are checked against the declared return type too.
- **Artifacts use `priv/bendler/<target>/<env>/`** despite Mix's shared
  priv symlink. Build and clean share a filesystem lock; abandoned locks
  require manual recovery after verifying that the owning build has died.
- Each NIF module reserves 8 GiB of virtual address space (the runtime's
  heap arena, `MAP_NORESERVE`) plus 2 GiB of virtual stack per worker thread.
- `Nat` values are limited to `2^48-1`; the codec rejects larger integers.
- The GPU lane (`f!(x)`) works through a port (Metal on macOS, CUDA on
  Linux when installed) and is off unless `gpu:` says otherwise; a NIF
  runs `!` on the CPU pool. Whether it is faster is the kernel's shape,
  not a flag: see the ray tracer demo's GPU section.
  A toolkit without a visible device produces a CPU-capable executable with
  no `.gpu` sidecar. Rebuild with `mix compile.bendler --force` on the GPU
  host before enabling that lane. Hosted CI does not promise GPU coverage.
- The C side depends on runtime internals (`io_eff`, `io_str`, `ctr_take`,
  ...). Bend promises no ABI: rebuild on every Bend update (the build hash
  includes the `bend version`).

## Layout

The [parallel Mandelbrot demo](demos/mandelbrot/README.md) compares a
CPU Port kernel with scalar Elixir and Nx/EXLA, including thread scaling,
exact upstream checksums, and reproducible benchmark commands.
The [sorting and set-operations demo](demos/sorting/README.md) compares
tree-bitonic sorting with `Enum.sort` and `MapSet`, including list round-trip
costs and cases where more Bend workers make performance worse.
The [small CSV parser](demos/csv/README.md) uses tuples, Maybe and Result,
with byte-preserving fields and differential tests against NimbleCSV.
The [raytracer](demos/raytrace/README.md) takes its whole scene as user
datatypes and answers packed RGB `Bytes`, with parallel tiles, an
Elixir-owned tile schedule and deadline, a PNG writer, and a bit-exact
upstream checksum beside the F32-against-doubles comparison. Its camera
fly-through is the worked example of typed events: one call renders a
whole turn and each frame arrives as it finishes, into an animated PNG
that grows while the render runs.

```
lib/bendler.ex          use Bendler: builds at compile time, defines the functions
lib/bendler/sig.ex      parses def signatures, decides what is exportable
lib/bendler/gen.ex      writes the shim; patches the emitted C for the BEAM
lib/bendler/build.ex    runs bend and clang, caches by input hash
lib/bendler/codec.ex    the frame codec
lib/bendler/port.ex     the port owner: bounded queue, deadline, events, exit codes
lib/mix/tasks/          mix compile.bendler and mix bendler.clean
priv/c/                 the four foreign effects and the two transports
priv/bend/bendler.bend  the prelude (Bytes), copied next to sources that use it
bend/fib.bend           the example module
test/support/           Bendler.Examples.FibNif and FibPort, and the crash and admission fixtures
demos/<name>/           a real port each (Bend source, port module, reference, tests, bench)
test/                   the suite (mix test)
docs/RESEARCH.md        findings, alternatives, roadmap
docs/REVIEW.md          what independent review found, and what changed
docs/VALIDATION.md      what was verified, and how
docs/BEAM_API.md        which parts of erl_nif and erl_driver this needs
docs/MVP.md             the task list from PoC to MVP
```
