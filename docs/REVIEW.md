# Independent review findings

This code went through two rounds of adversarial review by an independent
implementer working from the same brief, who had built a port-only
integration of their own. Every finding below was confirmed against the
source and fixed; the tests that pin them are in `test/bendler_test.exs`
and the verification runs are in `VALIDATION.md`.

## Round one: the native side

- **Empty-list type scanner read past its buffer** (reproduced with
  AddressSanitizer). The spec grammar is unary, `L` takes exactly one type,
  but the scanner treated `L`s as brackets to balance and walked past the
  NUL on `LLu`. Replaced by `bl_skip_type`, which consumes one type with a
  depth cap.
- **Lock held across allocation on the NIF failure path**: an allocation
  under the mailbox mutex could reach the runtime's fatal path, which
  takes the same non-recursive mutex. No allocation happens under the
  lock now, and transport allocations are fallible.
- **Dirty scheduler saturation**: every NIF caller blocked on the mutex,
  so a flood parked a dirty CPU scheduler thread each. Admission is
  bounded (`max_waiting`); callers past it get `:busy`.
- **No deadline** on either backend. Adding one exposed a further bug:
  with one shared reply slot a fast reply could overwrite a reply a slow
  caller had not read yet. Each call now owns its slot.
- **Unbounded port queue**, unchecked frame sizes and list counts.
- **Regex patches of the emitted C had no postconditions**; the build now
  asserts match counts and that nothing process-seizing survives, and a
  version gate refuses a bend other than 2.0.20 unless configured.
- **Cache key too narrow** (no imports, no toolchain) and no Mix compiler.

## Round two: build and lifecycle

- `mix bendler.clean` deleted the build requests, so the next compile
  built nothing. Requests are kept and stale ones dropped.
- A queued port request sent to a closed port returned a `handle_call`
  tuple from `handle_info`. Dispatch returns only `noreply` or `stop` and
  replies to the popped caller itself.
- Build requests were not namespaced by application, so a consumer
  rebuilt the library's examples into its own `priv`. Requests are per
  app; the examples moved under `test/support`.
- The default backend was still `:nif` while the docs recommended the
  port. Port is the default.
- Atomic staging had been claimed and never landed. Clang writes to a
  unique staged path, renamed on success.
- The NIF copied and allocated before checking the frame cap or admission;
  the reply buffer grew before its cap was checked.
- A malformed request was still executed on substituted defaults. This
  changed the error model: a generated `bendler_specs.h` carries each
  export's spec, `bl_validate` walks the whole request against it without
  allocating, on the calling thread for the NIF and before dispatch for
  the port, and only a valid request ever reaches a def.

## Round three: after the first commit

- Credo was configured with an empty enabled set and ran zero checks.
  Restored the default set with a 120-column limit; the findings it then
  raised (nesting, complexity, a raise inside a rescue) were fixed.
- The NIF's Linux deadline waited on a realtime-clock condvar with a
  monotonic deadline. The condvar is now created with `CLOCK_MONOTONIC`
  on Linux (macOS uses a relative wait).
- A request withdrawn on deadline before the loop picked it up left its
  wake-up byte in the pipe, so an idle loop woke repeatedly. The loop now
  drains the pipe before deciding whether to park.
- A port request refused with `:busy` after being popped from the queue
  left the rest of the queue unscheduled. Dispatch now drains until a
  request is in flight, the queue is empty, or the port is gone.
- The claim that omitting `unload` keeps the library loaded was wrong;
  the docs now say so, and library pinning is an open NIF item.

## Positions adopted from the reviewer

- The MVP is a reliable CPU port binding generator for bounded pure
  functions; NIF support stays opt-in and outside that promise.
- Data interoperability before more of the BEAM C API.
- Kernels for real-world validation: batched Levenshtein, Murmur3,
  ThumbHash, in that order (`MVP.md`).

## Positions not adopted

- Keeping NIF work out of the repository entirely. It stays, labelled
  experimental, because its measurements and failure modes are the useful
  research output: it shows the hand-off costs the same as a port's, so
  the case for a NIF rests on direct calls, which need a compiler change.
