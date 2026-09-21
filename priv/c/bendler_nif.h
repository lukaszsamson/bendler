// Experimental NIF: bounded asynchronous requests, with a VM-lifetime pin.
// All request ownership lives here; the separate glue only exports entry points.
#ifndef BENDLER_NIF_H
#define BENDLER_NIF_H
#include <erl_nif.h>
#include <limits.h>
#include "bendler_common.h"

enum { BL_RESERVED, BL_QUEUED, BL_RUNNING, BL_DELIVERING, BL_FINISHED };
typedef struct BlCall BlCall;
struct BlCall {
  u8* req;
  u64 len;
  ErlNifEnv* env;               // immutable reference term; no payload terms
  ERL_NIF_TERM ref;
  ErlNifPid pid;
  ErlNifMonitor monitor;
  bool monitored, cancelled, notified;
  bool events, event_pending, ack_ready, ack_go, ask_active;
  ErlNifUInt64 event_seq;
  char* ask_spec;
  u8* ask_reply;
  u64 ask_len;
  int state;
  int64_t deadline;
  BlCall* next;
};

static pthread_mutex_t bl_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t bl_init_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t bl_cv;
static bool bl_cv_ready, bl_loaded, bl_init_once, bl_ready, bl_dead;
static int bl_threads, bl_max_waiting, bl_waiting;
static int bl_pipe[2] = {-1, -1};
static BlCall *bl_head, *bl_tail, *bl_cur;
static ErlNifResourceType *bl_call_type, *bl_pin_type;
static void* bl_pin;
static char bl_err[256];

// Called under bl_lock. A full pipe already contains a pending wake-up.
static void bl_wake_locked(void) {
  u8 byte = 1;
  ssize_t n;
  do { n = write(bl_pipe[1], &byte, 1); } while (n < 0 && errno == EINTR);
}

// enif_monotonic_time is scheduler-thread-only (OTP returns TIME_ERROR on
// our Bend pthread). Store deadlines in the OS clock domain after admission.
static int64_t bl_now(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts)) return INT64_MAX;
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static bool bl_expired(BlCall* c) { return c->deadline != INT64_MAX && bl_now() >= c->deadline; }
static ERL_NIF_TERM bl_error(ErlNifEnv* env, const char* reason) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, reason));
}
static ERL_NIF_TERM bl_invalid(ErlNifEnv* env, const char* reason) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"),
    enif_make_tuple2(env, enif_make_atom(env, "invalid"), enif_make_string(env, reason, ERL_NIF_LATIN1)));
}

// Only tiny envelopes are allocated under this lock; large binary construction
// happens outside it. Cancellation and sending share the lock.
static void bl_error_locked(BlCall* c, const char* reason) {
  if (c->cancelled || c->notified) return;
  ErlNifEnv* env = enif_alloc_env();
  if (env) {
    ERL_NIF_TERM msg = enif_make_tuple3(env, enif_make_atom(env, "bendler_reply"),
      enif_make_copy(env, c->ref), bl_error(env, reason));
    (void)enif_send(NULL, &c->pid, env, msg);
    enif_free_env(env);
  }
  c->notified = true;
}
static void bl_unlink_locked(BlCall* c) {
  BlCall** p = &bl_head;
  BlCall* prev = NULL;
  while (*p && *p != c) { prev = *p; p = &(*p)->next; }
  if (*p) { *p = c->next; if (bl_tail == c) bl_tail = prev; c->next = NULL; }
}
static void bl_clear(BlCall* c) {
  if (c->monitored) { (void)enif_demonitor_process(NULL, c, &c->monitor); c->monitored = false; }
  free(c->req); c->req = NULL;
  free(c->ask_spec); c->ask_spec = NULL;
  free(c->ask_reply); c->ask_reply = NULL;
  if (c->env) { enif_free_env(c->env); c->env = NULL; }
}
// Called only once per queued/runtime-owned request, after detaching it.
static void bl_release(BlCall* c) { bl_clear(c); enif_release_resource(c); }
static void bl_cancel(BlCall* c) {
  bool release = false;
  pthread_mutex_lock(&bl_lock);
  c->cancelled = true;
  if (c->state == BL_RUNNING) bl_wake_locked();
  if (c->state == BL_QUEUED) {
    bl_unlink_locked(c); c->state = BL_FINISHED; bl_waiting--; release = true;
  }
  // RESERVED belongs to the scheduled term; its dirty continuation or dtor
  // retires admission. RUNNING/DELIVERING retains the native hold until reply.
  pthread_mutex_unlock(&bl_lock);
  if (release) bl_release(c);
}
static void bl_down(ErlNifEnv* env, void* obj, ErlNifPid* pid, ErlNifMonitor* mon) {
  (void)env; (void)pid; (void)mon; bl_cancel(obj);
}
static void bl_call_dtor(ErlNifEnv* env, void* obj) {
  (void)env;
  BlCall* c = obj;
  pthread_mutex_lock(&bl_lock);
  if (c->state == BL_RESERVED) { c->state = BL_FINISHED; bl_waiting--; }
  pthread_mutex_unlock(&bl_lock);
  // OTP already dismantled this resource's monitors before calling dtor.
  // Calling enif_demonitor_process here would touch a dying monitor tree.
  free(c->req); c->req = NULL;
  free(c->ask_spec); c->ask_spec = NULL;
  free(c->ask_reply); c->ask_reply = NULL;
  if (c->env) { enif_free_env(c->env); c->env = NULL; }
  c->monitored = false;
}
static void bl_pin_dtor(ErlNifEnv* env, void* obj) { (void)env; (void)obj; }

