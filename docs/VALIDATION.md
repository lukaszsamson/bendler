# Validation record

## 2026-09-21: remove the admission/deadline test race

[CI run 35612050570](https://github.com/lukaszsamson/bendler/actions/runs/35612050570)
passed the complete Ubuntu job, including the new package and transport-stress
checks. macOS passed 198/199 tests; the combined admission/deadline test expected
`:busy` but saw `:exited`. It arranged callers with two 20 ms sleeps while a
150 ms owner deadline was active, allowing scheduler delays to invalidate the
assertion. This was not a reported transport status-74 failure.

The admission and worker-death tests now disable deadlines and inspect the
actual in-flight/queued caller identities before proceeding. A separate test
retains a real finite timer and asserts `:timeout`, owner shutdown and supervised
recovery. Invalid-frame checks use a longer independent timeout. Production
timeouts and admission semantics are unchanged; no alternative error is accepted
to make the busy assertion pass.

Local validation: the targeted module passed 22 tests, and the full suite passed
**200 tests** with the failing seed 616945, three BEAM schedulers (`+S 3:3`) and
`--max-cases 6`. Formatting and strict Credo passed.

## 2026-09-21: release confidence and status-74 investigation

Local macOS arm64, Bend 2.0.20, Elixir 1.20.3, OTP 28:

- Before transport changes, the event and Murmur suites passed all ten seeds
  (123, 999157, 1–8): 260 tests. The historical failures did not reproduce.
- A separate controlled poll/write race did reproduce against the committed
  launcher: a worker closes stdin after POLLOUT becomes ready, then exits 65.
  A test-only write delay exposes EPIPE; the old launcher terminates with 74
  instead of reporting 65. The fixed launcher stops forwarding input, drains
  output and collects the worker's status. Its regression and the three existing
  launcher lifecycle tests pass. No timing hook is in the production launcher.
- Relay diagnostics now identify the endpoint and errno or poll flags; observed
  nonzero worker exits identify the worker status separately. Worker read/write
  diagnostics include errno (including EPIPE), and stdin nonblocking setup is
  checked. These logs contain no request/response payloads.
- Full `mix test --warnings-as-errors` with seeds **123 and 999157**:
  **199 passed each**. The final race regression also verifies that a worker's
  last output frame is delivered after its input closes.
- `scripts/check_port_transport.exs`: **200 rounds**, concurrently exercising
  early stream halt, consumer exceptions/death and Murmur batch frames spanning
  4 KiB and 64 KiB boundaries. Results match the Elixir reference, the event
  worker remains usable, and no failures are retried. The probe is now in CI.
- `test/package_smoke.sh` builds the actual Hex tarball and unpacks it outside
  the checkout. A fresh consumer uses only that unpacked Bendler source,
  compiles, cleans/rebuilds, and runs the assembled release with Bend absent
  from PATH. The harness supplies its fixture and local telemetry dependency;
  it neither downloads dependencies nor publishes a package. This is now in CI.
- The supported CPU Port surface is frozen in API.md; MVP.md is a release
  checklist rather than a history of already-completed feature proposals.
- Core strict Credo plus explicit stress-script lint, formatting, dev/library
  Dialyzer (zero errors) and ExDoc warnings-as-errors passed. The CSV ask ASan
  harness passed repeated callbacks, reallocations, typed errors, reuse and
  malformed replies with the updated Port transport.

**Still unresolved:** the original event/Murmur status-74 failures cannot be
attributed to the reproduced exit-status masking race. The latter requires a
worker input close; it does not explain why a healthy worker would close input.
Do not describe the historical failures as fixed. Retain this release gate until
there is a diagnosis or an explicit release-risk decision. Updated CI has not
yet run on these uncommitted changes; local tests do not establish Linux results.

## 2026-09-21: typed NIF ask callbacks

On the same local macOS arm64 toolchain as below:

- Full `mix test --warnings-as-errors --seed 123`: **198 passed**. Eight NIF
  ask tests replace the old NIF-ask rejection test and cover repeated callbacks,
  direct reentry, CSV tuple/Result/Maybe/Bytes responses, stale sequence,
  foreign owner, malformed native replies, handler errors and invalid values,
  total/handler deadlines, caller death, handler cleanup and module isolation.
- Failed or abandoned asks freeze their module intentionally: the runtime has
  no safe typed request unwind. Tests confirm a separate module keeps serving.
  Typed CSV file errors remain normal data and subsequent calls succeed.
- Strict core and explicit nine-file demo Credo, dev/library Dialyzer (zero errors), root and explicit demo
  formatting, documentation warnings-as-errors, isolated lifecycle,
  initialization-failure and scheduler-admission checks passed.
- The final rebuild again passed all 198 tests; the extended isolated lifecycle
  probe confirms typed ask calls survive a refused upgrade. The Port ask ASan
  harness passed repeated callbacks, input reallocations, typed errors, reuse
  and malformed-reply refusal. This is not NIF sanitizer coverage.
- Five warm CSV samples, 100k rows / 233 asks / 16 KiB chunks: NimbleCSV
  77.602 ms, host-driven Port 340.329 ms, ask-Port 214.994 ms, ask-NIF 229.942 ms.
  All aggregates agree. See `demos/csv/ASK.md` for the smaller size and method.

This adds no NIF sanitizer/soak evidence or Linux evidence. The historical
unexplained Port status-74 failures below remain unresolved; this passing run
does not establish their cause or fix them.

## 2026-09-21: experimental NIF emit streams and particle demo

Local macOS arm64 / Apple M2 Pro, Bend 2.0.20, Elixir 1.20.3 and OTP 28:

- Final full `mix test --warnings-as-errors --seed 123`: **191 passed**.
  Fourteen added tests cover NIF events and the particle demo. Event tests cover
  pure/IO-only/plain calls, scalar/tuple/datatype payloads, ordering, backpressure,
  early halt, consumer exceptions, repeated enumeration, caller death, native
  paused deadlines, lazy admission, stale/duplicate acknowledgements, 100
  cancellation races, bounded admission and fatal-module isolation.
- The native deadline test initially failed. Tracing showed
  `enif_monotonic_time` returning `ERL_NIF_TIME_ERROR` on the Bend pthread.
  Admission now translates the BEAM deadline into OS monotonic time on the
  scheduler. The parked-deadline test passes without any consumer ack/wake.
- Port/NIF particle snapshots are identical, and a single oscillator agrees
  with the integration rule. A 16-particle, 180-tick SVG was generated and
  rasterized for visual inspection. Output is streamed, not accumulated.
- Five warmed 2,000-event samples: scalar pulse 20.49 µs/event via Port versus
  11.50 via NIF; 64-particle snapshots 245.89 versus 243.05 µs/event. Payload
  counts/checksums and final results agree. File output is excluded. Full
  methodology and cancellation-barrier timings are in `demos/particles/README.md`.
- Dev/library Dialyzer: zero errors. Core strict Credo and explicit linting of
  six demo files passed. Formatting and documentation with warnings as errors
  passed. The demo modules are test-only and not part of dev Dialyzer analysis.
- Isolated lifecycle script: original calls and both pre-created/new streams
  survive refused upgrades; active-work reply after purge and normal VM exit
  pass. Lazy closures stay in the stable helper module. Initialization failure
  probes and scheduler saturation/reserved-admission cleanup pass. The init
  probe was updated to declare the two new native entry points.

**Unresolved Port flake:** two earlier full runs each saw an exit status 74,
once in event early cancellation and once in Murmur batch hashing. The event
test passed two isolated reruns; full-suite seeds 999157 and 123 subsequently
passed (the final 191-test run used 123). No cause was established and no Port
transport fix is claimed. This must not be described as repeated clean runs.

No remote CI/Linux run, NIF sanitizer instrumentation, long-duration soak or
hard-cancellation guarantee is claimed. At this earlier checkpoint NIF ask
callbacks were out of scope (now added above); concurrent effect
activations, windowed acknowledgements and safe unload remain out of scope.

## 2026-09-21: review fixes and Port ask callbacks

Local macOS arm64, Apple M2 Pro, Bend 2.0.20, Elixir 1.20.3 and OTP 28:

- Full `mix test --warnings-as-errors`: **177 passed** (16 added tests).
- Regression tests reproduce the suspended-stream owner-replacement case,
  reject generated `_stream` name collisions, and preserve APNG repeat counts.
- Ask tests cover typed Maybe replies, repeated callbacks, handler exceptions,
  invalid returns, direct reentry rejection, total and independent handler
  deadlines, caller death, brutal owner death and malformed native replies.
- CSV tests compare aggregates against NimbleCSV at arbitrary chunk boundaries,
  exercise typed read failures, EOF, malformed CSV, record caps and ask fuel.
- Root strict Credo plus an explicit check of five changed demo/script files
  passed. Dev/library Dialyzer reported zero errors; this does not type-check
  the test-only demo modules. Root formatting and docs with warnings as errors
  passed; demo Elixir files were formatted explicitly.
- `check_ask_asan.exs` passed: repeated small replies, a 64 KiB reply forcing
  input-buffer growth, EOF, typed errors, reuse, and malformed response rejection
  before decoding. The intentional malformed reply exits the worker with 65.
  An initial harness cleanup race after that deliberate exit was corrected;
  the final script exits successfully. No ASan diagnostic was produced.
  Like the existing probes, this disables PRESERVE only in the instrumented
  copy and disables leak detection. It is not a NIF sanitizer test.
- Five warmed samples at 16 KiB chunks, one worker, file IO included:
  100k rows took 85.805 ms in NimbleCSV, 265.978 ms in host-driven Bend Port,
  and 193.700 ms in ask-driven aggregation. All returned identical totals.
  The refactored benchmark was also smoke-tested. Full methodology and the
  10k-row measurements are in `demos/csv/ASK.md`.

No Linux or remote CI run was performed for these changes. CI now includes
the ask ASan probe. NIF events/callbacks, ask+emit in one export, indirect
callback-cycle detection and long-duration memory measurements remain deferred.

## Earlier validation

Observed 2026-09-20 on macOS arm64 (Apple M-series, 24 schedulers), Bend
2.0.20 at `~/.bend/bin/bend` (checkout `7561656…`), Elixir 1.21.0-dev on
OTP 28 (erts 16.4.0.1), Apple clang 21. A smoke test of compatibility and
behaviour, not a benchmark or a safety certification.

## Test suite

`mix test`: **46 tests, 0 failures** (19 core, 27 across the three demos), repeated runs with random seeds.
Coverage:

1. Signature parsing: exportable defs, skipped ones with reasons, trailing
   comments, multi-line signatures reported, `a.b`/`a_b` collision refused.
2. Codec round-trips for every type including nested lists; range checks;
   a list count past the binary refused; error frames carry a message.
3. NIF: generated functions with docs; every marshalled type; empty and
   nested lists through the native codec; a parallel call; Elixir-side
   argument checks; 16 callers at concurrency 4 all served, 32 callers of a
   slow def get a mix of results and `:busy`; a 150 ms deadline abandons a
   slow request, the runtime finishes it and later calls work; a `Nat`
   overflow freezes that module's runtime (`:dead`) while another NIF
   module keeps working.
4. Port: every type, nested lists, concurrent callers; with `max_queue: 1`
   and a 150 ms deadline: one in flight, one queued, the third `:busy`, the
   deadline stops the owner with `{:shutdown, :timeout}`, the queued caller
   gets `:exited`, the supervisor's replacement serves the next call; a
   well-framed but invalid request (wrong type, trailing bytes, unknown
   index) is answered with an error frame and the worker serves the next
   call; queued callers get `:exited` when the port dies.
5. The NIF refuses an invalid request on the calling thread with the
   reason text, before anything reaches the runtime.
6. A NIF request posted but never picked up before its deadline is
   withdrawn, and the loop parks cleanly afterwards and serves again.

## Bytes

`B.Bytes` round-trips through both backends: sums, reversal and indexing
on small binaries and on 100 KB of random bytes; a list where a binary is
declared is refused on the Elixir side. Benchmarks (`demos/*/bench.exs`):

| workload | List<U32> | Bytes | Elixir |
|---|---|---|---|
| Murmur3, 5 B | 11.8 µs | 8.9 µs | 0.1 µs |
| Murmur3, 64 KB | 8.5 ms | 0.28 ms | 0.57 ms |
| ThumbHash 100x100 | 10.8 ms | 5.8 ms | 26 ms |
| ThumbHash 32x32, batch of 32 | 16 ms | 9 ms | 18 ms (`Task.async_stream`) |

## Static checks

`mix credo --strict` runs the full default check set (69 checks) with a
120-column line limit and reports no issues; `mix dialyzer` with
`unmatched_returns`, `missing_return` and `extra_return` reports none;
`mix compile --warnings-as-errors` and `mix format --check-formatted`
pass.

## Build workflows

- `MIX_ENV=test mix bendler.clean` then `mix compile` rebuilt all four
  artifacts (the review's R1: previously it built none).
- A separate Mix application (`scratch/consumer`) with `{:bendler, path:
  "../.."}` and the `:bendler` compiler built exactly one artifact, its own
  `consumer_calc`, and `Consumer.Calc.add(20, 22)` returned 42 through the
  port. The dependency's own `priv/bendler/` still shows this repository's
  test artifacts because Mix symlinks a project's `priv/` into every
  environment's build; nothing from it is built by the consumer.

The line `bendler: stdout write failed` on stderr during the suite is the
port worker exiting after its owner closed the port on a deadline; `bend: a
Nat past the largest immediate 2^48-1` is the overflow test.

## Sanitizer

The port program was rebuilt from the test build directory with
`-fsanitize=address` and driven from Elixir with `nest([])`,
`nest([[], [1], []])`, `words("")`, `range(0, [])` and a frame whose list
count (100000) exceeds its bytes. All four calls answered correctly with
no sanitizer report; the lying count exited 65. This exercises the fix for
the empty-list type scanner that an independent review reproduced with ASan on the
previous version.

## Concurrency trace

Instrumenting the NIF transport (stderr prints on post, take, reply, done)
with 4 concurrent callers showed reply 6 overwritten by reply 7 before
caller 6 reacquired the mutex. After giving each call its own slot, five
rounds of 16 calls at concurrency 4 completed; the instrumentation was
removed.

## Release

`MIX_ENV=prod mix release` built `_build/prod/rel/bendler`. Running its
`eval` with `PATH=/usr/bin:/bin` (no `bend`) called
`Bendler.Examples.FibNif.fib(30, 0, 1)` → 832040 and, after
`FibPort.start_link/0`, `FibPort.words("a b")` → `["a", "b"]`. The build
is not invoked at runtime. Note that the release's `priv/bendler/` also
contained the test-only modules' artifacts, because Mix shares the
project's `priv/` across environments.

## Measurements

From `mix run scratch/bench.exs` (2000 warm calls averaged; one timed
`pow2(24)`), before the admission and deadline changes:

| call | NIF | port |
|---|---|---|
| `is_big(5)` | 10.3 µs | 9.7 µs |
| `fib(90, 0, 1)` | 14.6 µs | 12.1 µs |
| `range(1000, [])` | 69 µs | 65 µs |
| `pow2(24)` | 9 ms | 8 ms |

## Not validated

Linux; GPU programs; hostile worker output beyond the frame cap; memory
growth under sustained load; unload or upgrade of a NIF module (unsupported
by design); hard cancellation; more than one request in flight; concurrent
builds; per-environment artifacts.

## CSV and composite types (2026-09-20)

Final full suite: **65 tests passed**. Compilation with warnings-as-errors,
formatting of changed Elixir files, targeted strict Credo (10 files), Dialyzer
(zero errors) and documentation generation with warnings-as-errors passed.
The full test run still prints an existing unused `require Bitwise` warning
from the ThumbHash test file, which this change does not modify.

Added native Port and NIF coverage for 2–16-field tuples, explicitly nested
tuples, Maybe, Result, Bytes inside variants, empty nested lists and both
Result branches. Malformed arities, tags, missing payloads and trailing bytes
are rejected without poisoning the runtime. Result failures return data;
transport-error frames still raise and cannot appear inside composite values.

The CSV demo uses NimbleCSV 1.3.0 as an eager-parser oracle. It checks binary
preservation, CRLF, multiline quotes, escaped quotes, both header policies,
structured errors and recovery. Forty generated tables round-trip through
NimbleCSV's dumper, and all 781 length-0–4 inputs over quote/comma/CR/LF/a
agree on acceptance and successful values. The input wrapper caps input at
1 MiB; the raw generated function does not impose that demo-specific cap.

Commands: `mix test`; `mix credo 'lib/bendler/{sig,gen,codec}.ex'
test/composite_test.exs test/support/composite.ex 'demos/csv/**/*.{ex,exs}'
--strict`; `mix dialyzer`; `mix docs --warnings-as-errors`.

`MIX_ENV=test mix run demos/csv/check_asan.exs` passed 100 cycles against an
AddressSanitizer-instrumented external port, including empty composite lists,
nested options/Bytes, Result errors, user datatypes and malformed frames. Leak
detection is disabled because runtime teardown is not validated. This is not
NIF sanitizer coverage. A historical combined ASan/UBSan run, before the
calling-convention diagnosis below, stopped in generated runtime `root_done`;
it has not been rerun, so the Bend runtime is not claimed UBSan-clean.

Five-sample CPU benchmark results and limitations are in
`demos/csv/README.md`. NimbleCSV won every measured case. No Linux, streaming,
GPU or arbitrary-user-datatype claim is made by this demo.

## F32, Char and Map (2026-09-20)

Full suite: **70 tests passed**; warnings-as-errors, format, credo
(strict), dialyzer and `mix docs --warnings-as-errors` clean.

| check | port | NIF |
|---|---|---|
| `half(3.0)`, `half(0.1)` rounds to single, `-1.0e-45` underflows to `-0.0` | yes | yes |
| `1.0/0.0`, `-1.0/0.0`, `0.0/0.0` come back as `:infinity`, `:neg_infinity`, `:nan`; the atoms go in too | yes | yes |
| `upper(?a)`, an astral code point, `String.to_list` as a charlist, a charlist back to a String | yes | yes |
| `tally` builds a `Map<&2, U32>` in Bend; `total` consumes one; `scale` round-trips `Map<F32>`; `Map<List<B.Bytes>>` with an empty key | yes | yes |
| 4096 keys through the trie | yes | yes |
| native validator refuses a surrogate or out-of-range Char and a short F32 before dispatch; the worker keeps serving | yes | yes |

Codec unit tests: a double past the single range, an integer or a string
as `F32` raise; negative, surrogate and past-range Chars raise; a reply
Char is range-checked on the host; a map with atom keys or a pair list in
place of a map raise; the pair list becomes a map in `check/3`.

## User datatypes (2026-09-20)

Full suite: **75 tests passed**; warnings-as-errors, format, credo
(strict), dialyzer and `mix docs --warnings-as-errors` clean.

| check | port | NIF |
|---|---|---|
| `Shape` (three constructors, one nullary) in, out, in a list, in a Maybe, a tuple and a Result | yes | yes |
| `Tree` with `T`, `Maybe<&2, T>` and `List<&2, T>` fields: sum in Bend, echo back unchanged | yes | yes |
| a linked list 300 constructors deep, built in Elixir and in Bend | yes | yes |
| `Rec is Type` holding a Shape, Bytes, a list of pairs with F32 and a `Maybe<Result<U32, Char>>` | yes | yes |
| encoding a wrong constructor, arity or field type raises `ArgumentError`; `{:dot}` is not `:dot` | yes | yes |
| native validation refuses an out-of-range constructor index, a wrong field count and a wrong field type before dispatch | yes | yes |
| parser rules: type parameters, no finite constructor, mutual types, Map field, `List<Maybe<T>>`, `List<T>` on a Data type, `Map<T>` parameter, each with its reason | — | — |

The ThumbHash demo's `Px`, `Pos` and `Ch` types became exportable without
a change to the demo. Measured through the port: a 4093-node tree in
1.6 ms, round trip 3.6 ms; a 2000-cell linked list 2.7 ms in, 1.1 ms
out; 10,000 three-field records 5.3 ms.

## Track 3 review fixes (2026-09-20)

The full suite now passes 80 tests. New regressions cover 255/256/257
constructors and fields, defensive rejection of oversized codec tables,
valid UTF-8 map keys, Bytes inside a datatype with no unrelated Bytes
export (separate Port and NIF modules), and omitted build options on the
fresh/cache paths. Native Bytes validation accepts the Dyn.DB path without
requiring the canonical Bytes constructor. No user constructor layout is
introduced into C. Strict Credo and Dialyzer pass.

The ASan harness now defines every Dyn constructor macro and exercises
records with Bytes/F32/Result, 300-deep recursive values and malformed
constructor frames. The expanded fixture initially faulted during its first
Base-composite call, before the Dyn cases, in generated `root_done` /
`corpus_eval` / `io_step`; ASan reported a null read at `shim.c:1541` at both
O1 and O3. The register dump showed `x19`, used as `corpus_eval`'s spill-frame
base, clobbered to `0x300000030`; the `Corpus` value reloaded through that bad
frame was null. Bend's generated host machine marks its tail-called segments
`preserve_none` and the surrounding cold routines `preserve_most`. With ASan's
added calls and register pressure, that convention combination is not sound on
arm64 Apple clang 21. Compiling the same source with conventional platform
calling conventions made all 100 cycles pass, including the Dyn cases.

`check_asan.exs` now makes a separate `shim_asan.c`, asserts that it changes
exactly one generated `PRESERVE` definition, and disables those calling-
convention attributes only in that copy. This is an instrumentation ABI
compatibility fix, not a sanitizer suppression: `-fsanitize=address` still
instruments the entire codec and generated runtime, `halt_on_error=1` remains
set, and the production `shim.c` and artifact are untouched. Leak detection
remains disabled because runtime teardown is not validated.

## Track 2 integration (2026-09-20)

The ASan fix was rerun against the integrated launcher/scoped-artifact
build: **100 composite cycles and 500 deterministic fuzz frames passed**.
The fuzz target is an identity export, not a random expensive kernel.
Production calling conventions are unchanged; the sanitizer copy uses the
standard ABI and retains full instrumentation. UBSan and NIF sanitizer
coverage remain outside this result.

Launcher tests compile a deliberately uncooperative CPU worker. A deadline
and untrappable owner death both lead to TERM, KILL and worker reaping. A
blocked caller gets `{:error, :exited}` rather than an exit signal. Another
fixture exits its group leader but leaves an ignoring descendant holding
stdout; the launcher observes exit with `waitid(..., WNOWAIT)`, kills the
group while its leader PID is still reserved, then reaps and drains output.
That avoids signalling a recycled process-group id or orphaning descendants.
An external SIGKILL of the launcher itself is not covered.

Codec regressions exercise decoded-memory amplification, both native
validators, malformed/truncated replies, excessive nesting, oversized frame
headers and NIF requests, invalid UTF-8 map keys, and successful calls after
refusal. Generated-call telemetry tests check span pairing, queue/wait/run
measurements, sanitized exceptions, and preservation of public return values.

`MIX_ENV=test mix run scripts/check_overload.exs` completed 40 waves of 64
calls (2,560 requests), one worker thread and queue limit four. One run:
289 accepted / 2,271 busy; worker RSS 2,992 KiB warm baseline, 3,040 KiB
peak/final; BEAM RSS 91,600 KiB baseline and 104,304 KiB final. RSS sampling
is observational, includes unrelated VM state and can miss short peaks.
The script checks retained worker growth against a 128 MiB regression
threshold; it does not enforce a production memory limit.

After lifecycle/budget/telemetry changes, the existing Levenshtein benchmark
reported short single calls 48.0 µs (Elixir 1.0), medium single 46.3 µs
(37.5), medium batch 64: 9.6 µs/pair (37.8). The extra relay has a real
small-call cost; this is not evidence that NIF lifecycle hazards are worth
accepting. Values are the script's averages on this macOS arm64 host.

CI has been added for macOS arm64 and Linux x86_64 with Bend 2.0.20 release
archive SHA-256 pins (from upstream's release-generated flake), OTP 28.0,
Elixir 1.20.3 and locked dependencies. No remote CI run was performed here;
At that stage Linux results were pending; the publication checks below now
record completed remote validation.

Final local checks: **106 tests passed** with warnings as errors, formatting,
strict Credo, Dialyzer (zero errors), and documentation generation passed.
The release-consumer smoke test also passed: two native builders publish the
same artifact under a lock; consumer clean removes only host/prod artifacts,
preserves another target/environment sentinel, and ordinary compile rebuilds
the worker and launcher. The resulting release returns 42 with Bend absent
from PATH. The simultaneous-builder assertion is a separate ExUnit test;
it does not claim that all of Mix's own compiler state supports concurrent
OS invocations. A dead build's lock is deliberately not auto-reclaimed.

## The GPU lane (2026-09-20)

Port build of a program with `!` calls: clang with Bend's Metal flags,
then `<staged> --gpu-build` writes the device program, renamed beside the
artifact as `<exe>.gpu`. `gpu: :on` on the ray tracer port: the upstream
checksum kernel answers 402971 and 19281 on the device (bit-exact with
the CPU), a 64x64 tile of the demo's scene matches the CPU byte for byte;
`gpu: :off` and a NIF run the same defs on the CPU pool. Config: `:on`,
`:off`, `"4GB"` accepted; `true`, `"4 gigs"` and `backend: :nif, gpu:
:on` refused. Not validated: CUDA (no Linux box), `--gpu` with a heap
cap. The demo's renderer at full size on the device first died with
`memory fault (machine stack overflow?)`; reduced to a pure Bend program
(a `!` over a right spine of about a thousand forks) and reported as
bendlang/bend#918; the demo now forks its tiles as a balanced tree.

## Experimental asynchronous NIF roadmap (2026-09-21)

Local macOS arm64 / OTP 28 / Elixir 1.20.3 / Bend 2.0.20 validation:

- `mix test --warnings-as-errors --seed 2`: **116 passed**. Earlier full
  runs at seeds 1 and 594702 passed 115 tests, before the long finite-deadline
  regression was added. The new suite covers reference-preserving replies,
  expired deadlines, time spent before encoding, queued and running
  cancellation, admission limits, caller death, and large finite timeouts.
- Formatting, strict Credo, Dialyzer (zero errors) and docs with warnings as
  errors passed.
- `MIX_ENV=test mix run scripts/check_nif_lifecycle.exs`: a disposable BEAM
  rejects replacement loading, calls the original binding again, submits
  work, deletes and soft-purges the module, receives the native result after
  purge, and exits via `:init.stop()` with status zero. The launcher bounds
  a stalled child. This proves pinning and VM exit, not graceful thread joins.
- `MIX_ENV=test mix run scripts/check_nif_init.exs`: separate fault-injected
  libraries reject initialization before any thread is created and after a
  thread exists but before readiness. Both child VMs exit successfully;
  expected on-load failure warnings are part of these probes.
- `MIX_ENV=test mix run scripts/check_nif_scheduler.exs`: three consecutive
  runs passed with one dirty CPU scheduler. A test-only blocking NIF's live
  running flag remains set while Bendler returns `:busy`. A caller killed
  while its validation is queued leaves no reserved admission behind. The
  probe verifies both saturation and blocker liveness before killing it;
  it does not rely solely on a sleep or function-name observation.
- The Port ASan harness still passes 100 composite cycles plus 500 fuzz
  frames. This is **not NIF sanitizer coverage**; leak detection stays off.

Independent ownership review found and fixed a destructor that tried to
demonitor after OTP had dismantled the resource's monitor tree. Readiness
waiting was also moved to a dirty IO scheduler. The isolated upgrade test
found an identical-BEAM reload edge case invalidating target-local telemetry
closures after failed on-load; the closure now lives in stable library code.
An existing Port restart test now waits for service recovery instead of
assuming a 50 ms cold start during the launcher's 200 ms termination grace.

One local overhead sample, 100 warm-ups then 5,000 verified typed
`fib(20, 0, 1)` calls per backend: NIF **15.6 µs/call**, Port **19.9 µs/call**.
NIF used its default thread count; Port used two. These are serial tiny-call
averages, not direct-call NIF latency or a universal performance claim. They
do not justify treating the experimental NIF as equivalent to Port isolation.

CI now invokes all three isolated NIF scripts. The local results above predate
remote execution; see the publication checks below. Runtime pinning intentionally retains threads, the
library and runtime memory until VM exit; fatal current requests also remain
retained because other runtime workers may still access them. Hard
cancellation, graceful unload, hot upgrade and runtime restart are not solved.

## Public repository and Linux CI (2026-09-21)

The public repository is https://github.com/lukaszsamson/bendler. The Linux
job in [run 35571069189](https://github.com/lukaszsamson/bendler/actions/runs/35571069189)
passed on Ubuntu 24.04 x86_64 with Bend 2.0.20, LLVM 21.1.8, OTP 28.1 and
Elixir 1.20.3. It ran 115 tests, formatting, warnings-as-errors, strict Credo,
Dialyzer, docs, 100 ASan composite cycles plus 500 fuzz frames, overload/RSS,
consumer clean/rebuild and a compiler-free release, and all three isolated
NIF probes (purge/reload, initialization failures, and scheduler admission).
This tests coexistence with BEAM allocation and finite NIF deadlines on that
runner; it is not a general native-memory-safety or platform guarantee.

Publishing exposed three setup/test assumptions: the Bend archive has a
top-level directory, upstream LLVM needs macOS SDK discovery, and release
assertions must inspect Mix's build `priv`, not assume a source-tree symlink.
The macOS run additionally exposed a mismatch between Apple's linker and
LLVM's bundled libc++; CI now selects the matching Mach-O LLD. A local
`mix hex.build` also passed; no Hex package has been published.

The final [run 35572044841](https://github.com/lukaszsamson/bendler/actions/runs/35572044841)
passed every step on **both macOS 15 arm64 and Ubuntu 24.04 x86_64** at code
revision `465c155`. macOS ran all 116 tests, including the real GPU test;
Linux explicitly skips that Metal-only test. Both jobs passed ASan, release
and isolated NIF checks. macOS 15 is the CI baseline because Bend's emitted
Metal code uses `MTLCompileOptions.mathMode`, introduced in macOS 15.

The GPU test now remains visible when skipped for a missing device sidecar.
Builds no longer attempt to publish a nonexistent sidecar when Bend's
`--gpu-build` succeeds without a visible device. That no-device branch is
grounded in Bend's documented/generated behavior; this macOS CI runner did
have a device, so its passing test is not evidence for a headless Metal run.
Local raytracer validation after the change also passed all 12 tests, and
strict Credo reported no issues.

## Incremental CSV over Port and NIF (2026-09-21)

Local validation: **142 tests passed**, including 26 new streaming tests shared
between Port and NIF. They cover arbitrary chunk partitions, UTF-8 and arbitrary
bytes, escaped/multiline fields, maximum-size records, absolute error offsets,
concurrent cursors, lazy demand, early halt, source/consumer failure and reuse.
The implementation uses ordinary bounded typed calls, not an `ask`/`emit`
protocol; no native transport or NIF lifecycle code changed.

The new external-Port ASan probe passed 150 partitioned round trips, a 64 KiB
record, and error recovery, followed by three consecutive successful reruns.
Like the existing probe it uses the platform-ABI workaround and disables leak
detection. An initial attempt exited with transport status 74 without an ASan
diagnostic; a one-request check and all subsequent full probes passed. Its
cause has not been established, so these results do not claim that transient
transport exits have been eliminated. The probe is included in CI; these new
changes have only been validated locally, not in a new remote CI run yet.

An isolated five-sample, one-worker benchmark using fixed 16 KiB file chunks
and checksummed reduction measured 100,000 rows (5.28 MB): NimbleCSV 100.32 ms,
Port 350.63 ms, NIF 358.86 ms; first row 0.118 / 1.363 / 1.139 ms respectively.
No total-file result list is retained. These are warm-cache end-to-end timings,
not peak RSS measurements or evidence that Bend is faster than NimbleCSV.
See `demos/csv/README.md` for the buffering and cancellation contract.

## 2026-09-21: typed events with acknowledgement backpressure

Observed on macOS arm64, Apple M2 Pro, 12 schedulers, Bend 2.0.20 at
`~/.bend/bin/bend`, Elixir 1.21.0-dev on OTP 28 (erts 16.4.0.1), Apple
clang 21, `MIX_ENV=test`.

### What was measured

`mix test`: **135 tests, 0 failures**, from 116 before this change. The
new ones are `test/events_test.exs` (14) and five in
`demos/raytrace/test/raytrace_test.exs`, one of which is the GPU-gated
fly-through. Strict Credo, `mix compile --warnings-as-errors`,
`mix dialyzer` (0 errors) and `mix docs --warnings-as-errors` were clean.

What the event tests pin, each against the real port and a real Bend
program (`bend/events.bend`):

1. A pure export is unchanged, and an effectful export that emits nothing
   (`tick`) is an ordinary call.
2. Events arrive in order, decoded and checked against the emitter's
   declared type, and the stream ends with `{:done, result}`. A `U32`, a
   user datatype (`Point`) and a product (`U32 & String`) each cross as
   events exactly as they cross as replies.
3. A corrupt event body raises `Bendler.Error`: a bad tag, trailing bytes,
   and a well-formed value of the wrong type are all refused.
4. Backpressure: driving the stream one element at a time in the test
   process, a second event never arrives while the first is unacknowledged
   (`refute_receive` over 250 ms and again over 100 ms). The worker is
   parked inside `Bendler.emit`; at most one event is in the mailbox.
5. Early halt: `Enum.take(stream, 3)` of a 10 000-event turn yields three
   events and the def stops; the port serves the next call immediately. An
   exception in the consumer does the same.
6. A plain (non-stream) call of an emitter export answers 1 for `count`:
   the def emitted once, was told `False`, and returned.
7. A consumer killed mid-stream frees the request; the next call works.
8. A deadline that fires while the worker waits on an acknowledgement stops
   the owner exactly as any other timeout.
9. Killing the port mid-stream raises `Bendler.Error` with reason
   `:exited` in the consumer (the stream monitors the owner).
10. An effectful export under `backend: :nif` raises at build time.

### Numbers (`demos/raytrace/bench.exs`, samples=5)

Fly-through at 320x240, 24 frames, 12 threads:

| measurement | median | min | max |
|---|---|---|---|
| time to first frame | 6.68 ms | 6.33 | 7.64 |
| per-frame latency | 6.91 ms | 6.20 | 7.82 |
| 24 frames in one call | 202.8 ms | 190.1 | 206.6 |
| 24 separate `render_tile` calls | 234.6 ms | 214.9 | 306.8 |
| cancel (3rd frame) to next call answered | 0.358 ms | 0.325 | 0.442 |
| `save_apng` of 24 frames | 334.2 ms | 291.0 | 377.0 |

So the whole emit path, including the acknowledgement round trip, costs
*less* than issuing one request per frame: 8.45 ms per frame in one call
against 9.78 ms per call, because the scene is encoded and validated once
instead of 24 times. The acknowledgement itself is well under the 0.358 ms
that separates a cancellation from the port answering again, which also
bounds it: that figure includes the refusal reaching the worker, the def
returning, the reply crossing, and a small unrelated call being served.

The 48-frame, 320x240 sample committed as
`demos/raytrace/raytrace_flythrough.png` (1.24 MB) takes about 500 ms end
to end, 10 ms per frame including deflate.

GPU lane, 24 frames at 128x96 with `gpu: :on` (a whole frame per bang):
CPU 57.3 ms, **GPU 3351.9 ms** — 58x slower, the same verdict the demo's
single-image GPU section already records for this kernel. A whole 320x240
frame in one bang is past what macOS tolerates in a single Metal command
buffer: it aborts with `kIOGPUCommandBufferCallbackErrorImpactingInteractivity`
and the worker exits 1. The benchmark therefore measures the GPU lane at
128x96; the gated GPU test uses 64x48 and matches the CPU bit for bit.

### What was not measured

- **No NIF parity.** Events are port-only. The NIF transport would need
  its own "write event, wait for ack" over the existing wake-up pipe; that
  is not implemented, and an `IO(T)` export is refused there at build time.
  The refusal is tested; the hypothetical NIF path is not.
- **No Linux or CI run of the event tests.** Everything above is one
  macOS arm64 machine. Nothing in the emit path is platform-specific
  (`poll`, `read`, `write` on stdin/stdout, as the request path already
  uses), but that is an argument, not a measurement.
- **No fault injection on the acknowledgement frame.** A malformed
  acknowledgement is a `bl_fail` (exit 65) by construction, since only this
  library writes it; that branch was not exercised.
- **No long-running soak.** The longest run here is 100 000 announced
  frames of which three were taken. Memory behaviour over hours of events
  was not observed.
- **No multi-subscriber or multi-request semantics.** One request is in
  flight and one subscriber owns its events, by construction.
- **Telemetry for streams** emits a span covering the request, closed when
  the def returns. It was exercised by the suite but not separately
  asserted for the stream case.
