# Supported API: 0.1.x

This is the stability boundary. Patch releases preserve this documented API;
incompatible changes require a versioned migration notice. Experimental/internal interfaces carry no such promise.

## Supported: CPU Port bindings

- `use Bendler, otp_app: ..., source: ...` generates a binding. Supported options:
  `backend: :port` (default), `gpu: :off` (default), `exports`, `threads`,
  `timeout` and `max_queue`. Defaults and accepted values are in the README.
- Generated synchronous functions have the selected Bend def's arguments;
  dots in def names become underscores. Prefer an explicit `exports` list so
  adding a helper to a Bend file cannot accidentally grow your public API.
- Generated `start_link/1` and `child_spec/1` integrate with an OTP supervisor.
  Runtime options documented in the README may override the module defaults.
- `IO(T)` exports return the ordinary mapped `T`. An emit export additionally
  has `name_stream/arity`, an Enumerable yielding `{:event, value}` and one
  terminal `{:done, result}`. A plain call declines the first emission; a stream
  acknowledges the previous event only when its consumer requests the next.
- An export with `~ask: Request -> IO(Response)` takes a final unary Elixir
  handler. One channel per export: ask **or** emit. Handlers run in fresh
  processes, have a fixed five-second deadline, and remain within the call's
  total deadline. Host-owned state must be accessible from those processes.
- The accepted types and value representations in TYPES.md are part of the
  contract, including bytes versus UTF-8 strings, F32 rounding, Maybe/Result
  tags and the restricted user-datatype subset. This is not arbitrary Bend syntax.
- `Bendler.Error.reason` is machine-readable. Port transport outcomes include
  `:busy`, `:timeout`, `:exited`, `:callback` and `:refused`; direct callback
  reentry raises `:reentrant` in the handler. If uncaught there, it becomes a
  callback failure for the outer call. Invalid host arguments raise
  `ArgumentError`. Match reasons, not exception text or diagnostic log wording.
  A typed `Result.Fail` is a returned `{:error, value}`, not a transport exception.
- `[:bendler, :call, :start | :stop | :exception]` telemetry and the documented
  measurements/metadata in CONTRACTS.md are supported. Payload values are not logged.

Deadlines include queue time. There is no automatic retry. Port failure or an
abandoned ask stops its owner/worker; supervision can replace them, and queued
callers fail rather than migrate to the new worker. Emit cancellation is
cooperative while the owner remains alive; use a finite deadline for bounded
cleanup. Callbacks are trusted code, not sandboxed code.

## Supported build workflow

Add `:bendler` after the standard Mix compilers. `mix compile.bendler`, its
`--force` option, and `mix bendler.clean` are supported. The current inline
build fallback when the compiler is omitted remains compatible in 0.1.x.
Build-tool configuration documented in CONTRACTS.md remains supported for the
pinned toolchain. A release contains its native artifacts and does not need Bend
or clang at runtime. Artifact paths, fingerprints and lock formats are internal;
use the Mix tasks rather than manipulating them.

The support baseline is Bend 2.0.25, OTP 28, macOS arm64 and Linux x86_64.
CI pins Elixir 1.20.3 and LLVM 21.1.8. Broader Mix dependency version constraints
are not evidence that every permitted version has been tested. Windows and
arbitrary Bend/OTP upgrades are not covered. `allow_any_bend` opts out of the
compiler compatibility gate and therefore out of the tested runtime contract.

## Experimental, opt-in

`backend: :nif`, `max_waiting`, NIF events/asks, and GPU builds/execution remain
experimental. They may share generated function shapes with Port without sharing
its lifecycle guarantees. In particular, a failed or abandoned pending NIF ask
freezes that module until VM restart; a typed Result error does not. There is
no safe NIF unload/upgrade or hard cancellation. See NIF.md and CONTRACTS.md.

## Internal, even when exported by Elixir

The wire tags/protocol, `__bendler_*` functions, raw submit/ack/answer/cancel
handles, direct Bendler.Port/Bendler.Nif transport calls, Codec/Gen/Sig/Build
helpers, generated C, resource layouts and runtime patches are implementation
details. Public visibility or an ExDoc entry alone does not make them stable.
Use generated bindings and Mix tasks. The byte-buffer prelude's documented
`B.Bytes` boundary representation is supported; its heap layout and generated
conversion helpers are not.

## Documentation map

- README: setup and normal usage.
- API: stability and supported entry points (this file).
- TYPES: precise type/value mapping and signature restrictions.
- CONTRACTS: operational semantics, budgets, errors and telemetry.
- DESIGN: why the program serves requests through foreign effects.
- NIF: the experimental in-VM backend and the BEAM APIs it uses.
- VALIDATION: what is checked, known issues and what is not validated.
- ROADMAP: work waiting on Bend upstream, and work deferred by choice.

None of these override the API boundary defined here.
