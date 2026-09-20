# From PoC to MVP

The PoC proves the shape: a generated Bend shim serves requests from the
BEAM through three foreign effects, as a port or as a NIF. The MVP, in the
words of the second review, is **a reliable CPU port binding generator for
bounded pure functions**. NIF support stays opt-in and outside that
promise. The work falls into six tracks; the first two gate a public
release, the rest gate "usable for a real port". Items marked (done) were
closed while adopting the reviews.

## 1. Publish hygiene

- [x] (done) git, Apache-2.0 LICENSE, Hex metadata, `ex_doc`, credo and
      dialyzer configured and clean.
- [x] (done) Examples under `test/support`; a consumer building the
      library as a dependency builds nothing of the library's.
- [x] (done) Port is the default; the README example is supervised.
- [x] (done) Atomic staging; per-app build requests; `clean` keeps requests.
- [ ] `CHANGELOG.md`; a support matrix stated plainly: Bend 2.0.20 only,
      OTP 28 baseline, macOS arm64 tested, Linux via CI, no Windows.
- [ ] Pinned-toolchain CI on macOS and Linux: `install.sh` for bend, clang,
      `mix test`, format, warnings-as-errors, credo, dialyzer, plus the
      consumer-app check, the clean-then-compile workflow and the
      compiler-free release run.
- [ ] Linux build: drop `-undefined dynamic_lookup`, add `-lX11`/`-lasound`
      only when the emitted C includes them, confirm the runtime's
      fixed-hint `mmap` coexists with the BEAM's allocators, and exercise
      the NIF's monotonic condvar path with a finite timeout that succeeds
      and one that expires.

## 2. Required for the port MVP

The MVP is a reliable CPU port binding generator for bounded pure
functions. In order:

- [x] (done) Queue transitions that never strand a request: every outcome
      establishes an in-flight request, drains further, empties the queue
      or stops the owner. Queued callers monitored; total deadlines.
- [x] Launcher-owned termination: POSIX relay owns the process group,
      TERM then KILL after 200 ms on owner deadline/death, and reaps the
      worker. Tests include ignored TERM, blocked callers on owner `:kill`,
      and a worker that exits leaving a descendant holding stdout open.
- [x] Artifacts isolated by environment and target
      (`priv/bendler/<target>/<env>/`); concurrent builders serialize with
      clean under a filesystem lock. A consumer release runs without Bend
      on PATH. Abandoned locks require manual recovery (see CONTRACTS.md).
- [x] Property/fuzz tests for both codecs: deterministic truncation,
      nesting, frame caps, invalid UTF-8 and malformed replies. Local ASan
      passed 100 composite cycles plus 500 fuzz frames. The checksum-pinned
      macOS/Linux CI workflow runs it too; remote CI has not yet been run.
- [x] Decoded-size admission budgets (64 MiB native/host default) and a
      sustained 2,560-call overload/RSS check. This is not an OS RSS cap;
      user computations and allocator retention are outside codec budgets.
- [x] (done) Batched Levenshtein (`the_fuzz` as reference) with differential
      correctness tests and end-to-end benchmarks: `demos/levenshtein/lev.bend`
      (two-row DP over code points, parallel batch), `demos/levenshtein/test/lev_test.exs`
      (all `simetric` and `the_fuzz` cases, Unicode code-point checks,
      batch tests), `demos/levenshtein/bench.exs` (single short pair ~23 µs
      through the port vs ~1 µs in Elixir; 64×43-char batch ~9 µs/pair
      vs ~40 µs/pair, ~4x parallel gain). Re-measured after launcher,
      telemetry and budget checks: short call 48 µs; medium 64-pair batch
      9.6 µs/pair vs Elixir 37.8 µs/pair. These are local averages, not
      universal latency claims; batching remains important.
- [x] Document the accepted signature subset, the error contract, Unicode
      semantics (code points, U+FFFD for invalid bytes) and the platform
      matrix in `docs/CONTRACTS.md`.
- [x] Telemetry: `[:bendler, :call, :start | :stop | :exception]` with
      module/function/backend and end-to-end duration; Port completions add
      queue depth, wait and dispatch-to-reply time. NIF wait/run split is
      deliberately not fabricated. Arguments/results are not emitted.

## 3. Next, driven by real workloads

Prefer Base types with compiler-defined canonical boxing, plus the controlled
Bytes prelude. Arbitrary user constructors still need generated converters.

