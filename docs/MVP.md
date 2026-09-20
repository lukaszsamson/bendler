# From PoC to MVP

The PoC proves the shape: a generated Bend shim serves requests from the
BEAM through three foreign effects, as a port or as a NIF. The MVP, in the
words of the second review, is **a reliable CPU port binding generator for
bounded pure functions**. NIF support stays opt-in and outside that
promise. The work falls into six tracks; the first two gate a public
release, the rest gate "usable for a real port". Items marked (done) were
closed while adopting the reviews.

## 1. Publish hygiene (before the first push)

- [ ] `git init`, a LICENSE (Apache-2.0 matches Bend's), `CHANGELOG.md`.
- [ ] Hex metadata in `mix.exs` (`description`, `package`, `docs` with
      `extras: docs/*.md`), `ex_doc` as a dev dep, `mix docs` clean.
- [ ] CI: GitHub Actions on macOS (works today) and Linux (untested):
      install bend via `install.sh`, clang 14+, `mix test`,
      `mix format --check-formatted`, `mix compile --warnings-as-errors`.
- [ ] Linux build: drop `-undefined dynamic_lookup`, add `-lX11`/`-lasound`
      only when the emitted C includes them (as `cli_build` does), confirm
      the runtime's fixed-hint `mmap` coexists with the BEAM's allocators.
- [ ] Per-environment artifacts: `priv/bendler/<env>/` or a build-path priv,
      so `test` and `dev` stop overwriting each other.
- [x] (done) Examples moved under `test/support`; a consumer building the
      library as a dependency builds nothing of the library's.
- [x] (done) Port is the default; the README example is supervised.
- [x] (done) Atomic staging; per-app build requests; `clean` keeps requests.
- [ ] Fresh-checkout CI that also runs the consumer-app check and the
      clean-then-compile workflow.
- [ ] State the support matrix plainly: Bend 2.0.20 only, macOS arm64
      tested, Linux x86_64/arm64 CI, no Windows (Bend has none).

## 2. Lifecycle and safety (the review's open items)

- [ ] Hard cancellation for the port: a launcher that owns the OS process
      (`erlexec`-style or a tiny C wrapper), sends TERM then KILL on the
      owner's deadline, and reaps it. Today closing the port is not a kill.
- [ ] Caller death: monitor the caller of a queued port request and drop it
      from the queue; for the NIF, withdraw an unposted request (done) and
      document that a posted one runs to completion.
- [ ] NIF unload: keep the "no unload, no upgrade" contract but make it
      explicit with a `Bendler.Nif` resource whose destructor logs, and a
      `load` that refuses a second runtime in the same module.
- [ ] Runtime death policy: today the runtime freezes and keeps its threads
      and memory. Add an option to restart the module's runtime thread with
      a fresh corpus (needs the runtime's globals reset; check feasibility
      against `corpus_setup`/`pool_open`'s static `up` flag) or state that
      a dead NIF module needs a VM restart and recommend the port backend.
- [x] (done) Requests validated before dispatch; invalid ones never run a
      def. Total deadlines, monotonic waits, caller monitoring.
- [ ] Fault injection tests: OOM in the transport, a reply larger than the
      frame cap, sustained malformed input with RSS watched, allocator
      failure on each thread.
- [ ] NIF admission before the dirty scheduler (`enif_schedule_nif`) so
      `:busy` never waits for a dirty thread; default `max_waiting` from
      `enif_system_info`'s dirty scheduler count.
- [ ] Use `enif_thread_create`/`enif_mutex_*`/`enif_cond_*` and pin the
      library with a resource (see `BEAM_API.md`).
- [ ] Telemetry: `[:bendler, :call, :start | :stop | :exception]` with
      module, function, backend, queue depth, wait and run time.

## 3. Types and the BEAM API

The codec speaks U32, Nat (< 2^48), String, Bool, Unit and nested lists.
Real code needs more; each row is a Bend Base type the runtime lays out
itself, so the C side stays ignorant of user constructors.

| add | Bend | Elixir | notes |
|---|---|---|---|
| [ ] `F32` | `F32` | float | boxed `f32_unbox`; rounding is the caller's problem |
| [ ] `Char` | `Char` | integer code point | packed `CID_CHR` |
| [ ] tuples | `A & B` | `{a, b}` | `CID_TUPLE` node |
| [ ] `Maybe`, `Result` | `Maybe<..>`, `Result<..>` | `nil \| v`, `{:ok, v} \| {:error, {code, msg}}` | already how `IO.try` results look |
| [ ] bytes | `Array<U32>` or `List<U32>` of bytes | binary | today a binary becomes a `String` of code points, which is wrong for hashing, compression, wire formats; needs the block (`TAG_BUF`) layout or a `Bytes` Base type if upstream adds one |
| [ ] `Map` (string keys) | `Map<V>` | map with binary keys | Base has `new set get has del keys` |
| [ ] user datatypes | `type T is Data: K{..}` | tagged tuple or struct | generate Bend-side converters to and from a generic tree (`Bendler.Value`), never lay out user constructors in C |
| [ ] `Nat` past 2^48 | error | raise | nothing to do until the runtime grows bignats |

BEAM API from inside Bend, as foreign effects (the port has none of these
by nature; the NIF can, on the loop thread, with an independent env):

- [ ] `Beam.send(pid_handle, value)` via `enif_send` from the runtime thread:
      progress reports from long computations, streaming results.
- [ ] `Beam.log(level, String)` routed to Logger.
- [ ] `Beam.env(String)` / config reads at call time.
- [ ] Handles: a `Beam.Pid` handle law in the shim (Bend handles are
      opaque, linear words), so a pid can be passed in and used exactly
      once per effect, which is the semantics Bend wants anyway.

## 4. Concurrency and performance

- [ ] Request ids in the frame and `IO.fork` per request in the shim, so
      independent calls overlap on the event loop (the pure parts already
      run on every core). Then lift the one-in-flight limit.
- [ ] Batch calls: `Module.batch([{:f, args}, ...])` in one frame, the
      cheapest way to amortise the ~10 µs hand-off.
- [ ] Direct calls (the real NIF win): patch `comp.ts` so `compile_book`
      takes roots that are never inlined and emits per-root C entries plus
      layout descriptors; run the patched compiler under Bun; call on the
      dirty scheduler thread. Upstream the patch (WONTFIX #813 is the
      hook). Until then the NIF backend stays experimental.
- [ ] GPU: build with the `!` flags from `cli_build`, ship the `.gpu`
      sidecar beside the artifact, test one `f!(x)` export on Metal.
- [ ] A benchmark suite with `benchee`: hand-off overhead, list and string
      transfer cost per element, parallel speedup vs pure Elixir and vs the
      standalone Bend binary.

## 5. Build and developer experience

- [ ] The Mix compiler as the only path (drop the inline build), with a
      manifest that Mix's `--force` and `mix clean` respect.
- [ ] Precompiled artifacts (`rustler_precompiled`-style): download by
      target and Bend version, checksum in the repo.
- [ ] Dependencies that ship Bend code: discover `.bend` sources in deps,
      resolve `import` paths across apps, fingerprint them.
- [ ] `mix bendler.check`: run `bend --check-only` on the project's
      `PROOF.bend` so laws gate CI, which is Bend's whole pitch.
- [ ] Inline Bend, `~B"""..."""` in the module like Zigler's `~Z`, written
      to the build dir before generation.
- [ ] Signature parsing from the compiler, not a regex: `bend base --types`
      style output for a user file, or a `--json` from a small `main.ts`
      addition; until then reject what the regex cannot read (done) and
      document the accepted subset.
- [ ] Error mapping: Bend check errors reported with the user's file and
      line, not the shim's.

## 6. A real port, to learn what is missing

Pick code that is pure, terminating and numeric or string shaped, with a
small interface, and where Bend's parallelism can show. In order:

1. **Batched Levenshtein distance**, with `the_fuzz` (or `simetric`) as
   the reference. Strings in, U32 out: it fits today's types. Batch many
   pairs per call and parallelise the independent comparisons in Bend;
   verify Unicode semantics (code points, not graphemes) before claiming
   compatibility. Differential tests against the Elixir implementation.
2. **Murmur3 x86_32**, against the archived `murmur` package. Bytes in,
   U32 out, wrapping arithmetic and endianness. Needs the bytes type; it is
   the forcing function for it.
3. **ThumbHash encoding**, against `thumbhash-ex`: keep image IO in
   Elixir, port the RGBA computation. Exercises buffers and F32 precision,
   so it comes after binary and array support.
4. **A parallel numeric kernel** from Bend's own `bench/runtime/` (nbody,
   mandelbrot, k-means) exposed to Elixir and compared with `Nx` on the
   CPU. This is the "why would I do this" demo.
5. **Sorting and set operations** on `List<U32>`: Bend's bitonic sort vs
   `Enum.sort`. Tests the list transfer cost against the parallel gain.
6. Stretch: a small parser (`NimbleCSV`-sized) to see how far user
   datatypes and `Maybe`/`Result` get before the converter generator
   (track 3) is needed.

Data interoperability comes before more of the BEAM C API: keep
processes, ETS, supervision and IO in Elixir; add `F32` and buffers when a
kernel needs them; defer arbitrary terms, callbacks and native resources
until their ownership model is clear (`BEAM_API.md` has the specifics).

What each port answers: which types are missing, whether the ~10 µs
hand-off matters at that grain, and whether Bend's termination and
affinity rules make the port harder than the C it replaces.
