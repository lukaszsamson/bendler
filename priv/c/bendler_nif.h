// Bendler NIF transport: the Bend event loop runs on its own thread inside the
// BEAM; a dirty NIF hands it a request frame and waits for the reply frame.
//
// Lock discipline: bl_lock guards the mailbox only and is never held across an
// allocation or a runtime call, so the failure path (bl_die) can always take
// it. Requests are validated by the caller's thread before they are posted,
// so the loop only ever decodes well-formed input. A request buffer belongs
// to the loop from hand-over to reply (Bendler.arg reads it lazily during the
// call); a caller that gave up marks its call abandoned and the loop frees it.
#ifndef BENDLER_NIF_H
#define BENDLER_NIF_H
#include "bendler_common.h"

static pthread_mutex_t bl_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  bl_cv   = PTHREAD_COND_INITIALIZER;
static int   bl_pipe[2];

typedef struct BlCall {
  u8*  req; u64 req_len;
  u8*  rep; u64 rep_len;
  bool done; bool abandoned;
} BlCall;
static BlCall* bl_next;              // posted, not yet taken by the loop
static BlCall* bl_cur;               // being served
static bool  bl_dead;
static char  bl_err[256];
static int   bl_waiting;             // callers admitted (waiting or in flight)
static int   bl_max_waiting = 4;

static void bl_die(const char* msg) {
  pthread_mutex_lock(&bl_lock);
  if (!bl_dead) { bl_dead = true; snprintf(bl_err, sizeof bl_err, "%s", msg); }
  pthread_cond_broadcast(&bl_cv);
  pthread_mutex_unlock(&bl_lock);
  for (;;) pause();  // the runtime freezes; the VM lives on
}

// Replaces the runtime's _exit: a runtime error no longer kills the VM.
void bendler_die(int code) {
  char msg[64]; snprintf(msg, sizeof msg, "bend runtime exited with code %d", code);
  bl_die(msg);
}

// After validation a codec failure is a bendler bug: freeze this runtime.
static void bl_fail(const char* msg) { bl_die(msg); }

static void bl_deliver(u8* p, u64 n) {
  pthread_mutex_lock(&bl_lock);
  BlCall* c = bl_cur; bl_cur = NULL;
  if (c == NULL) { free(p); }
  else if (c->abandoned) { free(p); free(c->req); free(c); }
  else { c->rep = p; c->rep_len = n; c->done = true; }
  pthread_cond_broadcast(&bl_cv);
  pthread_mutex_unlock(&bl_lock);
}

static Term bl_frame_more(Env e, IoWork* w) {
  pthread_mutex_lock(&bl_lock);
  if (bl_next == NULL) {
    pthread_mutex_unlock(&bl_lock);
    return io_wait_on(w, bl_pipe[0], POLLIN, 0, bl_frame_more);
  }
  u8 byte; while (read(bl_pipe[0], &byte, 1) == 1) {}
  bl_cur = bl_next; bl_next = NULL;
  bl_req = bl_cur->req; bl_end = bl_cur->req + bl_cur->req_len;
  pthread_cond_broadcast(&bl_cv);   // the slot is free for the next poster
  pthread_mutex_unlock(&bl_lock);
  u32 fn = bl_rd32(bl_req); bl_req += 4;   // validated by the poster
  return (Term)fn;
}

static Term bl_frame_next(Env e, IoWork* w) { return bl_frame_more(e, w); }

static void bl_frame_reply(BlBuf* b) {
  u64 n = b->len - 4;
  u8* p = malloc(n + 1);
  if (p == NULL) bl_die("out of memory");
  memcpy(p, b->p + 4, n);
  bl_deliver(p, n);
}

static void* bl_thread(void* arg) {
  char  thr[16]; snprintf(thr, sizeof thr, "%d", (int)(intptr_t)arg);
  char* argv[] = { "bend", "--threads", thr, "--gpu", "off", NULL };
  bend_main(5, argv);
  bl_die("bend main returned");
  return NULL;
}

// The plain C API the NIF glue (a separate translation unit) links against.
void bendler_start(int threads, int max_waiting) {
  static bool up;
  if (up) return;
  up = true;
  if (max_waiting > 0) bl_max_waiting = max_waiting;
  if (pipe(bl_pipe)) { bl_dead = true; snprintf(bl_err, sizeof bl_err, "pipe failed"); return; }
  for (int i = 0; i < 2; i += 1) fcntl(bl_pipe[i], F_SETFL, fcntl(bl_pipe[i], F_GETFL) | O_NONBLOCK);
  pthread_t tid;
  if (pthread_create(&tid, NULL, bl_thread, (void*)(intptr_t)threads)) { bl_dead = true; snprintf(bl_err, sizeof bl_err, "pthread_create failed"); return; }
  pthread_detach(tid);
}

