# Validation

What is checked, what is known to be imperfect, and what is not covered.

## The test suite

`mix test` runs the library suite and every demo's tests against real Bend
programs built by the real toolchain. There are no mocks of the transport.

**Signatures and generation.** Exportable defs, skipped defs and the reason
each was skipped, trailing comments, signatures spanning lines, and
rejection of def names that collide after `.` becomes `_` or of a generated
`_stream` name that collides.

**Codec.** Round trips for every type, including nested and empty lists,
tuples, Maybe, Result, F32, Char, Map and user datatypes; range checks;
decoded-memory amplification; malformed, truncated and over-nested values;
oversized frame headers and item counts; invalid UTF-8 map keys; trailing
bytes; and a successful call after a refusal.

**Port lifecycle.** Every type across the transport, concurrent callers,
bounded admission with `max_queue`, a deadline that stops the owner with
`{:shutdown, :timeout}` while queued callers get `:exited`, supervised
replacement serving the next call, a well-framed but invalid request
answered with an error frame while the worker survives, and queued callers
failing when the port dies.

**Launcher.** A deliberately uncooperative CPU worker is terminated and
reaped after a deadline and after untrappable owner death. A blocked caller
gets `{:error, :exited}` rather than an exit signal. Another fixture exits
its group leader but leaves an ignoring descendant holding stdout: the
launcher observes the exit with `waitid(..., WNOWAIT)`, kills the group
while the leader PID is still reserved, then reaps and drains output, so it
neither signals a recycled process group id nor orphans descendants. A
regression test covers preserving the worker's exit status when the worker
closes stdin while request bytes are still pending.

**Events.** Ordering, decoding and type checking against the emitter's
declared type; a corrupt event body (bad tag, trailing bytes, a well-formed
value of the wrong type) raising `Bendler.Error`; one-outstanding
backpressure observed with `refute_receive` while a consumer is paused;
early halt with `Enum.take/2`; a consumer exception; a consumer killed
mid-stream; a deadline firing during an acknowledgement wait; killing the
port mid-stream; and a plain call of an emitter export declining the first
event.

**Ask callbacks.** Typed requests and responses, handler failures, invalid
handler returns, handler timeout, direct same-worker reentry, caller death,
the total deadline, supervised recovery on the port, and typed `Result.Fail`
remaining ordinary data.

**NIF.** Generated functions and docs, every marshalled type through the
native codec, a parallel call, reference-preserving replies, expired
deadlines, time spent before encoding, cancellation of queued and of
running work, bounded admission, caller death, large finite timeouts, an
invalid request refused on the calling thread before anything reaches the
runtime, a request withdrawn before the loop picked it up leaving the loop
parked cleanly, and a `Nat` overflow freezing one module while another NIF
module keeps working. Event tests add typed scalar, tuple and datatype
events, paused consumers, cancellation races, stale acknowledgements,
native deadlines and fatal-module isolation.

**Demos.** Each demo carries differential tests against an independent
reference: NimbleCSV for the CSV parsers (fixed cases, all 781 strings of
length 0 to 4 over quote, comma, CR, LF and `a`, and 40 generated tables,
including invalid UTF-8 and embedded newlines), an Elixir reference plus
upstream checksums for Mandelbrot and the raytracer, `Enum.sort` and
`MapSet` for sorting, and verbatim reference copies for Murmur3 and
ThumbHash. The streaming CSV tests run both backends over every two-part
split of representative fixtures, one-byte chunks, concurrent cursors,
lazy reads, source and consumer failures, early halt, maximum-size records
and reuse after errors.

Floating-point results are compared exactly where the algorithm allows it:
the raytracer pins three upstream checksums bit for bit, and only the
comparison against a double-precision Elixir reference uses a tolerance,
with the actual figures printed.

## Static checks

- `mix format --check-formatted`
- `mix credo --strict` over the full default check set with a 120-column
  line limit
- `mix dialyzer` with `unmatched_returns`, `missing_return` and
  `extra_return`
- `mix compile --warnings-as-errors` and `mix test --warnings-as-errors`
- `mix docs --warnings-as-errors`

## CI

