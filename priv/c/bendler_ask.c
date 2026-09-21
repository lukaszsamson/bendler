#include BENDLER_TRANSPORT
#ifdef BENDLER_NIF_H
static Term bl_ask_more(Env e, IoWork* w) {
  u8 byte;
  while (read(bl_pipe[0], &byte, 1) == 1) {}
  pthread_mutex_lock(&bl_lock);
  BlCall* c = bl_cur;
  bool failed = !c || c->cancelled || c->notified || bl_expired(c) || bl_dead;
  if (failed) {
    if (c && bl_expired(c)) bl_error_locked(c, "timeout");
    pthread_mutex_unlock(&bl_lock);
    bl_die("typed ask abandoned; no safe Bend continuation exists");
  }
  u8* reply = c->ask_reply;
  u64 len = c->ask_len;
  c->ask_reply = NULL;
  if (reply) c->event_pending = false;
  pthread_mutex_unlock(&bl_lock);
  if (!reply) return io_wait_on(w, bl_pipe[0], POLLIN, io_tick() + 100000000ull, bl_ask_more);
  const u8* saved = bl_req;
  const u8* saved_end = bl_end;
  bl_req = reply; bl_end = reply + len;
  Term answer = bl_decode_spec(e, c->ask_spec);
  bl_req = saved; bl_end = saved_end;
  free(reply);
  pthread_mutex_lock(&bl_lock);
  c->ask_active = false;
  pthread_mutex_unlock(&bl_lock);
  return answer;
}
Term bendler_ask_run(Env e, Term* f, IoWork* w) {
  char* spec = bl_spec(e, f[0]);
  char* response = bl_spec(e, f[1]);
  pthread_mutex_lock(&bl_lock);
  BlCall* c = bl_cur;
  bool valid = c && c->events && !c->event_pending && !c->ask_active;
  if (valid) { c->ask_active = true; free(c->ask_spec); c->ask_spec = response; }
  pthread_mutex_unlock(&bl_lock);
  if (!valid) { free(spec); free(response); bl_die("ask requires a callback owner"); }
  BlBuf b = {0};
  bl_put32(&b, 0); bl_put8(&b, 17);
  bl_encode_spec(e, spec, f[2], &b);
  free(spec); bl_event_frame(&b); free(b.p);
  return bl_ask_more(e, w);
}
#else
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
#endif
static void __attribute__((constructor)) bendler_ask_use(void) { io_eff(CID_BENDLER_ASK, bendler_ask_run, 0); }