static void bl_die(const char* reason) {
  pthread_mutex_lock(&bl_lock);
  bl_dead = true;
  snprintf(bl_err, sizeof bl_err, "%s", reason);
  BlCall* pending = bl_head; bl_head = bl_tail = NULL;
  for (BlCall* c = pending; c; c = c->next) {
    c->state = BL_FINISHED; bl_waiting--; bl_error_locked(c, "dead");
  }
  // Other Bend workers may still read the current request. Freeze it in place,
  // including its native resource hold, rather than freeing live memory.
  if (bl_cur) bl_error_locked(bl_cur, "dead");
  bl_wake_locked();
  if (bl_cv_ready) pthread_cond_broadcast(&bl_cv);
  pthread_mutex_unlock(&bl_lock);
  while (pending) { BlCall* next = pending->next; bl_release(pending); pending = next; }
  for (;;) pause();
}
void bendler_die(int code) {
  char reason[64]; snprintf(reason, sizeof reason, "bend runtime exited with code %d", code);
  bl_die(reason);
}
static void bl_fail(const char* reason) { bl_die(reason); }

static Term bl_frame_more(Env e, IoWork* w) {
  (void)e;
  u8 byte;
  while (read(bl_pipe[0], &byte, 1) == 1) {}
  for (;;) {
    pthread_mutex_lock(&bl_lock);
    if (bl_dead) { pthread_mutex_unlock(&bl_lock); bl_die("runtime is dead"); }
    BlCall* c = bl_head;
    if (!c) {
      pthread_mutex_unlock(&bl_lock);
      return io_wait_on(w, bl_pipe[0], POLLIN, 0, bl_frame_more);
    }
    bl_unlink_locked(c);
    if (c->cancelled || bl_expired(c)) {
      c->state = BL_FINISHED; bl_waiting--; bl_error_locked(c, "timeout");
      pthread_mutex_unlock(&bl_lock);
      bl_release(c);
      continue;
    }
    c->state = BL_RUNNING; bl_cur = c;
    bl_req = c->req; bl_end = c->req + c->len;
    pthread_mutex_unlock(&bl_lock);
    u32 fn = bl_rd32(bl_req); bl_req += 4;
    return (Term)fn;
  }
}
static Term bl_frame_next(Env e, IoWork* w) {
  pthread_mutex_lock(&bl_lock);
  bl_ready = true;
  pthread_cond_broadcast(&bl_cv);
  pthread_mutex_unlock(&bl_lock);
  return bl_frame_more(e, w);
}
// Event encoding has already enforced the frame budget. Allocate/copy away
// from bl_lock; the running request's native hold protects c throughout.
static void bl_event_frame(BlBuf* b) {
  pthread_mutex_lock(&bl_lock);
  BlCall* c = bl_cur;
  bool overlapping = c && c->events && c->event_pending;
  bool send_event = c && c->events && !c->cancelled && !c->notified && !bl_expired(c);
  pthread_mutex_unlock(&bl_lock);
  if (overlapping) bl_fail("concurrent emit effects are unsupported");
  if (!send_event) return;

  ErlNifEnv* env = enif_alloc_env();
  ERL_NIF_TERM binary = 0;
  u64 len = b->len - 5;
  u8* out = env ? enif_make_new_binary(env, len, &binary) : NULL;
  bool ok = env && (out || len == 0);
  if (ok && len) memcpy(out, b->p + 5, len);
  pthread_mutex_lock(&bl_lock);
  if (!c->cancelled && !c->notified) {
    if (bl_dead) bl_error_locked(c, "dead");
    else if (bl_expired(c)) bl_error_locked(c, "timeout");
    else if (!ok) bl_error_locked(c, "nomem");
    else {
      c->event_seq++;
      c->event_pending = true; c->ack_ready = false;
      ERL_NIF_TERM msg = enif_make_tuple4(env, enif_make_atom(env, "bendler_event"),
        enif_make_copy(env, c->ref), enif_make_uint64(env, c->event_seq), binary);
      if (!enif_send(NULL, &c->pid, env, msg)) c->cancelled = true;
    }
  }
  pthread_mutex_unlock(&bl_lock);
  if (env) enif_free_env(env);
}

