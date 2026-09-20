#include <erl_nif.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

void bendler_start(int threads, int max_waiting);
int  bendler_call(const uint8_t* req, uint64_t len, int timeout_ms, uint8_t** rep, uint64_t* rep_len, const char** err);

static ERL_NIF_TERM error(ErlNifEnv* env, const char* what) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, what));
}

// __bendler_call(frame :: binary, timeout_ms :: integer | -1) ::
//   binary | {:error, :busy | :timeout | :nomem} | {:error, {:invalid, charlist}}
//   | raises {:bendler_dead, charlist}
static ERL_NIF_TERM call_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary req; int timeout_ms;
  if (!enif_inspect_binary(env, argv[0], &req) || !enif_get_int(env, argv[1], &timeout_ms)) return enif_make_badarg(env);
  uint8_t* rep = NULL; uint64_t rep_len = 0; const char* err = NULL;
  switch (bendler_call(req.data, req.size, timeout_ms, &rep, &rep_len, &err)) {
    case 0: break;
    case 1: return enif_raise_exception(env, enif_make_tuple2(env, enif_make_atom(env, "bendler_dead"),
              enif_make_string(env, err, ERL_NIF_LATIN1)));
    case 2: return error(env, "busy");
    case 3: return error(env, "timeout");
    case 5: return enif_make_tuple2(env, enif_make_atom(env, "error"),
              enif_make_tuple2(env, enif_make_atom(env, "invalid"), enif_make_string(env, err, ERL_NIF_LATIN1)));
    default: return error(env, "nomem");
  }
  ERL_NIF_TERM out;
  unsigned char* p = enif_make_new_binary(env, rep_len, &out);
  memcpy(p, rep, rep_len);
  free(rep);
  return out;
}

// load_info is {threads, max_waiting}
static int load(ErlNifEnv* env, void** priv, ERL_NIF_TERM info) {
  int arity = 0; const ERL_NIF_TERM* items; int threads = 1, max_waiting = 4;
  if (enif_get_tuple(env, info, &arity, &items) && arity == 2) {
    enif_get_int(env, items[0], &threads);
    enif_get_int(env, items[1], &max_waiting);
  }
  bendler_start(threads > 0 ? threads : 1, max_waiting);
  return 0;
}

// No upgrade callback, so a second load_nif of the same module is refused;
// no unload callback because there is nothing it could do: the runtime
// thread and its workers cannot be stopped. That is a limitation, not a
// protection: purging the module's code after a load lets the library be
// unloaded under threads still executing it. Pinning it with a resource
// whose destructor covers every thread is the open item in docs/MVP.md.
static ErlNifFunc funcs[] = {
  { "__bendler_call", 2, call_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
};

ERL_NIF_INIT(BENDLER_MODULE, funcs, load, NULL, NULL, NULL)
