# Experimental NIF implementation plan

The CPU Port remains the supported MVP boundary. This work improves the
experimental in-process backend, not its fault isolation: native corruption
can still terminate the BEAM.

Implementation order:

1. Establish runtime ownership and library pinning. Bend has no proven
   stop-and-join protocol for all its threads. Retain a native resource with
   a destructor in the library for the VM lifetime, refuse upgrade, and
   explicitly distinguish safe code purge from reclaiming runtime memory.
2. Check initialization, including pipe, thread and readiness failures.
   Do not report a usable runtime before it reaches its request loop.
3. Admit bounded calls on normal schedulers; schedule only frame validation
   and copying as dirty CPU work. No dirty scheduler waits for Bend execution.
4. Capture an absolute monotonic deadline before encoding; carry it through
   validation, admission, queueing and reply delivery.
5. Deliver replies from native threads using independent environments and
   process monitors. Give cancellation a precise ownership contract: queued
   work is removable; already-running computation is abandoned, not stopped.
6. Test load failure, saturation, caller death, deadline races, code purge
   and VM exit in isolated BEAM processes. Record residual limits and results.

Graceful runtime unloading, hot upgrade and hard cancellation remain blocked
on a cooperative upstream runtime shutdown protocol. An unload callback is
notification only: it cannot refuse unloading or fix live unmanaged threads.

Completion evidence is added as each step is integrated; this plan is not a
claim that the NIF backend is production-safe.

## Investigation status (2026-09-21)

### Event extension

Sequential emit exports now have NIF parity: resource-scoped, sequence-tagged
messages, one outstanding event, acknowledgements on the normal scheduler and
an IO-loop wake-up. A parked finite deadline is enforced natively. Admission
is retained until cooperative completion even if the caller has cancelled.
The particle demo compares this with Port and separately measures scalar events.
Typed ask responses are now experimental too: replies are validated on a dirty
CPU scheduler and delivered to the parked IO continuation. A failed/abandoned
ask freezes its module because the runtime has no safe request unwind. Typed
Result failures are recoverable data. Parallel effect activations remain unsupported.

The extension exposed a pre-existing clock error: `enif_monotonic_time` is
scheduler-only, so runtime pthread checks received `ERL_NIF_TIME_ERROR`. Native
admission now converts the remaining BEAM duration into an OS monotonic
deadline. Lazy-stream closures live in the stable Bendler.Nif helper, not in the
reload-refused target module. The isolated lifecycle script checks both existing
and newly created streams after a refused upgrade. This is not upgrade support.

### Original lifecycle audit

The lifecycle audit is complete, against OTP 28's local `erl_nif.md` and
`erl_nif.c`. Key constraints for implementation:

- Open a callback-bearing resource type in `load`, but allocate the pin in
  a separate `__bendler_init__/0` after `load_nif` commits the resource type.
- Retain the pin before starting any native thread. Once any thread has
  started, initialization failure must not release the pin and unmap its code.
- Make initialization dirty and wait for the first request-loop readiness
  signal; validate every condition-variable, pipe, fcntl and thread result.
- Request resources need independent environments, process monitors and
  explicit staged/queued/running/finished ownership. Synchronize cancellation
  with native sending so the caller can drain racing replies safely.
- Keep abandoned running work admitted until the runtime actually finishes
  it. Otherwise repeated deadlines bypass the configured admission bound.
- Exercise purge during active computation and fault-injected initialization
  in disposable BEAM processes, guarded by the existing POSIX launcher.

After explicit approval of the native files, steps 1–6 were implemented with
the VM-lifetime policy above. The transport and resource state live together
in `priv/c/bendler_nif.h`; the separate glue is only the NIF entry table.
The typed Elixir wrapper preserves synchronous calls while native delivery
is asynchronous. Validation/copying, but not execution waiting, runs dirty.

The isolated lifecycle test found that loading identical BEAM code and then
refusing its NIF upgrade invalidated target-local anonymous fun entries on
this OTP. Generated functions now delegate to a stable helper in `Bendler`, keeping the
telemetry closure in the stable library module. The original binding remains
callable after a refused upgrade.

Validation commands and results are recorded in `VALIDATION.md`. Safe purge
is not graceful unload: the runtime, and a current request frozen by a fatal
runtime error, remain retained until VM exit. No production NIF support or
Linux validation claim is made by these local checks.