| add | Bend | Elixir | notes |
|---|---|---|---|
| [x] bytes (done) | `B.Bytes{len, buf: Array<U32>}` from the prelude | binary | one buffer block each way; Murmur3 on 64 KB went from 8.5 ms to 0.28 ms, ThumbHash 100x100 from 10.8 ms to 5.8 ms |
| [x] tuples | `A & B`, `A & B & C` | `{a, b}`, `{a, b, c}` | 2–16 fields; parentheses preserve nesting; canonical Base Tuple nodes |
| [x] `Maybe`, `Result` | `Maybe<T>`, `Result<E, T>` | `{:some, v} \| :none`, `{:ok, v} \| {:error, e}` | recursively composable; errors are arbitrary supported values; tested on both backends; see TYPES.md |
| [x] `F32` | `F32` | float | doubles round to the nearest single, past the single range raises; `:nan`, `:infinity`, `:neg_infinity` cross both ways; the term is the bare IEEE word |
| [x] `Char` | `Char` | integer code point | a bare word at runtime (`Chr` is a newtype), so the same 4 bytes as `U32` under tag 14; the code-point range is validated on both sides |
| [x] `Map` (string keys) | `Map<V>`, `Map<&2, V>` | map with valid UTF-8 binary keys | crosses as `List<Sigma<&2, &k, String, _ => V>>`; the shim wraps the call in `Map.from_list`/`Map.to_list`, so C never sees the trie. Whole parameter or result only; invalid UTF-8 keys are rejected to avoid collisions |
| [x] user datatypes | `type T is Data:` / `is Type:` | `{:ctor, fields...}`, `:ctor` when nullary | the prelude's `Dyn` tree is what C builds and reads; the shim gets generated `Bendler.to_T`/`of_T` converters (one fused def per type recursing on fuel, since Bend forbids mutual recursion). Rules: no type parameters, no Map field, self-reference only as `T`, `List<T>`, `Maybe<T>`, no mutual types, some finite constructor. A 4093-node tree round-trips in 3.6 ms through the port |
| [ ] `Nat` past 2^48 | error | raise | nothing to do until the runtime grows bignats |

Also: compiler diagnostics mapped to the user's file and line, Bend
sources in dependencies, and a `mix bendler.check` that runs
`bend --check-only` on `PROOF.bend` in CI.

## 4. Separate experimental NIF roadmap

Outside the MVP promise; `BEAM_API.md` has the API specifics.

- [x] (done) Monotonic condvar clock on Linux; wake-up bytes drained
      before parking, so a request withdrawn on deadline leaves no stale
      readable pipe.
- [ ] Actual library pinning: a resource that owns the runtime, whose
      destructor covers every thread; until the runtime can stop and join
      its threads, document that loading pins nothing.
- [ ] Checked initialisation: fail `load` when the runtime cannot start.
- [ ] Cheap admission on the normal scheduler (`enif_schedule_nif`), with
      the dirty scheduler count from `:erlang.system_info/1` in `load_info`.
- [ ] A deadline measured from the caller's side (`enif_monotonic_time`),
      not from after validation and scheduling.
- [ ] Asynchronous delivery (`enif_send` from the runtime thread) with
      explicit ownership and caller monitoring.
- [ ] A tested purge and shutdown policy.

## 5. Deferred

