# The experimental NIF backend

`backend: :nif` loads the Bend program into the VM instead of running it
beside the VM. It is opt-in and experimental: it shares the generated
function shapes of the port backend without sharing its lifecycle
guarantees. The port backend is the supported one ([API.md](API.md)).

Nothing here gives Bend access to Erlang terms. The interface is the same
bounded binary frame codec the port uses; more BEAM APIs would not mean more
Bend types. Resource ownership and scheduling use OTP 28's NIF APIs.

## The call path

1. An ordinary generated call captures an absolute monotonic deadline before
   encoding its arguments. Ask calls are an exception (see Deadlines).
2. `__bendler_submit/3` checks the envelope and reserves bounded admission
   on a normal scheduler. A saturated module answers `:busy` without waiting
   for a dirty scheduler.
3. `enif_schedule_nif` runs validation and copying on a dirty CPU scheduler.
   No dirty CPU scheduler waits for Bend computation to finish.
4. The runtime sends `{:bendler_reply, ref, reply}` with `enif_send`; the
   caller waits in an ordinary Elixir `receive`.
5. A timeout cancels the handle and drains an already-delivered racing
   reply. Sending and cancellation take the same short lock, so sending
   cannot start after cancel has returned.

Submit and cancel are internal plumbing, not a public asynchronous API. The
generated typed functions stay synchronous. There is no native deadline
timer that interrupts a running computation.

## Ownership and resources

A scheduled resource term owns a reserved request. If its process dies
before the dirty continuation runs, the resource destructor retires the
admission. Queueing acquires a native resource reference, retained through
execution and reply construction. Down callbacks cancel queued work or
abandon running work.

The stored process-independent environment holds only an immutable
reference. Reply construction uses a fresh environment outside the mailbox
lock, so allocating and copying a large binary cannot block normal admission
on that lock. Error envelopes are small and sent under the lock.
Finalization releases the monitor, the request buffer, the environment and
the native reference. OTP dismantles a resource's monitors before running
its destructor, so the destructor must not demonitor again.

## VM-lifetime pin, purge and refused upgrade

`load` validates configuration and opens callback-bearing resource types.
The generated `@on_load` then calls `__bendler_init__/0` after `load_nif`
has committed those types. Init runs on a dirty IO scheduler, allocates the
pin before starting any thread, checks every condition-variable, pipe,
`fcntl` and thread result, and waits at most 30 seconds for the Bend request
loop to signal readiness. A failed startup releases the pin only if no
native thread was created.

The pin's initial reference is deliberately never released after a thread
starts. OTP postpones unloading a library while a resource with a destructor
in it exists, so code purge cannot unmap the runtime's library beneath its
live threads. This is a **VM-lifetime pin**, not a stop-and-join destructor:
purge does not reclaim the runtime's threads, heap or mappings. Upgrade is
explicitly refused.

An `unload` callback returns `void` and cannot refuse unloading, so omitting
it or logging from it is not protection. Graceful unload needs upstream stop
flags, cancellation points, retained thread ids, joins, queue wake-ups,
mapping cleanup and global-state reset. Recovering from a frozen runtime
requires a VM restart. Do not replace a loaded artifact or repeatedly reload
a bound module. Normal VM exit relies on OS reclamation, not thread joins.

Each module reserves 8 GiB of virtual address space for the runtime's arena
(`MAP_NORESERVE`) plus 2 GiB of virtual stack per worker thread.

## Deadlines

Deadlines are absolute monotonic milliseconds and include queue time.
Ordinary calls capture them before argument encoding; streams capture them
when enumeration starts, before encoding. Ask calls currently capture them
after initial argument encoding, so that encoding time is outside their
timeout budget. `enif_monotonic_time` is valid only on scheduler
threads and returns `ERL_NIF_TIME_ERROR` elsewhere, so admission converts
the remaining BEAM duration into a `CLOCK_MONOTONIC` deadline on the
scheduler, and Bend's pthread uses that OS monotonic value. A parked emit
sets an IO timer, so a paused consumer's finite deadline fires without
another acknowledgement. The Elixir receive enforces the same deadline.

Caller death or a timeout removes queued work. Running work stays admitted
until it completes, or remains pinned if the runtime freezes: pure running
work cannot be interrupted.

## Events

The generated `_stream` API yields the same events and terminal result as
the port. One event is outstanding per native request. Native code sends
from an independent environment with `enif_send(NULL, ...)`, then parks the
Bend IO activation on the existing nonblocking wake pipe, so neither a
normal nor a dirty scheduler waits for an acknowledgement. Payload
allocation and copying happen outside the cancellation lock; the native
request hold protects the storage.

Acknowledgements carry the request resource and the event sequence. Stale or
duplicate sequences are ignored, and a process other than the owner cannot
acknowledge. Stream continuations belong to their enumerating process; do
not transfer a suspended continuation elsewhere. Admission includes the
parked request and any queued requests.