static Term bl_ack_more(Env e, IoWork* w) {
  (void)e;
  u8 byte;
  while (read(bl_pipe[0], &byte, 1) == 1) {}
  pthread_mutex_lock(&bl_lock);
  BlCall* c = bl_cur;
  int64_t now = bl_now();
  bool expired = c && c->deadline != INT64_MAX && now >= c->deadline;
  if (bl_dead) { pthread_mutex_unlock(&bl_lock); bl_die("runtime is dead"); }
  if (!c || !c->events || c->cancelled || c->notified || expired) {
    if (c) {
      if (expired) bl_error_locked(c, "timeout");
      c->event_pending = false;
    }
    pthread_mutex_unlock(&bl_lock);
    return term_pak(CID_FALSE, 0);
  }
  if (c->ack_ready) {
    bool go = c->ack_go;
    c->ack_ready = false; c->event_pending = false;
    pthread_mutex_unlock(&bl_lock);
    return term_pak(go ? CID_TRUE : CID_FALSE, 0);
  }
  // Translate milliseconds to the runtime's nanosecond tick. Recheck at
  // most 1s later, avoiding overflow for very distant finite deadlines.
  u64 at = 0;
  if (c->deadline != INT64_MAX) {
    u64 ms = (u64)c->deadline - (u64)now;
    if (ms > 1000) ms = 1000;
    at = io_tick() + ms * 1000000ull;
  }
  pthread_mutex_unlock(&bl_lock);
  return io_wait_on(w, bl_pipe[0], POLLIN, at, bl_ack_more);
}
static Term bl_ack_next(Env e, IoWork* w) { return bl_ack_more(e, w); }

// Dirty CPU entry: validate the typed response before copying or waking Bend.
// The sequence and owner checks prevent stale or foreign replies crossing calls.
ERL_NIF_TERM bendler_nif_answer(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  BlCall* c; ErlNifBinary bin; ErlNifUInt64 seq; ErlNifPid pid;
  if (!enif_get_resource(env, argv[0], bl_call_type, (void**)&c) ||
      !enif_get_uint64(env, argv[1], &seq) || !enif_inspect_binary(env, argv[2], &bin) ||
      !enif_self(env, &pid) || enif_compare_pids(&pid, &c->pid)) return enif_make_badarg(env);
  if (bin.size > BENDLER_MAX_FRAME) return bl_invalid(env, "callback response too large");
  pthread_mutex_lock(&bl_lock);
  bool valid = c->state == BL_RUNNING && c->event_pending && c->event_seq == seq &&
    c->ask_spec && !c->ask_reply && !c->cancelled && !c->notified && !bl_expired(c);
  char* spec = valid ? strdup(c->ask_spec) : NULL;
  pthread_mutex_unlock(&bl_lock);
  if (!valid) return bl_error(env, "refused");
  if (!spec) return bl_error(env, "nomem");
  const char* at = spec;
  BlCheck check = {bin.data, bin.data + bin.size, 0, 0, NULL};
  bl_check(&check, &at, 0, bl_spec_has_dyn(spec, bl_skip_type(spec)));
  free(spec);
  if (check.err || check.p != check.end) return bl_invalid(env, "invalid callback response");
  u8* copy = malloc(bin.size + 1);
  if (!copy) return bl_error(env, "nomem");
  memcpy(copy, bin.data, bin.size);
  pthread_mutex_lock(&bl_lock);
  valid = c->state == BL_RUNNING && c->event_pending && c->event_seq == seq &&
    !c->ask_reply && !c->cancelled && !c->notified && !bl_expired(c);
  if (valid) { c->ask_reply = copy; c->ask_len = bin.size; bl_wake_locked(); }
  pthread_mutex_unlock(&bl_lock);
  if (!valid) free(copy);
  return valid ? enif_make_atom(env, "ok") : bl_error(env, "refused");
}

