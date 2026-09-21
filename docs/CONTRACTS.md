# Bendler contracts

This is the compact public contract for the generated port and experimental
NIF. Both backends use the same signature parser and wire codec; the port is
the intended MVP boundary, not a claim that every platform has passed CI.

## Exported signatures

A top-level `def name(...) -> T:` is exported when every parameter and `T` is
one of `U32`, `Nat`, `F32`, `Char`, `String`, `Bool`, `Unit`, `B.Bytes`,
`List<T>`, `Maybe<T>`, `Result<E, T>`, a product `A & B` (2–16 fields), a
supported user datatype from the same file, or a whole `Map<V>` parameter or
result with valid UTF-8 binary keys.

Products can be parenthesized to preserve nested tuple shape. Generic kind
qualifiers (`List<&2, T>`, `Maybe<&2, T>`, `Result<&2, &2, E, T>`) and reusable
(`+`) parameters are accepted. Signatures may span lines. Type expressions
nest at most 32 levels.

A def whose result is `IO(T)`, with `T` of that same set, is exported too,
and may take one **emitter** parameter, `~emit: T -> IO(Bool)`. The emitter
is not a wire argument: the shim supplies a lambda over `Bendler.emit`, and
the export gets a second generated function, `name_stream/n`, yielding
`{:event, value}` per event and `{:done, result}` at the end. Write the `~`
(Bend's template marker) whenever the def emits more than once: a function
type is Type-kinded, so a closure binder cannot be `+`. `+emit:` is refused.

The following are deliberately not exported: `main`, erased (`-`) or other
template (`~`) parameters, closures that are not emitters, arrays,
unsupported types, and a `Map` nested inside another type (for example
`List<Map<U32>>`). A Map value is converted as a whole by the Bend prelude
and may not contain a user datatype. Def names that collide after `.`
becomes `_` are rejected. Sequential `IO(T)` exports and emitters work on
both backends, including typed ask callbacks. NIF asks have a stricter failure
contract: abandoning an active callback freezes its module (see below).

## User datatypes

`type T is Data:` (or `is Type:`) crosses as tagged Elixir values:
`Circle{r: U32}` is `{:circle, r}`, while a fieldless constructor is `:circle`.
Types have no parameters, erased fields, or Map fields. A recursive type may
refer to itself only as a whole `T`, `List<T>`, or `Maybe<T>` (use kind
qualifiers where Bend requires them); mutually recursive types are not
accepted. At least one constructor must have a finite value. Constructors are
limited to 1–255 per type and 0–255 fields each.

Values are bounded at 2048 nesting levels. The request validator also enforces
the codec's decoded allocation budget (64 MiB), frame/item limits, constructor
indices, field counts, and complete consumption of each value. These are
defence-in-depth limits, not a promise that arbitrary large values are cheap.

The frame cap is 64 MiB and the request item cap is 16 million. The native
decoded budget is `BENDLER_MAX_DECODED`; the host enforces the same default
before request encoding and pre-scans replies with a conservative BEAM-term
budget. This bounds codec admission/allocation, **not process RSS**: user Bend
computation can allocate independently, and the runtime may retain pages.
An external OS memory limit is still appropriate for untrusted computation.

## Boundary errors and Unicode

Elixir-side argument mismatches raise `ArgumentError` before dispatch. This
includes out-of-range `U32`/`Nat`/`Char`, invalid `F32`, malformed tuples,
wrong variants, invalid datatype constructors, malformed lists, and maps whose
keys are not binary valid UTF-8. Map keys are strict: invalid bytes are
rejected rather than replacement-decoded, so distinct keys cannot collapse.

`String` values are binaries. Bend decodes them as UTF-8; invalid byte
sequences are replaced with U+FFFD. This lossy replacement applies to String
values, not to Map keys. `Char` accepts Unicode scalar values
`0..0x10FFFF`, excluding surrogates. Bend runtime failures and transport
failures raise `Bendler.Error`; `Result`'s `{:error, value}` is ordinary
returned data, not an exception. A malformed frame is refused before the user
def runs.

`Bendler.Error.reason` is `:busy` for admission rejection, `:timeout` for an
expired call, `:exited` for port termination, `:dead` for a frozen NIF runtime,
`:refused` for invalid native requests, `:nomem` for a native transport
allocation failure, and `:build` for build/other boundary invariant failures.
Port deadlines include owner queue time; termination fails other pending
calls rather than retrying them. The launcher watches owner-pipe EOF, sends
TERM to its worker group, KILL after 200 ms, and reaps the child. This also
works when the owner is killed and its terminate callback cannot run. It is
not protection against an external SIGKILL of the launcher itself.

Artifacts and loaders use `priv/bendler/<target>/<env>/`. Rebuild on upgrade;
cleaning an environment does not delete another environment's artifacts.
Build and clean serialize through an artifact-directory `.lock`, with a
five-minute wait limit. If the building OS process dies, confirm that the
PID in `.lock/owner` no longer owns a live build before manually removing
that specific lock directory. Locks are not automatically reclaimed because
racing a replacement owner could allow concurrent artifact writes.

## Events and acknowledgements

Worker-to-host frames are a reply (a value tag, or `0` for the transport
error) or an EVENT frame led by `16` (`BL_EVENT`) and holding one encoded
value of the emitter's type. Host-to-worker frames are a request, unchanged,
or a one-byte acknowledgement (`1` go on, `0` stop) answering the event the
worker is parked on. `BENDLER_MAX_FRAME` bounds an event like any frame, and
the exit-code contract (0 clean EOF, 65 framing, 74 transport) is unchanged;
EOF while an acknowledgement is awaited is the host leaving, so the worker
exits 0.

At most one event is outstanding. An event belongs to the one request in
flight. With a live subscriber the port owner forwards it and waits for the
subscriber's acknowledgement; without one (a plain call, a cancelled or dead
subscriber) it answers `false` at once and drops the event, so the def stops
early. The owner never blocks on a consumer, and the request's total
deadline keeps running while events flow: a deadline that fires during an
acknowledgement wait stops the owner exactly as for any other call.

