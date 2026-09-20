#include BENDLER_TRANSPORT
Term bendler_reply_run(Env e, Term* f, IoWork* w) {
  char* spec = bl_spec(e, f[0]);
  if (bl_req != bl_end) bl_fail("arguments left unread");   // cannot happen after validation
  BlBuf b = { 0 };
  bl_put32(&b, 0);
  if (spec[0] == '!') {
    bl_put_err(&b, "unknown function index");
  } else {
    const char* ty = spec;
    bl_encode(e, &ty, f[1], &b, 0);
  }
  free(spec);
  bl_frame_reply(&b);
  free(b.p);
  return term_pak(CID_UNIT, 0);
}
static void __attribute__((constructor)) bendler_reply_use(void) { io_eff(CID_BENDLER_REPLY, bendler_reply_run, 0); }
