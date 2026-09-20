#include BENDLER_TRANSPORT
Term bendler_arg_run(Env e, Term* f, IoWork* w) {
  char* spec = bl_spec(e, f[0]);
  const char* ty = spec;
  Term t = bl_decode(e, &ty, 0);
  free(spec);
  return t;
}
static void __attribute__((constructor)) bendler_arg_use(void) { io_eff(CID_BENDLER_ARG, bendler_arg_run, 0); }