Demand drives the acknowledgements in the generated stream: the one for
event N is sent when the consumer asks for event N+1, so a paused consumer
holds at most one event and the worker waits. Halting early, an exception in
the consumer, or the consumer's death each make the next emit answer `False`
and release the request once the def has returned; the port then serves the
next call. Events are decoded and checked against the emitter's declared
type, and a corrupt event frame raises `Bendler.Error`.

Cancellation is cooperative and typed: `False` is an ordinary Bend value the
def may act on. A def that ignores it keeps being answered `False` until it
returns; only the total deadline is involuntary.

## Telemetry

Generated functions emit `[:bendler, :call, :start | :stop | :exception]`
with module, function, backend and span context. Times are native monotonic
units (`System.convert_time_unit/3`). Successful Port calls add queue depth
at admission, queue wait time and dispatch-to-reply time (including relay
transport), not pure kernel time. NIFs expose total call duration only.
Exceptions preserve the original raised error but emit a sanitized reason;
neither arguments nor return values are included in metadata. Forced caller
death can leave a start event without its matching completion event.

A generated `_stream` opens its span when the stream is first reduced and
closes it when the request ends, so the span covers the whole request, not
one event and not the consumer's own work. A consumer that raises still
closes the span as `:stop` once the def returns.

## Platform matrix

| Target | Bend toolchain pin | CPU port status | NIF status |
|---|---|---|---|
| macOS arm64 | Bend 2.0.20 archive, SHA-256 pinned in CI | macOS 15 CI verified | isolated probes pass; still experimental |
| Linux x86_64 | Bend 2.0.20 archive, SHA-256 pinned in CI | Ubuntu 24.04 CI verified | isolated probes pass; still experimental |
| Other targets | not packaged by this project | unsupported | unsupported |

The CPU binding contract covers bounded pure functions, not Bend's Window or
Audio effects. Those effects need separate lifecycle and transport design;
Linux also requires their X11/ALSA development libraries and link flags.
The supported generated programs include neither effect, so their builds do
not link `-lX11` or `-lasound`. The macOS-only `-undefined dynamic_lookup` flag
is omitted on Linux. CI pins LLVM clang 21.1.8 as well as Bend, OTP and Elixir.

The port backend is the release recommendation. The NIF depends on Bend runtime
internals and reserves substantial virtual address space. A VM-lifetime native
resource pin prevents code purge from unloading its library beneath live
threads. Purge does not reclaim its runtime; hot upgrade/reload is unsupported.
Rebuild artifacts with the old VM stopped; no mixed-version ABI negotiation
is provided. See `NIF_ROADMAP.md` and `BEAM_API.md`.

NIF deadlines are absolute monotonic milliseconds captured before encoding.
Admission precedes dirty validation/copying; waiting uses an ordinary process
receive. Caller death or timeout removes queued work, while running work stays
admitted until completion. Cancellation synchronizes with sending so the
wrapper can drain racing replies without later mailbox pollution. Internal
raw submit/cancel functions are not a supported public async API; callers of
that plumbing must explicitly cancel on deadline. There is no native timer
thread interrupting a running computation.

## NIF events (experimental)

