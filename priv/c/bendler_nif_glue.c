// The generated runtime owns the state machine and resources in bendler_nif.h.
// Keeping the entry table separate allows substituting the Elixir module name.
#include <erl_nif.h>
int bendler_nif_load(ErlNifEnv*, void**, ERL_NIF_TERM);
int bendler_nif_upgrade(ErlNifEnv*, void**, void**, ERL_NIF_TERM);
ERL_NIF_TERM bendler_nif_init(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM bendler_nif_submit(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM bendler_nif_cancel(ErlNifEnv*, int, const ERL_NIF_TERM[]);
static ErlNifFunc funcs[] = {
  {"__bendler_init__", 0, bendler_nif_init, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"__bendler_submit", 3, bendler_nif_submit, 0},
  {"__bendler_cancel", 1, bendler_nif_cancel, 0}
};
// Upgrade is explicitly refused. The permanent callback-bearing resource,
// not an unload callback, postpones dlclose while runtime threads exist.
ERL_NIF_INIT(BENDLER_MODULE, funcs, bendler_nif_load, NULL, bendler_nif_upgrade, NULL)