Early halt or consumer failure cancels future delivery and flushes messages
already sent, and wakes a parked emit so it answers false. Unlike port
stream cleanup this does **not** wait for native completion: admission is
retained until the def returns. Ignoring false can therefore occupy the
runtime.

The supported effect topology is a sequential IO spine. Concurrent emits
through `IO.fork` are unsupported: overlapping events freeze the module
rather than creating an unbounded mailbox.

## Ask callbacks

A typed ask reply arrives through a dirty CPU entry point rather than
stdin. Only the submitting process may answer, and the pending sequence must
match. The frame cap is checked before copying, and type and allocation
budgets are validated before Bend decodes it. A malformed or stale native
reply is refused without consuming the pending ask.

A handler failure, an invalid handler return, a handler timeout, caller
death or the total deadline expiring while an ask is waiting abandons the
continuation and **permanently freezes that module**. Queued and future
calls fail with `:dead` and a VM restart is required; other modules stay
usable. There is no safe native request unwind: the implementation neither
invents a value of `Response` nor `longjmp`s through the runtime. A
successfully encoded `Result.Fail` is ordinary data and does not freeze
anything. NIF handlers have a guardian that monitors the caller and kills
and reaps the handler on completion or abandonment.

Use the port backend when a failed callback must be recoverable.

## Fatal runtime errors

The runtime's `_exit` is routed to `bendler_die`, which replies `:dead` to
pending and current callers and freezes that runtime. Pending requests can be
reclaimed. The current request stays allocated because other Bend workers
might still read it, so the bounded current request and the runtime state
are intentionally retained until the VM exits. A crash inside the C runtime
proper, such as a segfault, still takes the VM down, as with any NIF.

## Admission

`max_waiting` (default 4) counts staged, queued and running requests for the
module. Callers past it get `:busy` immediately on a normal scheduler, and
waiting callers wait in Elixir rather than occupying a dirty scheduler.
Abandoned running work keeps its slot until the computation finishes;
queued work can be removed. Admission is configured independently of the
dirty CPU scheduler count, which load reads from `:erlang.system_info/1`.

## Hazards

- Native corruption terminates the BEAM. This backend is not a fault
  isolation boundary; the port backend is.
- The runtime, its threads and its memory are retained until VM exit.
- No unload, no upgrade, no hot reload, no runtime restart.
- No hard cancellation: an abandoned computation runs to completion.
- A fatal runtime error or an abandoned ask freezes the module.
- Sanitizer coverage is external-port only. The NIF is not run under
  AddressSanitizer inside the BEAM.
- `!` calls run on the CPU pool; the `gpu:` option is refused, because the
  runtime looks for the device program beside the executable, which in the
  BEAM is the VM's own.

## The erl_nif surface used

| Area | APIs | Purpose |
|---|---|---|
| Entry | `ERL_NIF_INIT`, load and upgrade callbacks | configuration checks, upgrade refusal |
| Resources | `enif_open_resource_type[_x]`, `enif_alloc_resource`, `enif_make_resource`, `enif_get_resource`, `enif_keep_resource`, `enif_release_resource` | the pin and request ownership |
| Scheduling | `enif_schedule_nif`, dirty IO init | validation and copying, bounded readiness wait |
| Time | `enif_monotonic_time`, POSIX `clock_gettime` | translate the BEAM deadline on a scheduler; the native thread uses OS monotonic time |
| Monitoring | `enif_self`, `enif_monitor_process`, `enif_demonitor_process` | caller-death cleanup |
| Delivery | `enif_alloc_env`, `enif_make_copy`, `enif_send`, `enif_free_env` | independent reference and reply lifetimes |
| Events | `enif_send`, `enif_compare_pids`, sequence checks | one outstanding event, owner-checked acknowledgements |
| Ask | `enif_inspect_binary`, owner and sequence checks, dirty CPU validation | typed replies into the parked IO continuation |
| Terms | binary inspection and construction, integer and reference checks, tuples, atoms | the frame envelope and errors |

There is no ETF decoder, no arbitrary BEAM terms, no atom creation from user
strings and no public PID handles. Wrapping the runtime's pthreads with
`enif_thread_*` would not make the upstream pool stoppable.

## erl_driver

Nothing from `erl_driver` is needed. The port backend is an external **port
program**, not a linked-in driver: it uses `Port.open`, `{:packet, 4}`,
`:exit_status`, `Port.command` with `[:nosuspend]` and `Port.close`, and its
POSIX launcher owns worker-group termination and reaping. A linked-in driver
would carry the same memory-safety and lifecycle hazards as the NIF, and the
asynchronous NIF delivery above already avoids blocking callers.
