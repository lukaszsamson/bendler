#include BENDLER_TRANSPORT
// Bendler.emit(-A, spec, x): encodes x as an EVENT frame, writes it to the
// host, then parks on the host's one-byte acknowledgement and answers it
// as a Bool. At most one event is outstanding, so the worker never runs
// ahead of the consumer, and False is the consumer asking it to stop.
Term bendler_emit_run(Env e, Term* f, IoWork* w) {
  char* spec = bl_spec(e, f[0]);
  BlBuf b = { 0 };
  bl_put32(&b, 0);
  bl_put8(&b, BL_EVENT);
  bl_encode_spec(e, spec, f[1], &b);
  free(spec);
  bl_frame_reply(&b);
  free(b.p);
  return bl_ack_next(e, w);
}
static void __attribute__((constructor)) bendler_emit_use(void) { io_eff(CID_BENDLER_EMIT, bendler_emit_run, 0); }
