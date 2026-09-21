// Test-only NIF used by scripts/check_nif_scheduler.exs. It occupies a dirty
// CPU scheduler without entering Bend, so the script can prove that Bendler's
// admission NIF still returns :busy on a normal scheduler.
#define _POSIX_C_SOURCE 200809L
#include <erl_nif.h>
#include <stdatomic.h>
#include <errno.h>
#include <time.h>

static _Atomic int started;

static ERL_NIF_TERM sleep_ms(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  unsigned int milliseconds;
  if (argc != 1 || !enif_get_uint(env, argv[0], &milliseconds) || milliseconds > 5000) {
    return enif_make_badarg(env);
  }

  atomic_store_explicit(&started, 1, memory_order_release);
  struct timespec requested = {(time_t)(milliseconds / 1000),
                               (long)(milliseconds % 1000) * 1000000L};

  int rc;
  do { rc = nanosleep(&requested, &requested); } while (rc != 0 && errno == EINTR);
  atomic_store_explicit(&started, 0, memory_order_release);

  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM started_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argv;
  if (argc != 0) return enif_make_badarg(env);
  return enif_make_atom(env, atomic_load_explicit(&started, memory_order_acquire) ? "true" : "false");
}

static ErlNifFunc funcs[] = {
  {"sleep_ms", 1, sleep_ms, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"started", 0, started_nif, 0},
};

ERL_NIF_INIT(Elixir.Bendler.DirtyBlocker, funcs, NULL, NULL, NULL, NULL)
