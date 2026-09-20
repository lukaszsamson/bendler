# Which parts of erl_nif and erl_driver Bendler needs

Read against OTP 28's `erts/doc/references/erl_nif.md` (about 190
`enif_*` functions) and `erl_driver.md` (102 `driver_*`/`erl_drv_*`
functions) in `~/otp`. The question is not "how much of the API can be
wrapped" but "which parts does a Bend binding actually touch", because
Bend never sees Erlang terms: everything crosses as a frame the codec
defines. That keeps the surface small on purpose.

## erl_nif: what the NIF backend uses today

| area | functions | used for |
|---|---|---|
| entry | `ERL_NIF_INIT`, `load` | one library per module, `load_info` carries threads and admission |
| calling | `ErlNifFunc` with `ERL_NIF_DIRTY_JOB_CPU_BOUND` | every call blocks for the runtime, so it must not sit on a normal scheduler |
| terms in | `enif_inspect_binary`, `enif_get_int`, `enif_get_tuple` | the frame and the timeout |
| terms out | `enif_make_new_binary`, `enif_make_tuple2`, `enif_make_atom`, `enif_make_string`, `enif_raise_exception`, `enif_make_badarg` | the reply frame and the error shapes |

That is nine functions. Everything else the docs describe is either not
needed by design or belongs to a later track.

## erl_nif: what an MVP should add

- **`upgrade` and `unload` callbacks**, even if `upgrade` only returns an
  error: today their absence is what refuses a second `load_nif`. `unload`
  cannot stop the runtime's threads; it should at least log and refuse.
- **Resources** (`enif_open_resource_type`, `enif_alloc_resource`,
  `enif_make_resource`, `enif_release_resource`, `enif_keep_resource`) to
  pin the library: a resource term held by the module keeps the library
  from being unloaded on code purge, which is the correct answer to "the
  runtime thread would keep running in unloaded code". Also the vehicle for
  an opaque handle to a long-lived Bend value later.
- **`enif_consume_timeslice`** does not apply (dirty jobs), but
  **`enif_schedule_nif`** could split a call: validate on a normal
  scheduler, run on a dirty one, so `:busy` answers without occupying a
  dirty thread (the review's admission point).
- **Process-independent environments** (`enif_alloc_env`,
  `enif_make_copy`, `enif_send`, `enif_free_env`) for `Beam.send` from an
  effect on the runtime thread: progress, streaming, and a future
  asynchronous call shape where the NIF returns at once and the reply
  arrives as a message (`enif_self` for the caller's pid, `enif_monitor_process`
  to drop work when the caller dies).
- **Binaries as bytes** (`enif_inspect_binary` on the way in already;
  `enif_make_new_binary` out) once the codec has a bytes type; iovecs
  (`enif_inspect_iovec`, `enif_ioq_*`) only if streaming large payloads.
- **Threads and locks**: `enif_thread_create`, `enif_mutex_*`, `enif_cond_*`
  instead of raw pthreads, so the VM's lock checker and thread naming see
  them. Cheap to switch; worth it before publishing the NIF as supported.
- **`enif_system_info`** for the dirty scheduler count, to size
  `max_waiting` sensibly by default.

Not needed: term construction beyond binaries and small tuples (the codec
is the contract), maps, ports, `enif_binary_to_term`/`term_to_binary`
(unless the codec is replaced by ETF, which the review argued against
for a C decoder), time functions, hashing, `enif_getenv`.

## erl_driver: not the right tool

The port backend uses an OS process, which is a *port program*, not a
*port driver*. Drivers are linked-in C loaded into the VM, with the
`ErlDrvEntry` callbacks (`start`, `stop`, `output`, `ready_input`,
`outputv`, `control`, `timeout`, `process_exit`) and the driver API
(`driver_output*`, `driver_select`, `driver_async`, `driver_alloc_binary`,
`set_busy_port`, `erl_drv_busy_msgq_limits`, the `erl_drv_thread_*` and
lock families). A driver would give the port backend in-process speed
without a NIF's blocking rules, and `set_busy_port` plus
`erl_drv_busy_msqg_limits` are exactly the backpressure the review asked
for, but:

- the runtime's constraints are the same as for a NIF (global state,
  threads, signals, `_exit`), so nothing gets safer;
- OTP's own docs steer new code to NIFs; drivers are the legacy path;
- the two things drivers do better, `driver_select` on an fd and async
  thread pools, the port program already gets from the OS.

So: nothing from `erl_driver` is needed. If in-process speed with
non-blocking semantics is wanted, the answer is the asynchronous NIF shape
above (`enif_send` from the runtime thread), not a driver.

## What the port backend uses

Plain Erlang ports: `Port.open` with `:spawn_executable`, `{:packet, 4}`,
`:exit_status`, `[:nosuspend]` on `Port.command`, and `Port.close`. To
kill a worker on deadline the missing piece is an OS-level launcher (or
`:os.cmd("kill")` on the `:os_pid` from `Port.info`), not a driver API.
