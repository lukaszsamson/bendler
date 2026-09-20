// Bendler port transport: length-prefixed frames on stdin/stdout.
// Exit codes: 0 clean EOF at a frame boundary, 65 framing error or codec
// invariant violation, 74 transport error. A well-framed but invalid
// request is answered with an error frame and the worker goes on.
#ifndef BENDLER_PORT_H
#define BENDLER_PORT_H
#include "bendler_common.h"

static u8* bl_in; static u64 bl_in_len; static u64 bl_in_cap; static bool bl_in_open;

static void bl_fail(const char* msg) {
  fprintf(stderr, "bendler: %s\n", msg);
  exit(65);
}

static void bl_frame_reply(BlBuf* b);

static void bl_error_frame(const char* msg) {
  BlBuf b = { 0 };
  bl_put32(&b, 0);
  bl_put_err(&b, msg);
  bl_frame_reply(&b);
  free(b.p);
}

static void bl_drop_frame(void) {
  u64 used = (u64)(bl_end - bl_in);
  memmove(bl_in, bl_in + used, bl_in_len - used);
  bl_in_len -= used;
  bl_req = bl_end = NULL;
}

// Parks until a whole frame is in, validates it, and makes it the current
// request; an invalid one is answered and dropped here.
static Term bl_frame_more(Env e, IoWork* w) {
  for (;;) {
    if (bl_in_len >= 4) {
      u32 n = bl_rd32(bl_in);
      if (n > BENDLER_MAX_FRAME) bl_fail("request past BENDLER_MAX_FRAME");
      if (bl_in_len >= 4 + (u64)n) {
        bl_req = bl_in + 4;
        bl_end = bl_in + 4 + n;
        const char* err = n < 4 ? "short request" : NULL;
        u32 fn = 0;
        if (!err) { fn = bl_rd32(bl_req); bl_req += 4; }
        if (!err && fn >= BENDLER_FN_COUNT) err = "unknown function index";
        if (!err) err = bl_validate(fn, bl_req, bl_end);
        if (err) { bl_error_frame(err); bl_drop_frame(); continue; }
        return (Term)fn;
      }
    }
    if (bl_in_len + 65536 > bl_in_cap) {
      u64 cap = bl_in_cap * 2 + 65536;
      u8* p = realloc(bl_in, cap);
      if (p == NULL) bl_fail("out of memory");
      bl_in = p; bl_in_cap = cap;
    }
    ssize_t r = read(0, bl_in + bl_in_len, bl_in_cap - bl_in_len);
    if (r > 0) { bl_in_len += (u64)r; continue; }
    if (r == 0) {
      if (bl_in_len != 0) bl_fail("EOF inside a frame");
      fflush(stdout); exit(0);
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) return io_wait_on(w, 0, POLLIN, 0, bl_frame_more);
    if (errno != EINTR) { fprintf(stderr, "bendler: stdin read failed\n"); exit(74); }
  }
}

static Term bl_frame_next(Env e, IoWork* w) {
  if (!bl_in_open) { bl_in_open = true; fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK); }
  if (bl_end != NULL) bl_drop_frame();
  return bl_frame_more(e, w);
}

// The reply write is synchronous: the pipe to the VM is drained by the VM,
// and one request is in flight, so nothing else waits on the loop meanwhile.
static void bl_frame_reply(BlBuf* b) {
  u32 n = (u32)(b->len - 4);
  u8 hd[4] = { n >> 24, n >> 16, n >> 8, n }; memcpy(b->p, hd, 4);
  const u8* p = b->p; u64 left = b->len;
  while (left > 0) {
    ssize_t r = write(1, p, left);
    if (r < 0) {
      if (errno == EINTR) continue;
      // the host closed the pipe (a deadline, a shutdown): leave quietly
      if (errno != EPIPE) fprintf(stderr, "bendler: stdout write failed\n");
      exit(74);
    }
    p += r; left -= (u64)r;
  }
}
#endif
