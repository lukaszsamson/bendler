#include BENDLER_TRANSPORT
Term bendler_fn_run(Env e, Term* f, IoWork* w) { return bl_frame_next(e, w); }
static void __attribute__((constructor)) bendler_fn_use(void) { io_eff(CID_BENDLER_FN, bendler_fn_run, 0); }