GPU-shaped kernels (the lane itself builds and runs through a port; the
ray tracer demo shows why a scene-as-list kernel does not gain from it),
the direct-call compiler patch (the real NIF speed-up; upstream
WONTFIX #813 is the hook), an inline `~B` sigil, arbitrary BEAM effects
from Bend, and more than one request in flight (`IO.fork` alone is not
enough while the codec's cursor is global).

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
   the forcing function for it. (done: `demos/murmur3/murmur.bend` takes bytes as
   `List<U32>` — the interim convention, no codec change — with a
   parallel `batch_murmur3/2`; `demos/murmur3/test/murmur_test.exs` reuses every
   x86_32 known answer and boundary vector plus differential fuzz;
   `demos/murmur3/bench.exs` shows hand-off-dominated singles and the
   list-transfer cost that the track-3 bytes row must remove. Bytes added
   since: `murmur3/2` over `B.Bytes` hashes 64 KB in 0.28 ms against
   8.5 ms as a list and 0.57 ms in Elixir.)
3. **ThumbHash encoding**, against `thumbhash-ex`: keep image IO in
   Elixir, port the RGBA computation. (done: `demos/thumbhash/`, bytes as
   `List<U32>` both ways, floats inside Bend as `F32`. Differential tests
   against a verbatim copy of the reference found two bugs in the
   reference itself: the alpha channel is encoded without `w`/`h` and
   crashes on any transparent image, and operator precedence puts both
   flag bits in bit 0 instead of bits 15 and 23; the copy fixes both. F32
   against doubles: most hashes exact, the rest one quantisation step off
   where a coefficient sits on a rounding tie, so a precision policy or
   `F64` is the ask. Speed: 100x100 in 10 ms through the port against
   45 ms for the Elixir reference; a batch of 32 small images loses to
   `Task.async_stream` (16 ms vs 11 ms) because 130 KB of pixels cross as
   list cells each way, the same list-transfer cost Murmur3 measured. With
   the pixels as `B.Bytes`: 100x100 in 5.8 ms, and the batch of 32 in
   9 ms against 18 ms for `Task.async_stream`.)
4. **A parallel numeric kernel** from Bend's own `bench/runtime/` (nbody,
   mandelbrot, k-means) exposed to Elixir and compared with `Nx` on the
   CPU. (done: `demos/mandelbrot/` adapts the upstream fixed-point
   histogram/recolour checksum, with five tests including the full
   4096x4096 known answer, an independent Elixir reference, and a separate
   pinned Nx/EXLA host-CPU benchmark. At 262,144 pixels / 31 iterations on
   M2 Pro: Elixir 568.7 ms; Bend Port 59.4 / 15.2 / 7.9 ms with 1 / 4 / 12
   threads; Nx/EXLA 8.4 ms. Small strips, not resized full images; Nx caches
   escape times whereas upstream Bend recomputes them. See the demo README
   for methodology and limitations. No new codec types were needed; GPU
   binding builds remain deferred.)
5. **Sorting and set operations** on `List<U32>`: Bend's bitonic sort vs
   `Enum.sort`. (done: `demos/sorting/` adapts the upstream tree-bitonic
   network to arbitrary-length lists, with unique/union/intersection/left
   difference and four differential tests. Five-sample CPU benchmarks on
   M2 Pro: random 32,768-element sort takes Enum 2.2 ms vs Bend 29.6 / 44.1 /
   50.0 ms with 1 / 4 / 12 workers; one-worker identity round trip is 7.9 ms.
   MapSet plus sorted output also wins all measured set operations. Keep
   these workloads in Elixir; investigate fork granularity, list/tree
   allocation and packed U32 buffers before expecting a parallel gain.
   No codec or GPU extension was needed; see the demo README for caveats.)
6. **Small CSV parser** (done: `demos/csv/`), based on NimbleCSV's eager,
   byte-oriented semantics. Delimiters use Maybe; results carry nested lists
   of Bytes plus a tuple row count, or a structured error tuple. Differential
   fixtures and generated tables pass. This is a bounded subset, not a
   replacement for NimbleCSV's streaming/configurable parser. At 10,000 rows,
   NimbleCSV wins: plain 5.7 vs 28.4 ms, quoted 35.2 vs 98.1 ms. No additional
   user-datatype converter was needed: private parser state stays in Bend.

7. **A raytracer whose scene is a user datatype** (done: `demos/raytrace/`;
   GPU lane added since: the port builds with Bend's Metal lane and ships
   `<exe>.gpu`, `gpu: :on` runs the `!` defs on the device, the upstream
   kernel bit-exact and 78 vs 88 ms at 2^10 x 1600, but this demo's
   list-of-spheres renderer is 50x slower per pixel on the device (62 ms
   at best for 640x480 against 27 ms on the CPU pool), a spine of forks
   under a bang segfaults the runtime (reduced and reported as
   bendlang/bend#918; a balanced tree fixes it and halves the CPU time
   too) and a 1920x1200 bang trips the macOS GPU watchdog: a GPU-fast
   kernel is a different shape, bendlang/bend#828),
   the first port whose arguments are `type ... is Data` values: a `Scene`
   of `Sphere{center: Vec, radius, color: Vec, mirror}` crosses in and
   0.88 MiB of packed RGB `B.Bytes` comes back, with `render_tiles`
   forking the tiles and each tile forking its rows. Bend's own
   `bench/runtime/raytrace` float kernel is kept verbatim as
   `upstream_checksum`, whose `(6, 80)`, `(3, 40)` and `(7, 123)` answers
   (402971, 19281, 1245125) are pinned bit-exactly; an independent Elixir
   reference in doubles differs on 0.16% of channels, mean 0.0029, worst
   6/255, on silhouettes and shadow edges. On M2 Pro, 640x480: Bend Port
   136 / 39 / 27 ms with 1 / 4 / 12 threads (1920x1200: 1088 / 345 /
   233 ms), against about 2 s for the Elixir reference (measured
   127.2 ms at 160x120 against Bend's 3.6 ms, 35x). The same image with
   no spheres at all still took 24 ms of the first version's 40, so a
   large share of a render is building and moving the pixel buffer, not
   tracing: the serial tail is why scaling stops at 5x. The first version
   forked tiles as a spine and got slower with bigger batches; the
   balanced tree makes batch size free. Three library frictions found: a
   multi-line def signature is silently unexportable, the generated
   `@type` per datatype collides with a hand-written one, and a tuple is
   `Type`-kinded so it cannot sit in a `List<&2, _>`. No codec change was
   needed. `:timeout` is demonstrated end to end (the owner stops, the
   supervisor replaces it, the next call works).

Data interoperability comes before more of the BEAM C API: keep
processes, ETS, supervision and IO in Elixir; add `F32` and buffers when a
kernel needs them; defer arbitrary terms, callbacks and native resources
until their ownership model is clear (`BEAM_API.md` has the specifics).

What each port answers: which types are missing, whether the ~10 µs
hand-off matters at that grain, and whether Bend's termination and
affinity rules make the port harder than the C it replaces.