`.github/workflows/ci.yml` runs on macOS 15 arm64 and Ubuntu 24.04 x86_64.
Bend 2.0.20 and LLVM clang 21.1.8 are installed from release archives with
pinned SHA-256 checksums, OTP is 28.1, Elixir is 1.20.3, actions are
commit-pinned and dependencies are locked. Both jobs are green at HEAD.

Each job runs, in order: the toolchain check, `mix deps.get`, formatting,
compilation with warnings as errors, the test suite, strict Credo,
Dialyzer, docs, then:

- **AddressSanitizer probes** on the external port:
  `demos/csv/check_asan.exs` (100 composite and malformed-request cycles
  plus deterministic fuzz frames), `check_stream_asan.exs` (partitioned
  round trips, a 64 KiB record and error recovery) and `check_ask_asan.exs`.
- **Sustained overload and RSS observation**, `scripts/check_overload.exs`:
  40 waves of 64 calls with one worker thread and a queue limit of four,
  sampling worker and BEAM RSS and checking retained worker growth against
  a 128 MiB regression threshold. RSS sampling is observational, includes
  unrelated VM state and can miss short peaks; it is not a production
  memory limit.
- **Port cancellation and large-frame transport stress**,
  `scripts/check_port_transport.exs`.
- **A compiler-free consumer release**, `test/release_smoke.sh`: the
  release calls into the artifact with Bend absent from `PATH`.
- **The real Hex package in a fresh consumer**, `test/package_smoke.sh`:
  the tarball is built, unpacked outside the checkout, and a new project
  builds, cleans, rebuilds and releases against it.
- **Isolated NIF probes** in disposable BEAM processes:
  `check_nif_lifecycle.exs` (a refused replacement load, the original
  binding still callable, work submitted, the module deleted and soft
  purged, the native result received after the purge, and `:init.stop()`
  exiting cleanly), `check_nif_init.exs` (fault-injected libraries rejecting
  initialization before any thread is created, and after a thread exists but
  before readiness) and `check_nif_scheduler.exs` (saturation with one dirty
  CPU scheduler, a blocking NIF's liveness verified before it is killed, and
  a caller killed during queued validation leaving no reserved admission).

These probes establish pinning, refused upgrade and clean VM exit. They do
not establish graceful thread joins.

## The sanitizer approach

The ASan probes build a separate instrumented port executable from the
generated C and drive it from Elixir. Instrumentation stays enabled across
the codec and the runtime. The instrumented copy, and only it, disables
Bend's `PRESERVE` calling-convention attributes: an ASan-instrumented
`preserve_none` machine segment clobbers the arm64 register holding
`corpus_eval`'s spill-frame address, which is then reloaded as a null
`Corpus` argument. The normal generated shim and the NIF keep the
`PRESERVE` attributes. Leak detection is off.

This is external-port coverage only. It is **not** sanitizer coverage of a
NIF loaded into the BEAM, and no UndefinedBehaviorSanitizer result is
claimed.

## Known issues

- **Rare port exit status 74 in full-suite runs.** Transport exits with
  status 74 have been observed in whole-suite runs, and their cause was not
  established. Targeted reruns of the event and Murmur suites across ten
  seeds did not reproduce them.
- **A launcher EPIPE race is fixed.** A worker that closed stdin after
  POLLOUT became ready, then exited 65, could have its status masked as 74
  by the launcher's own write failure. The launcher instead stops forwarding
  input, drains output and reports the worker's real status, pinned by a
  deterministic regression test. This fix does not account for the
  unexplained failures above.
- **The PRESERVE attribute workaround** above is an instrumentation
  compatibility adjustment, not a diagnosis of a bug in Bend's generated
  code.

## Not validated

- Long soak runs, and memory growth over hours of calls or events.
- Hostile worker output beyond the frame cap.
- CUDA, and any headless or CI Metal device. GPU results come from a local
  macOS arm64 machine with a visible device.
- Windows, and targets other than macOS arm64 and Linux x86_64.
- NIF unload, upgrade and hard cancellation, which are unsupported by
  design.
- More than one request in flight per module.
- Broad Mix dependency version ranges: only the pinned toolchain above has
  been exercised.