The generated `_stream` API yields the same events and terminal result as Port.
One event is outstanding per native request. Native code sends from an
independent environment using `enif_send(NULL, ...)`, then parks the Bend IO
activation on the existing nonblocking wake pipe. Neither a normal nor dirty
BEAM scheduler waits for an acknowledgement. Payload allocation/copying occurs
outside the cancellation lock; the native request hold protects its storage.

Acknowledgements carry the request resource and event sequence; stale or
duplicate sequences are ignored, and a different process cannot acknowledge
the request. Stream continuations are owned by their enumerating process;
do not transfer a suspended continuation to another process. The per-module
admission limit still includes the parked request and any queued requests.

Early halt or consumer failure cancels future delivery and flushes already-sent
messages under the existing send/cancel synchronization contract. It wakes a
parked emit to return false. Unlike Port stream cleanup, this does **not** wait
for native completion: admission is retained until the def returns. There is
no hard cancellation between effects. Ignoring false can occupy the runtime;
choose Port when process isolation and hard termination are required.

Deadlines start at enumeration/admission, not stream construction. At native
admission, the scheduler converts the BEAM deadline's remaining duration into
`CLOCK_MONOTONIC` time. `enif_monotonic_time` is scheduler-thread-only and must
not be called from Bend's pthread. A parked emit sets an IO timer so a paused
consumer's finite deadline fires without another acknowledgement. Pure running
work still cannot be interrupted. The Elixir receive also enforces its deadline.

The supported effect topology is a sequential IO spine. Concurrent emits via
`IO.fork` are unsupported; overlapping events freeze the module rather than
creating an unbounded mailbox. Runtime fatal errors notify live callers and
freeze that module as before. VM-lifetime pinning, no reload/unload, and all
other NIF hazards are unchanged.

## Ask callback contract

An ask export has a parameter named `ask` of type `Request -> IO(Response)`;
use a Bend template (`~ask`) for repeated calls. Its generated Elixir function
takes a final unary callback. The callback is selected by the caller, not by
a Bend-supplied function name or PID. One channel per export, ask or emit.

Worker-to-host ASK frames start with 17 followed by a codec value of Request.
The host answers with a normal length-prefixed codec value of Response. The
worker is parked while awaiting it. Both endpoints validate response types;
the C check includes depth, item, byte and decoded-allocation budgets before
decoding. The original request cursor is retained and restored around replies.

That framing describes Port. NIF uses resource-scoped event messages and a
dirty-CPU reply entry point, not stdin/stdout. Only the submitting process may
answer, and the pending sequence must match. The frame cap is checked before
copying; type and allocation budgets are validated before Bend decodes it.
Malformed/stale native replies are refused without consuming the pending ask.

The handler runs in a fresh linked/monitored process, not the Port owner or
caller. It has a fixed 5-second deadline; the request's total deadline remains
active. Handler exceptions, wrong response types and handler timeout fail with
`:callback`; on Port they close the owner/worker and let a supervisor restart it. No automatic
retries. Total request timeout is `:timeout`; owner death is `:exited`. Caller
death also closes its occupied worker. A typed `Result.Fail` is normal data and
does not trigger replacement. Queued requests fail on owner replacement as usual.

Direct same-worker reentry from the handler raises `:reentrant`; indirection
through another process is not detected. Callbacks are trusted host code, not
a sandbox: spawned descendants and external side effects are their responsibility.
Handlers must not use raw file handles owned by another process. One request
remains in flight for the entire callback-driven computation.

**Experimental NIF failure policy:** handler failure, invalid handler return,
handler timeout, caller death or total deadline while an ask is waiting
abandons its continuation and permanently freezes that module. Queued and
future calls fail `:dead`; VM restart is required. Other modules remain usable.
There is no safe native request unwind: the implementation neither invents a
value of Response nor uses `longjmp` through the runtime. A successfully
encoded `Result.Fail` is ordinary data and does **not** freeze the module.
Cancellation during pure work still cannot interrupt it; the next ask will
observe cancellation and freeze, while a normal terminal reply retires it.
Use Port when automatic recovery matters. NIF handlers have a guardian that
monitors their caller and kills/reaps the handler on completion or abandonment.

Event cancellation remains cooperative: false only requests that the def stop.
Use a finite total deadline if cleanup must be bounded even for a def that
ignores cancellation. Streams now retain their original owner PID/monitor;
supervisor replacement cannot retarget a pending stream to the new owner.

## Sanitizer execution

`demos/csv/check_asan.exs` builds a separate ASan-instrumented port executable
from generated C. It preserves instrumentation everywhere. Only the ASan copy
disables Bend's `PRESERVE` calling-convention attributes, because the compiler's
ASan ABI on Apple clang otherwise corrupts the generated runtime spill frame.
The normal generated shim and the NIF remain untouched.
