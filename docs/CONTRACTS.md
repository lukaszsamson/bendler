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

The following are deliberately not exported: `main`, erased (`-`) or template
(`~`) parameters, `IO` results, closures, arrays, unsupported types, and a
`Map` nested inside another type (for example `List<Map<U32>>`). A Map value
is converted as a whole by the Bend prelude and may not contain a user
datatype. Def names that collide after `.` becomes `_` are rejected.

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

## Telemetry

Generated functions emit `[:bendler, :call, :start | :stop | :exception]`
with module, function, backend and span context. Times are native monotonic
units (`System.convert_time_unit/3`). Successful Port calls add queue depth
at admission, queue wait time and dispatch-to-reply time (including relay
transport), not pure kernel time. NIFs expose total call duration only.
Exceptions preserve the original raised error but emit a sanitized reason;
neither arguments nor return values are included in metadata. Forced caller
death can leave a start event without its matching completion event.

## Platform matrix

| Target | Bend toolchain pin | CPU port status | NIF status |
|---|---|---|---|
| macOS arm64 | Bend 2.0.20 archive, SHA-256 pinned in CI | tested baseline | experimental; no release promise |
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

## Sanitizer note

`demos/csv/check_asan.exs` builds a separate ASan-instrumented port executable
from generated C. It preserves instrumentation everywhere. Only the ASan copy
disables Bend's `PRESERVE` calling-convention attributes, because the compiler's
ASan ABI on Apple clang otherwise corrupts the generated runtime spill frame.
The normal generated shim and the NIF remain untouched.