static void bl_frame_reply(BlBuf* b) {
  if (b->len > 4 && b->p[4] == BL_EVENT) { bl_event_frame(b); return; }
  pthread_mutex_lock(&bl_lock);
  BlCall* c = bl_cur; bl_cur = NULL;
  if (c) c->state = BL_DELIVERING;
  pthread_mutex_unlock(&bl_lock);
  if (!c) return;

  ErlNifEnv* env = enif_alloc_env();
  ERL_NIF_TERM msg = 0;
  if (env) {
    ERL_NIF_TERM binary;
    u64 len = b->len - 4;
    u8* out = enif_make_new_binary(env, len, &binary);
    if (out || len == 0) {
      if (len) memcpy(out, b->p + 4, len);
    } else binary = bl_error(env, "nomem");
    msg = enif_make_tuple3(env, enif_make_atom(env, "bendler_reply"),
      enif_make_copy(env, c->ref), binary);
  }
  pthread_mutex_lock(&bl_lock);
  if (!c->cancelled && !c->notified) {
    if (bl_dead) bl_error_locked(c, "dead");
    else if (bl_expired(c)) bl_error_locked(c, "timeout");
    else if (!env) bl_error_locked(c, "nomem");
    else { (void)enif_send(NULL, &c->pid, env, msg); c->notified = true; }
  }
  c->state = BL_FINISHED; bl_waiting--;
  pthread_mutex_unlock(&bl_lock);
  if (env) enif_free_env(env);
  bl_release(c);
}
static void* bl_thread(void* arg) {
  (void)arg;
#if defined(BENDLER_TEST_INIT_FAILURE) && BENDLER_TEST_INIT_FAILURE == 2
  bl_die("injected failure after native thread creation");
#endif
  char threads[16]; snprintf(threads, sizeof threads, "%d", bl_threads);
  char* argv[] = {"bend", "--threads", threads, "--gpu", "off", NULL};
  bend_main(5, argv);
  bl_die("bend main returned");
  return NULL;
}

// Resource types are registered in load, but allocated only AFTER load commits.
int bendler_nif_load(ErlNifEnv* env, void** priv, ERL_NIF_TERM info) {
  int arity, dirty;
  const ERL_NIF_TERM* fields;
  if (bl_loaded || !enif_get_tuple(env, info, &arity, &fields) || arity != 3 ||
      !enif_get_int(env, fields[0], &bl_threads) || bl_threads < 1 || bl_threads > 128 ||
      !enif_get_int(env, fields[1], &bl_max_waiting) || bl_max_waiting < 1 ||
      !enif_get_int(env, fields[2], &dirty) || dirty < 1) return -1;
  ErlNifResourceTypeInit init = {0};
  init.dtor = bl_call_dtor; init.down = bl_down;
  bl_call_type = enif_open_resource_type_x(env, "bendler_call", &init, ERL_NIF_RT_CREATE, NULL);
  bl_pin_type = enif_open_resource_type(env, NULL, "bendler_runtime_pin",
    bl_pin_dtor, ERL_NIF_RT_CREATE, NULL);
  if (!bl_call_type || !bl_pin_type) return -1;
  bl_loaded = true; *priv = NULL;
  return 0;
}
int bendler_nif_upgrade(ErlNifEnv* env, void** priv, void** old, ERL_NIF_TERM info) {
  (void)env; (void)priv; (void)old; (void)info; return -1;
}

