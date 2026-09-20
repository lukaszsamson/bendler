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
- [ ] Launcher-owned termination: own the OS process, TERM then KILL on
      the owner's deadline or death, reap it; tested after a timeout and
      after the owner dies. Closing the port is not a kill today.
- [ ] Artifacts isolated by environment and target (`priv/bendler/<env>/`
      or a build-path priv); concurrent builds tested.
- [ ] Property and fuzz tests for both codecs: truncation, nesting, frame
      limits, invalid UTF-8, malformed replies; run the C side under ASan
      in CI.
- [ ] Memory budgets, not only counts: a decoded-size budget per request
      and a sustained-overload test with RSS watched.
- [x] (done) Batched Levenshtein (`the_fuzz` as reference) with differential
      correctness tests and end-to-end benchmarks: `demos/levenshtein/lev.bend`
      (two-row DP over code points, parallel batch), `demos/levenshtein/test/lev_test.exs`
      (all `simetric` and `the_fuzz` cases, Unicode code-point checks,
      batch tests), `demos/levenshtein/bench.exs` (single short pair ~23 µs
      through the port vs ~1 µs in Elixir; 64×43-char batch ~9 µs/pair
      vs ~40 µs/pair, ~4x parallel gain). Re-measure the hand-off
      after the admission and deadline changes.
- [ ] Document the accepted signature subset, the error contract, Unicode
      semantics (code points, U+FFFD for invalid bytes) and the platform
      matrix.
- [ ] Telemetry: `[:bendler, :call, :start | :stop | :exception]` with
      module, function, backend, queue depth, wait and run time.

## 3. Next, driven by real workloads

Each row is a Base type the runtime lays out itself, so the C side stays
ignorant of user constructors.

| add | Bend | Elixir | notes |
|---|---|---|---|
| [x] bytes (done) | `B.Bytes{len, buf: Array<U32>}` from the prelude | binary | one buffer block each way; Murmur3 on 64 KB went from 8.5 ms to 0.28 ms, ThumbHash 100x100 from 10.8 ms to 5.8 ms |
| [ ] tuples | `A & B` | `{a, b}` | `CID_TUPLE` node |
| [ ] `Maybe`, `Result` | `Maybe<..>`, `Result<..>` | tagged: `{:some, v} \| :none`, `{:ok, v} \| {:error, {code, msg}}` | tagged, not `nil \| v`, so nested options stay unambiguous |
| [ ] `F32` | `F32` | float | explicit conversion, range and non-finite policies; then ThumbHash |
| [ ] `Char` | `Char` | integer code point | packed `CID_CHR` |
| [ ] `Map` (string keys) | `Map<V>` | map with binary keys | Base has `new set get has del keys` |
| [ ] user datatypes | `type T is Data` | tagged tuple or struct | generated Bend-side converters to and from a generic tree; never lay out user constructors in C |
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

GPU builds, the direct-call compiler patch (the real NIF speed-up; upstream
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
