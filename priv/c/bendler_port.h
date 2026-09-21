// Bendler port transport: length-prefixed frames on stdin/stdout.
// Exit codes: 0 clean EOF at a frame boundary, 65 framing error or codec
// invariant violation, 74 transport error. A well-framed but invalid
// request is answered with an error frame and the worker goes on.
//
// Two kinds of frame travel each way. Host to worker: a request (the
// function index and its arguments) or, while a request is in flight and
// the worker is parked in `Bendler.emit`, a one-byte acknowledgement
// (1 go on, 0 the consumer is gone). Worker to host: a reply (a value or
// the error tag) or an EVENT frame (BL_EVENT then the encoded event).
#ifndef BENDLER_PORT_H
#define BENDLER_PORT_H
#include "bendler_common.h"

static u8* bl_in; static u64 bl_in_len; static u64 bl_in_cap; static bool bl_in_open;
// set while the worker is parked in Bendler.emit waiting for the host's
// acknowledgement: EOF is then the host leaving, not a truncated frame
static bool bl_await_ack;

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

// Grows the input buffer keeping the live request cursors valid: while an
// acknowledgement is awaited the request frame is still being read from
// this buffer, so a realloc must move bl_req and bl_end with it.
static void bl_in_reserve(u64 want) {
  if (bl_in_len + want <= bl_in_cap) return;
  u64 ro = bl_req ? (u64)(bl_req - bl_in) : 0;
  u64 eo = bl_end ? (u64)(bl_end - bl_in) : 0;
  u64 cap = bl_in_cap * 2 + want;
  u8* p = realloc(bl_in, cap);
  if (p == NULL) bl_fail("out of memory");
  if (bl_req) bl_req = p + ro;
  if (bl_end) bl_end = p + eo;
  bl_in = p; bl_in_cap = cap;
}

// One read into the free space, or a park. Answers 1 when bytes came in,
// 0 when the caller should park (the parking is the caller's, since each
// loop parks with its own continuation).
static int bl_in_read(void) {
  bl_in_reserve(65536);
  ssize_t r = read(0, bl_in + bl_in_len, bl_in_cap - bl_in_len);
  if (r > 0) { bl_in_len += (u64)r; return 1; }
  if (r == 0) {
    // EOF while an acknowledgement is awaited means the host is gone, not
    // a truncated frame: the request bytes still in the buffer are ours.
    if (bl_in_len != 0 && !bl_await_ack) bl_fail("EOF inside a frame");
    fflush(stdout); exit(0);
  }
  if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
  if (errno == EINTR) return 1;
  fprintf(stderr, "bendler worker: stdin read failed: errno=%d (%s)\n", errno, strerror(errno)); exit(74);
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
    if (!bl_in_read()) return io_wait_on(w, 0, POLLIN, 0, bl_frame_more);
  }
}

static Term bl_frame_next(Env e, IoWork* w) {
  if (!bl_in_open) {
    int flags = fcntl(0, F_GETFL);
    if (flags < 0 || fcntl(0, F_SETFL, flags | O_NONBLOCK) < 0) {
      fprintf(stderr, "bendler worker: stdin fcntl failed: errno=%d (%s)\n", errno, strerror(errno));
      exit(74);
    }
    bl_in_open = true;
  }
  if (bl_end != NULL) bl_drop_frame();
  return bl_frame_more(e, w);
}

// Parks until the host's one-byte acknowledgement of the event just
// written. The in-flight request frame still occupies [bl_in, bl_end), so
// the acknowledgement is the next frame after it; consuming it shifts the
// bytes behind it down and leaves the request untouched.
static Term bl_ack_more(Env e, IoWork* w) {
  for (;;) {
    u64 base = (u64)(bl_end - bl_in);
    if (bl_in_len >= base + 4) {
      u32 n = bl_rd32(bl_in + base);
      if (n != 1) bl_fail("an acknowledgement frame must be one byte");
      if (bl_in_len >= base + 5) {
        u8 v = bl_in[base + 4];
        if (v > 1) bl_fail("a malformed acknowledgement frame");
        memmove(bl_in + base, bl_in + base + 5, bl_in_len - base - 5);
        bl_in_len -= 5;
        bl_await_ack = false;
        return term_pak(v ? CID_TRUE : CID_FALSE, 0);
      }
    }
    if (!bl_in_read()) return io_wait_on(w, 0, POLLIN, 0, bl_ack_more);
  }
}

static Term bl_ack_next(Env e, IoWork* w) {
  if (bl_end == NULL) bl_fail("an event outside a request");
  bl_await_ack = true;
  return bl_ack_more(e, w);
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
      // Include EPIPE: it can be expected during shutdown, but the diagnostic
      // distinguishes it from other worker and launcher transport failures.
      fprintf(stderr, "bendler worker: stdout write failed: errno=%d (%s), remaining=%llu\n",
        errno, strerror(errno), (unsigned long long)left);
      exit(74);
    }
    if (r == 0) { fprintf(stderr, "bendler worker: stdout write made no progress\n"); exit(74); }
    p += r; left -= (u64)r;
  }
}
#endif