ERL_NIF_TERM bendler_nif_init(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc; (void)argv;
  bool thread_started = false;
  int rc = 0;
  pthread_mutex_lock(&bl_init_lock);
  if (bl_init_once) {
    pthread_mutex_lock(&bl_lock); bool ok = bl_ready && !bl_dead; pthread_mutex_unlock(&bl_lock);
    pthread_mutex_unlock(&bl_init_lock);
    return ok ? enif_make_atom(env, "ok") : bl_error(env, "init_failed");
  }
  bl_init_once = true;
  bl_pin = enif_alloc_resource(bl_pin_type, 1);
  if (!bl_pin) goto failed;
#if defined(BENDLER_TEST_INIT_FAILURE) && BENDLER_TEST_INIT_FAILURE == 1
  goto failed;
#endif
  pthread_condattr_t ca;
  if (pthread_condattr_init(&ca)) goto failed;
#ifndef __APPLE__
  rc = pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
#endif
  if (!rc) rc = pthread_cond_init(&bl_cv, &ca);
  if (pthread_condattr_destroy(&ca) && !rc) rc = EINVAL;
  if (rc) goto failed;
  bl_cv_ready = true;
  if (pipe(bl_pipe)) goto failed;
  for (int i = 0; i < 2; i++) {
    int flags = fcntl(bl_pipe[i], F_GETFL);
    if (flags < 0 || fcntl(bl_pipe[i], F_SETFL, flags | O_NONBLOCK) < 0) goto failed;
  }
  pthread_attr_t attr;
  if (pthread_attr_init(&attr)) goto failed;
  rc = pthread_attr_setstacksize(&attr, 16u << 20);
  if (!rc) rc = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_t tid;
  if (!rc) { rc = pthread_create(&tid, &attr, bl_thread, NULL); thread_started = rc == 0; }
  if (pthread_attr_destroy(&attr) && !rc) rc = EINVAL;
  if (rc) goto failed;

  struct timespec limit;
  clock_gettime(CLOCK_MONOTONIC, &limit); limit.tv_sec += 30;
  pthread_mutex_lock(&bl_lock);
  while (!bl_ready && !bl_dead) {
#ifdef __APPLE__
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    struct timespec rel = {limit.tv_sec - now.tv_sec, limit.tv_nsec - now.tv_nsec};
    if (rel.tv_nsec < 0) { rel.tv_sec--; rel.tv_nsec += 1000000000L; }
    rc = rel.tv_sec < 0 ? ETIMEDOUT : pthread_cond_timedwait_relative_np(&bl_cv, &bl_lock, &rel);
#else
    rc = pthread_cond_timedwait(&bl_cv, &bl_lock, &limit);
#endif
    if (rc) break;
  }
  bool ok = bl_ready && !bl_dead && rc == 0;
  pthread_mutex_unlock(&bl_lock);
  if (!ok) goto failed;
  pthread_mutex_unlock(&bl_init_lock);
  return enif_make_atom(env, "ok");

failed:
  pthread_mutex_lock(&bl_lock); bl_dead = true; pthread_mutex_unlock(&bl_lock);
  if (!thread_started) {
    for (int i = 0; i < 2; i++) if (bl_pipe[i] >= 0) { close(bl_pipe[i]); bl_pipe[i] = -1; }
    if (bl_cv_ready) { pthread_cond_destroy(&bl_cv); bl_cv_ready = false; }
    if (bl_pin) { enif_release_resource(bl_pin); bl_pin = NULL; }
  }
  // Once any thread exists, retain the pin even if @on_load fails.
  pthread_mutex_unlock(&bl_init_lock);
  return bl_error(env, "init_failed");
}

static ERL_NIF_TERM bl_stage(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  BlCall* c; ErlNifBinary bin;
  if (!enif_get_resource(env, argv[0], bl_call_type, (void**)&c) ||
      !enif_inspect_binary(env, argv[1], &bin)) return enif_make_badarg(env);
  const char* invalid = NULL;
  if (bin.size < 4) invalid = "short request";
  else if (bl_rd32(bin.data) >= BENDLER_FN_COUNT) invalid = "unknown function index";
  else invalid = bl_validate(bl_rd32(bin.data), bin.data + 4, bin.data + bin.size);
  u8* copy = invalid ? NULL : malloc(bin.size + 1);
  if (copy) memcpy(copy, bin.data, bin.size);
  pthread_mutex_lock(&bl_lock);
  const char* error = bl_dead ? "dead" : c->cancelled ? "cancelled" :
    bl_expired(c) ? "timeout" : (!invalid && !copy) ? "nomem" : NULL;
  if (invalid || error) {
    c->state = BL_FINISHED; bl_waiting--;
    pthread_mutex_unlock(&bl_lock);
    free(copy); bl_clear(c);
    return error ? bl_error(env, error) : bl_invalid(env, invalid);
  }
  c->req = copy; c->len = bin.size; c->state = BL_QUEUED;
  enif_keep_resource(c); // native hold: now independent of caller/GC
  if (bl_tail) bl_tail->next = c; else bl_head = c;
  bl_tail = c;
  u8 byte = 1;
  ssize_t written;
  do { written = write(bl_pipe[1], &byte, 1); } while (written < 0 && errno == EINTR);
  // EAGAIN means a wake-up is already pending. The pipe stays open for VM life.
  pthread_mutex_unlock(&bl_lock);
  return enif_make_tuple2(env, enif_make_atom(env, "ok"), argv[0]);
}

