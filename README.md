# Bendler

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
| `max_waiting` | NIF: callers admitted at once, waiting or in flight (default 4), each on a dirty scheduler thread |

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

`Bytes` comes from a small Bend prelude, `bendler.bend`, that the build
writes next to any source using it; import it as `import ./bendler.bend
as B`. A `Bytes{len, buf}` holds one byte per slot of an `Array<U32>`
buffer, so a binary crosses as one block instead of a list cell per byte
(30x faster for 64 KB in the Murmur3 demo). `B.Bytes.to_list/1`,
`B.Bytes.from_list/1` and `B.Bytes.at/2` are the helpers.

A def is exported when all its parameters and its result are of these types.
Erased (`-`) and template (`~`) parameters, `IO` results, closures, arrays
and user datatypes keep a def out (it is reported at debug level). `main` is
never exported: the shim supplies its own. Reusable (`+`) parameters are
honoured.

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
  NIF (dirty CPU) ── pipe+condvar ──▶  Bendler.fn()    (foreign effect: waits for a frame)
   or Port ({:packet, 4}) ────────▶    Bendler.arg(T)  (foreign effect: decodes one argument)
                                        M.fib(n, a, b)  (the user's def, on every core)
  ◀──────────── reply frame ◀────────  Bendler.reply(T, x) (foreign effect: encodes the result)
```

Bendler generates a *shim*: a Bend file that imports yours, declares three
foreign effects (`Bendler.fn`, `Bendler.arg`, `Bendler.reply`) and a `main`
that loops: read a function index, pull each argument, call the def, reply.
Bend's own compiler emits the C; the effects are ordinary Bend foreign C
files (`priv/c/`), spliced into that C by the compiler. The same shim serves
both backends, only the transport header differs:

- **port**: length-prefixed frames on stdin/stdout, the reads parked on
  Bend's event loop (`io_wait_on`), so the loop never blocks.
- **NIF**: the emitted C is patched (`main` → `bend_main`, the runtime's
  signal handlers dropped, `_exit` → `bendler_die`) and linked as a shared
  library with a small `erl_nif` glue. At load, a thread runs `bend_main`
  with `--threads N`. A dirty-scheduler NIF copies the frame in, pokes a
  pipe, and waits on a condition variable for the reply.

Every value that crosses is a Base type the runtime lays out itself
(`io_str`, `io_node(CID_CON, ...)`, packed `Bool`), which is why the C side
never has to know the layout of a user constructor.

## Limits and hazards

- **One request at a time per module.** The shim's loop is sequential;
  admission is bounded (`max_queue`, `max_waiting`) and the rest are told
  `:busy` at once. Inside a call, Bend still uses every core.
- **Latency is ~10 µs per call on either backend** (thread hand-off). The
  NIF form does not yet beat the port form; see the research notes.
- **Cancellation does not exist.** A timed-out request keeps running in the
  runtime. The port owner closes the port and stops, but closing a port is
  not a hard kill: the worker exits when it next writes to the closed pipe
  (that is the "stdout write failed" line on stderr). The NIF runtime just
  finishes the work and its reply is dropped.
- **A Bend runtime error freezes that module's NIF runtime**: the runtime's
  `_exit` is routed to `bendler_die`, so later calls raise `Bendler.Error`
  with reason `:dead` instead of taking the VM down. The frozen runtime keeps
  its threads and memory until the VM exits. A crash in the C runtime proper
  (a segfault) still kills the VM, as with any NIF. The port backend has the
  process boundary instead: a runtime error exits the worker (1), a protocol
  error exits 65, a transport error 74, and a supervisor restarts it.
- **NIF callers wait on dirty CPU schedulers.** At most `max_waiting` plus
  the one in flight do; size it with your dirty scheduler count in mind.
- **No reload, upgrade or unload** of a NIF module: the runtime's threads
  cannot be stopped. Nothing enforces this: purging the module's code can
  unload the library under threads still running it. Do not purge a module
  that loaded a Bendler NIF. A second `load_nif` is refused (no upgrade
  callback).
- **The NIF deadline** starts after validation and after a dirty scheduler
  was obtained, so it is shorter than the caller's wall clock.
- **The emitted C is patched by regex.** The build asserts each patch
  matched exactly as expected and that no `sigaction`, `signal`, `_exit` or
  `abort` call survives; a Bend release that changes the runtime fails the
  build rather than hosting something unexpected.
- **A malformed request never reaches a def.** Every request is validated
  against the export's type spec, without allocating, before it is handed
  to the runtime: the NIF does it on the calling thread and answers
  `:refused`; the port worker answers an error frame and goes on. Frames
  are capped at 64 MiB (`-DBENDLER_MAX_FRAME`), list items per request at
  16M (`-DBENDLER_MAX_ITEMS`), nesting at 32. Replies are checked against
  the declared return type on the Elixir side too.
- **`priv/bendler/` is shared across Mix environments** when the project
  has a `priv/` directory (Mix symlinks it), so `test` and `dev` builds of
  the same module overwrite each other's artifact.
- Each NIF module reserves 8 GiB of virtual address space (the runtime's
  heap arena, `MAP_NORESERVE`) plus 2 GiB of virtual stack per worker thread.
- `Nat` values are limited to `2^48-1`; the codec rejects larger integers.
- The GPU lane (`f!(x)`) is untested from the BEAM; the shim builds a CPU
  program (`BANGS 0` unless your code uses `!`).
- The C side depends on runtime internals (`io_eff`, `io_str`, `ctr_take`,
  ...). Bend promises no ABI: rebuild on every Bend update (the build hash
  includes the `bend version`).

## Layout

```
lib/bendler.ex          use Bendler: builds at compile time, defines the functions
lib/bendler/sig.ex      parses def signatures, decides what is exportable
lib/bendler/gen.ex      writes the shim; patches the emitted C for the BEAM
lib/bendler/build.ex    runs bend and clang, caches by input hash
lib/bendler/codec.ex    the frame codec
lib/bendler/port.ex     the port owner: bounded queue, deadline, exit codes
lib/mix/tasks/          mix compile.bendler and mix bendler.clean
priv/c/                 the foreign effects and the two transports
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
