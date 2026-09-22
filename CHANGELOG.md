# Changelog

## 0.1.0 — Unreleased

The supported surface is the CPU port binding generator,
frozen in `docs/API.md`. The baseline is Bend 2.0.25 with OTP 28 on macOS
arm64 and Linux x86_64; Windows is not supported.

### Bindings and build

- `use Bendler` turns a Bend file into an Elixir module: every exportable
  def becomes a function with an Elixir typespec and generated docs.
- `mix compile.bendler` (with `--force`) and `mix bendler.clean`, plus an
  inline build fallback when the Mix compiler is not listed.
- Reproducible artifact fingerprints over source, imports, generated shim
  and C, and toolchain; atomic staged builds; per-application, per-target
  and per-environment artifact paths with a filesystem lock.
- A release ships its native artifacts and needs neither Bend nor clang.
- A Bend 2.0.25 compiler gate, with `allow_any_bend` to opt out.

### Types

- `U32`, `Nat` (up to 2^48-1), `String`, `Bool`, `Unit`, `List<T>`,
  `B.Bytes`, products of 2 to 16 fields, `Maybe<T>`, `Result<E, T>`,
  `F32`, `Char`, and a whole `Map<V>` parameter or result.
- Same-file user datatypes cross as tagged tuples through the prelude's
  `Dyn` tree, with generated Bend-side converters.
- Codec validation on both sides, decoded-allocation budgets, frame, item
  and nesting caps, and a generated type-spec table the native validator
  walks before any def is dispatched.

### Port lifecycle

- A supervised port owner with bounded admission (`max_queue`), total
  deadlines including queue time, caller monitoring and telemetry.
- A POSIX launcher owns the worker process group: TERM on owner exit or
  deadline, KILL after 200 ms, then reaping and output draining. Worker
  exit codes are preserved across a stdin close with pending input.
- Documented exit codes: 0 clean EOF, 1 runtime error, 65 protocol error,
  74 transport error.
- Parent- and child-side `setpgid` permission failures are accepted only when the
  worker is verifiably in its intended process group, avoiding a spurious
  startup failure without ignoring genuine group-setup errors.
- `[:bendler, :call, :start | :stop | :exception]` telemetry with queue
  depth, wait time and run time, and no payload values.

### Events and ask callbacks

- A def answering `IO(T)` is an export. A `~emit: E -> IO(Bool)` parameter
  is its typed event sink: a fourth foreign effect writes an EVENT frame
  and parks on the host's one-byte acknowledgement, so at most one event
  is outstanding and `False` is typed, cooperative cancellation.
- Each such export gets a generated `_stream` function, a lazy Enumerable
  of `{:event, value}` ending in `{:done, result}`, whose demand drives the
  acknowledgements.
- Typed `~ask: Request -> IO(Response)` callbacks: the generated function
  takes a final unary handler, which runs in a fresh linked and monitored
  process with a fixed five-second deadline. Responses are validated on
  both sides. Direct same-worker reentry raises `:reentrant`; handler
  failure raises `:callback` and lets a supervisor replace the worker.
- One callback channel per export: ask or emit.

### Experimental NIF backend

- `backend: :nif` loads the program into the VM: bounded admission
  (`max_waiting`) on normal schedulers, validation and copying on a dirty
  CPU scheduler, replies by `enif_send`, waiting by ordinary `receive`.
- Checked initialization, caller monitoring, absolute monotonic deadlines
  translated to OS monotonic time before the Bend thread uses them.
- Emit streams with resource-scoped, sequence-checked messages and
  acknowledgements, and native parked deadlines.
- Typed ask replies validated on a dirty CPU scheduler with owner and
  sequence checks.
- A VM-lifetime pin keeps live runtime code mapped; upgrade is refused.
  There is no graceful unload and no hard cancellation. A fatal runtime
  error, or a failed or abandoned ask, freezes that module (`:dead`);
  a typed `Result.Fail` remains ordinary data.

### Experimental GPU lane

- A program using `!` is built with Bend's GPU lane (Metal on macOS, CUDA
  on Linux when installed) and ships a `<exe>.gpu` sidecar. `gpu:` accepts
  `:off`, `:on` and a heap cap. Port only; the NIF refuses the option.
  A toolkit without a visible device still yields a CPU-capable executable.

### Demos

Batched Levenshtein, Murmur3, ThumbHash, parallel Mandelbrot, tree-bitonic
sorting and set operations, CSV (eager, lazy streaming and ask-driven
aggregation), a raytracer with user datatypes, parallel tiles, a camera
fly-through over typed events and a GPU lane, and particle ticks comparing
port and NIF event delivery. Each demo owns its benchmark method and results.

### CI

macOS 15 arm64 and Ubuntu 24.04 x86_64, with checksum-pinned Bend 2.0.25 and
LLVM 21.1.8, OTP 28.1, Elixir 1.20.3 and commit-pinned actions. The workflow
runs the suite, formatting, warnings-as-errors, strict Credo, Dialyzer, docs,
external-port AddressSanitizer probes, an overload and RSS observation,
port transport stress, a compiler-free consumer release, a real Hex package
in a fresh consumer, and isolated NIF lifecycle probes.