static ERL_NIF_TERM bl_submit(ErlNifEnv* env, const ERL_NIF_TERM argv[], bool events) {
  ErlNifBinary bin; ErlNifSInt64 deadline = INT64_MAX;
  if (!enif_inspect_binary(env, argv[0], &bin) || !enif_is_ref(env, argv[2])) return enif_make_badarg(env);
  if (!enif_is_identical(argv[1], enif_make_atom(env, "infinity")) &&
      !enif_get_int64(env, argv[1], &deadline)) return enif_make_badarg(env);
  if (deadline != INT64_MAX) {
    int64_t beam_now = enif_monotonic_time(ERL_NIF_MSEC);
    if (deadline <= beam_now) return bl_error(env, "timeout");
    u64 remaining = (u64)deadline - (u64)beam_now;
    int64_t now = bl_now();
    deadline = remaining >= (u64)(INT64_MAX - now) ? INT64_MAX : now + (int64_t)remaining;
  }
  if (bin.size > BENDLER_MAX_FRAME) return bl_invalid(env, "request past BENDLER_MAX_FRAME");
  pthread_mutex_lock(&bl_lock);
  const char* error = bl_dead || !bl_ready ? "dead" :
    deadline != INT64_MAX && bl_now() >= deadline ? "timeout" :
    bl_waiting >= bl_max_waiting ? "busy" : NULL;
  if (!error) bl_waiting++;
  pthread_mutex_unlock(&bl_lock);
  if (error) return bl_error(env, error);

  BlCall* c = enif_alloc_resource(bl_call_type, sizeof *c);
  if (!c) {
    pthread_mutex_lock(&bl_lock); bl_waiting--; pthread_mutex_unlock(&bl_lock);
    return bl_error(env, "nomem");
  }
  memset(c, 0, sizeof *c); c->state = BL_RESERVED; c->deadline = deadline;
  c->events = events;
  c->env = enif_alloc_env();
  if (!c->env || !enif_self(env, &c->pid)) {
    enif_release_resource(c); return bl_error(env, "nomem");
  }
  c->ref = enif_make_copy(c->env, argv[2]);
  if (enif_monitor_process(env, c, &c->pid, &c->monitor)) {
    enif_release_resource(c); return bl_error(env, "cancelled");
  }
  c->monitored = true;
  ERL_NIF_TERM args[] = {enif_make_resource(env, c), argv[0]};
  // The scheduled term owns RESERVED. If the process dies before staging,
  // its destructor retires admission; there is no orphaned native reference.
  enif_release_resource(c);
  return enif_schedule_nif(env, "bendler_validate", ERL_NIF_DIRTY_JOB_CPU_BOUND, bl_stage, 2, args);
}
ERL_NIF_TERM bendler_nif_submit(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc; return bl_submit(env, argv, false);
}
ERL_NIF_TERM bendler_nif_subscribe(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc; return bl_submit(env, argv, true);
}
ERL_NIF_TERM bendler_nif_ack(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc; BlCall* c; ErlNifUInt64 seq;
  ErlNifPid pid;
  bool go = enif_is_identical(argv[2], enif_make_atom(env, "true"));
  if (!enif_get_resource(env, argv[0], bl_call_type, (void**)&c) ||
      !enif_get_uint64(env, argv[1], &seq) ||
      (!go && !enif_is_identical(argv[2], enif_make_atom(env, "false"))) ||
      !enif_self(env, &pid) || enif_compare_pids(&pid, &c->pid) != 0) return enif_make_badarg(env);
  pthread_mutex_lock(&bl_lock);
  if (!c->cancelled && c->state == BL_RUNNING && c->event_pending &&
      !c->ask_spec && !c->ack_ready && seq == c->event_seq) {
    c->ack_go = go; c->ack_ready = true;
    if (!go) c->events = false;
    bl_wake_locked();
  }
  pthread_mutex_unlock(&bl_lock);
  return enif_make_atom(env, "ok");
}
ERL_NIF_TERM bendler_nif_cancel(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc; BlCall* c;
  if (!enif_get_resource(env, argv[0], bl_call_type, (void**)&c)) return enif_make_badarg(env);
  bl_cancel(c);
  return enif_make_atom(env, "ok");
}
#endif