enum { BENDLER_OK = 0, BENDLER_DEAD = 1, BENDLER_BUSY = 2, BENDLER_TIMEOUT = 3, BENDLER_NOMEM = 4, BENDLER_INVALID = 5 };

// Waits on bl_cv until the deadline (monotonic on Linux, relative on macOS).
static int bl_wait(int timeout_ms, const struct timespec* deadline) {
  if (timeout_ms < 0) return pthread_cond_wait(&bl_cv, &bl_lock);
#ifdef __APPLE__
  struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
  struct timespec rel = { deadline->tv_sec - now.tv_sec, deadline->tv_nsec - now.tv_nsec };
  if (rel.tv_nsec < 0) { rel.tv_sec -= 1; rel.tv_nsec += 1000000000L; }
  if (rel.tv_sec < 0) return ETIMEDOUT;
  return pthread_cond_timedwait_relative_np(&bl_cv, &bl_lock, &rel);
#else
  return pthread_cond_timedwait(&bl_cv, &bl_lock, deadline);
#endif
}

// Validates, then hands the request to the loop; one request at a time
// reaches it and at most bl_max_waiting callers are admitted (waiting or in
// flight), the rest are told busy at once. timeout_ms < 0 waits forever;
// the deadline is total (queue time included). On a timeout the request
// keeps running and its reply is discarded: it cannot be cancelled.
int bendler_call(const u8* req, u64 len, int timeout_ms, u8** rep, u64* rep_len, const char** err) {
  if (len < 4) { *err = "short request"; return BENDLER_INVALID; }
  if (len > BENDLER_MAX_FRAME) { *err = "request past BENDLER_MAX_FRAME"; return BENDLER_INVALID; }
  u32 fn = bl_rd32(req);
  if (fn >= BENDLER_FN_COUNT) { *err = "unknown function index"; return BENDLER_INVALID; }
  const char* bad = bl_validate(fn, req + 4, req + len);
  if (bad) { *err = bad; return BENDLER_INVALID; }

  pthread_mutex_lock(&bl_lock);
  if (bl_dead) { *err = bl_err; pthread_mutex_unlock(&bl_lock); return BENDLER_DEAD; }
  if (bl_waiting >= bl_max_waiting) { pthread_mutex_unlock(&bl_lock); return BENDLER_BUSY; }
  bl_waiting += 1;
  pthread_mutex_unlock(&bl_lock);

  BlCall* c = calloc(1, sizeof *c);
  u8* buf = malloc(len + 1);
  if (c == NULL || buf == NULL) {
    free(c); free(buf);
    pthread_mutex_lock(&bl_lock); bl_waiting -= 1; pthread_cond_broadcast(&bl_cv); pthread_mutex_unlock(&bl_lock);
    return BENDLER_NOMEM;
  }
  memcpy(buf, req, len);
  c->req = buf; c->req_len = len;
  struct timespec deadline;
  if (timeout_ms >= 0) {
    clock_gettime(CLOCK_MONOTONIC, &deadline);
    deadline.tv_sec  += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec += 1; deadline.tv_nsec -= 1000000000L; }
  }

  pthread_mutex_lock(&bl_lock);
  int rc = BENDLER_OK;
  while (bl_next != NULL && !bl_dead && rc == BENDLER_OK) {
    if (bl_wait(timeout_ms, &deadline) == ETIMEDOUT) rc = BENDLER_TIMEOUT;
  }
  bool posted = false;
  if (rc == BENDLER_OK && !bl_dead) {
    bl_next = c; posted = true;
    u8 byte = 1;
    while (write(bl_pipe[1], &byte, 1) < 0 && errno == EINTR) {}   // EAGAIN: a byte is already pending
    while (!c->done && !bl_dead && rc == BENDLER_OK) {
      if (bl_wait(timeout_ms, &deadline) == ETIMEDOUT) rc = BENDLER_TIMEOUT;
    }
  }
  bl_waiting -= 1;
  if (bl_dead) { rc = BENDLER_DEAD; *err = bl_err; }
  if (c->done) {
    if (rc == BENDLER_OK) { *rep = c->rep; *rep_len = c->rep_len; } else free(c->rep);
    free(c->req); free(c);
  } else if (posted) {
    if (bl_next == c) { bl_next = NULL; free(c->req); free(c); }   // never taken: withdraw it
    else c->abandoned = true;                                         // the loop frees it at reply
  } else {
    free(c->req); free(c);
  }
  pthread_cond_broadcast(&bl_cv);
  pthread_mutex_unlock(&bl_lock);
  return rc;
}
#endif
