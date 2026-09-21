#include BENDLER_TRANSPORT
// One callback at a time. The original request remains in bl_in while
// the response arrives; only temporarily lend the codec its cursor.
static char* bl_ask_spec;
static Term bl_ask_more(Env e, IoWork* w) {
  for (;;) {
    u64 base = (u64)(bl_end - bl_in);
    if (bl_in_len >= base + 4) {
      u32 n = bl_rd32(bl_in + base);
      if (n > BENDLER_MAX_FRAME) bl_fail("callback response too large");
      if (bl_in_len >= base + 4 + (u64)n) {
        const u8* p = bl_in + base + 4;
        const char* spec = bl_ask_spec;
        BlCheck check = {p, p + n, 0, 0, NULL};
        bl_check(&check, &spec, 0, bl_spec_has_dyn(spec, bl_skip_type(spec)));
        if (check.err || check.p != check.end) bl_fail("invalid callback response");
        const u8* saved = bl_req;
        const u8* saved_end = bl_end;
        bl_req = p;
        bl_end = p + n;
        Term answer = bl_decode_spec(e, bl_ask_spec);
        bl_req = saved;
        bl_end = saved_end;
        free(bl_ask_spec); bl_ask_spec = NULL;
        memmove(bl_in + base, bl_in + base + 4 + n, bl_in_len - base - 4 - n);
        bl_in_len -= 4 + (u64)n;
        bl_await_ack = false;
        return answer;
      }
    }
    if (!bl_in_read()) return io_wait_on(w, 0, POLLIN, 0, bl_ask_more);
  }
}
Term bendler_ask_run(Env e, Term* f, IoWork* w) {
  char* spec = bl_spec(e, f[0]);
  bl_ask_spec = bl_spec(e, f[1]);
  BlBuf b = {0};
  bl_put32(&b, 0); bl_put8(&b, 17);
  bl_encode_spec(e, spec, f[2], &b);
  free(spec); bl_frame_reply(&b); free(b.p);
  bl_await_ack = true;
  return bl_ask_more(e, w);
}
static void __attribute__((constructor)) bendler_ask_use(void) { io_eff(CID_BENDLER_ASK, bendler_ask_run, 0); }
