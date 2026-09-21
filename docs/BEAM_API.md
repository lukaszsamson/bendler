# BEAM APIs used by Bendler

Bend never sees Erlang terms: the interface remains a bounded binary frame
codec. More BEAM APIs do not automatically mean more Bend types. This design
was checked against OTP 28's local `erl_nif.md` and resource implementation
in `erl_nif.c`. The [online reference](https://www.erlang.org/doc/apps/erts/erl_nif.html)
may describe a newer OTP release.

## Experimental NIF call path

1. Generated Elixir functions capture an absolute monotonic deadline before
   encoding arguments.
2. `__bendler_submit/3` checks the envelope and reserves bounded admission
   on a normal scheduler. Saturated calls return `:busy` without waiting
   for a dirty scheduler.
3. `enif_schedule_nif` runs validation and copying on a dirty CPU scheduler.
   No dirty CPU scheduler waits for Bend computation to finish.
4. The runtime sends `{:bendler_reply, ref, reply}` using `enif_send`;
   Elixir waits with an ordinary `receive`.
5. Timeout cancels the handle and drains an already-delivered racing reply.
   Sending and cancellation use the same short lock, so sending cannot start
   after cancel returns.

Submit/cancel are internal plumbing, not a supported public asynchronous
API. The generated typed functions remain synchronous. Raw users must cancel
on deadline: there is no native deadline timer that interrupts a running
computation. Queued work is removed on cancellation/caller death. Running
work retains admission until completion; it cannot be interrupted.

## Ownership

A scheduled resource term owns a RESERVED request. If its process dies before
the dirty continuation runs, the resource destructor retires admission.
Queueing acquires a native resource reference, retained through execution and
reply construction. Down callbacks cancel queued work or abandon running work.

The stored process-independent environment contains only an immutable
reference. Reply construction gets a fresh environment outside the mailbox
lock, so large binary allocation/copying cannot block normal admission on that
lock. Error envelopes are small and sent under the lock. Finalization releases
the monitor, request buffer, environment and native reference. OTP already
dismantles monitors before a resource destructor: the destructor must not
demonitor again.

A runtime fatal error replies `:dead` to pending/current callers and freezes
that runtime. Pending requests can be reclaimed. The current request remains
allocated because other Bend workers might still read it; at most the bounded
current request and runtime state are intentionally retained until VM exit.

## Startup, purge and shutdown

`load` validates configuration and opens callback-bearing resource types.
The generated `@on_load` then calls `__bendler_init__/0` after `load_nif`
commits those types. Init runs on a dirty IO scheduler, allocates a pin before
starting threads, checks initialization results, and waits at most 30 seconds
for the Bend request loop to become ready.

The native pin's initial reference is deliberately never released after a
thread starts. OTP postpones unloading while a resource with a destructor in
that library exists. This is a **VM-lifetime pin**, not a stop-and-join
destructor. Code purge cannot unmap the runtime's library, but it also does not
reclaim its threads or heap. Upgrade is explicitly refused. Failed startup
releases the pin only if no native thread was created.

An `unload` callback returns `void`; it cannot refuse unloading. Omitting it
or merely logging from it is not protection. Graceful unload needs upstream
stop flags, cancellation points, retained thread IDs, joins, queue wakeups,
mapping cleanup and global-state reset. Recovery from a frozen runtime still
requires VM restart. Do not replace a loaded artifact or repeatedly reload
the module. Normal VM exit relies on OS reclamation, not graceful thread joins.

## API surface

| Area | APIs | Purpose |
|---|---|---|
| Entry | `ERL_NIF_INIT`, load/upgrade callbacks | configuration checks, upgrade refusal |
| Resources | `enif_open_resource_type[_x]`, `enif_alloc_resource`, `enif_make_resource`, `enif_get_resource`, `enif_keep_resource`, `enif_release_resource` | pin and request ownership |
| Scheduling | `enif_schedule_nif`, dirty IO init | validation/copying and bounded readiness wait |
| Time | `enif_monotonic_time` | absolute BEAM monotonic milliseconds |
| Monitoring | `enif_self`, `enif_monitor_process`, `enif_demonitor_process` | caller-death cleanup |
| Delivery | `enif_alloc_env`, `enif_make_copy`, `enif_send`, `enif_free_env` | independent reference/reply lifetimes |
| Terms | binary inspection/construction, integer/reference checks, tuples/atoms | frame envelope and errors |

Load info includes the actual dirty CPU scheduler count from
`:erlang.system_info/1`, not an assumed `enif_system_info` field. Admission
is configured independently because it no longer occupies dirty schedulers
while waiting. Runtime pthreads remain; wrapping them with `enif_thread_*`
would not make the upstream pool stoppable.

No ETF decoder, arbitrary BEAM terms, atom creation from user strings, public
PID handles, progress effects or streaming API is added here.

## erl_driver

Nothing from `erl_driver` is needed. The Port backend is an external **port
program**, not a linked-in driver. It uses `Port.open`, `{:packet, 4}`,
`:exit_status`, `Port.command` with `[:nosuspend]`, and `Port.close`.
Its POSIX launcher owns worker-group termination and reaping. A linked-in
driver would retain the NIF's memory-safety and lifecycle hazards; async NIF
delivery already avoids blocking callers without introducing another API.
