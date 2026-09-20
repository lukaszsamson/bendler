// Bendler: the codec between the BEAM and a Bend program, shared by every transport.
// Spliced into the Bend runtime's C source, so every runtime symbol is in scope.
// bendler_specs.h (generated per module) declares the exports' type specs.
#ifndef BENDLER_COMMON_H
#define BENDLER_COMMON_H
#include "bendler_specs.h"

enum { BL_ERR = 0, BL_U32 = 1, BL_NAT = 2, BL_STR = 3, BL_BOOL = 4, BL_UNIT = 5, BL_LIST = 6, BL_BYTES = 7 };

#ifndef BENDLER_MAX_FRAME
#define BENDLER_MAX_FRAME (64u << 20)   // a request or reply body past this is refused
#endif
#ifndef BENDLER_MAX_ITEMS
#define BENDLER_MAX_ITEMS (16u << 20)   // list items (all lists together) one request may carry
#endif
#define BL_MAX_DEPTH 32                  // list nesting the spec grammar allows

typedef struct { u8* p; u64 len; u64 cap; } BlBuf;

// A program that never mentions List has no CID_CON: its codec refuses lists.
#ifndef CID_CON
#define CID_NIL 0
#define CID_CON 0
#define BL_NO_LIST 1
#endif

// bl_fail is a codec invariant violation after validation, i.e. a bendler
// bug: the transport decides (the port exits 65, the NIF freezes that
// runtime). Malformed input never reaches it: bl_validate runs first and
// answers an error frame without touching the runtime or the user's def.
static void bl_fail(const char* msg);
static const u8* bl_req;
static const u8* bl_end;

static void* bl_alloc(u64 n) {
  void* p = malloc(n ? n : 1);
  if (p == NULL) bl_fail("out of memory");
  return p;
}

static void bl_put(BlBuf* b, const void* src, u64 n) {
  if (b->len + n > BENDLER_MAX_FRAME) bl_fail("reply past BENDLER_MAX_FRAME");
  if (b->len + n > b->cap) {
    u64 cap = (b->cap ? b->cap * 2 : 256) + n;
    if (cap > BENDLER_MAX_FRAME + 64) cap = BENDLER_MAX_FRAME + 64;
    u8* p = realloc(b->p, cap);
    if (p == NULL) bl_fail("out of memory");
    b->p = p; b->cap = cap;
  }
  memcpy(b->p + b->len, src, n);
  b->len += n;
}
static void bl_put8(BlBuf* b, u8 v)   { bl_put(b, &v, 1); }
static void bl_put32(BlBuf* b, u32 v) { u8 t[4] = { v >> 24, v >> 16, v >> 8, v }; bl_put(b, t, 4); }
static void bl_put64(BlBuf* b, u64 v) { bl_put32(b, (u32)(v >> 32)); bl_put32(b, (u32)v); }
static u32  bl_rd32(const u8* p) { return ((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8) | p[3]; }
static u64  bl_rd64(const u8* p) { return ((u64)bl_rd32(p) << 32) | bl_rd32(p + 4); }

// The spec grammar is unary: one of u n s b t, or L followed by one type.
// bl_skip_type consumes exactly one type, bounded by the string's NUL.
static const char* bl_skip_type(const char* ty) {
  int depth = 0;
  for (;;) {
    char k = *ty;
    if (k == 'L') { if (++depth > BL_MAX_DEPTH) bl_fail("type spec nested too deep"); ty += 1; continue; }
    if (k == 'u' || k == 'n' || k == 's' || k == 'b' || k == 't' || k == 'y') return ty + 1;
    bl_fail("bad type spec");
  }
}

// Validation
// ==========
// Walks a request against the export's spec without allocating anything.
// Answers NULL when the request is exactly one well-formed value per
// parameter, else a message. This is the only gate malformed input meets.
typedef struct { const u8* p; const u8* end; u64 items; const char* err; } BlCheck;

static void bl_check(BlCheck* c, const char** ty, int depth) {
  if (c->err) return;
  char k = *(*ty)++;
  if (c->p >= c->end) { c->err = "truncated request"; return; }
  u8 tag = *c->p++;
  switch (k) {
    case 'u': if (tag != BL_U32 || c->end - c->p < 4) { c->err = "expected a U32"; return; } c->p += 4; return;
    case 'n':
      if (tag != BL_NAT || c->end - c->p < 8) { c->err = "expected a Nat"; return; }
      if (bl_rd64(c->p) > NAT_IMM) { c->err = "a Nat past 2^48-1"; return; }
      c->p += 8; return;
    case 's': {
      if (tag != BL_STR || c->end - c->p < 4) { c->err = "expected a String"; return; }
      u32 n = bl_rd32(c->p); c->p += 4;
      if ((u64)(c->end - c->p) < n) { c->err = "truncated String"; return; }
      c->p += n; return;
    }
    case 'b':
      if (tag != BL_BOOL || c->p >= c->end || *c->p > 1) { c->err = "expected a Bool"; return; }
      c->p += 1; return;
    case 't': if (tag != BL_UNIT) c->err = "expected a Unit"; return;
    case 'y': {
#ifndef BENDLER_CID_BYTES
      c->err = "this program has no Bytes type"; return;
#endif
      if (tag != BL_BYTES || c->end - c->p < 4) { c->err = "expected Bytes"; return; }
      u32 n = bl_rd32(c->p); c->p += 4;
      if ((u64)(c->end - c->p) < n) { c->err = "truncated Bytes"; return; }
      if (n > (1u << 30)) { c->err = "Bytes past 2^30"; return; }
      c->p += n; return;
    }
    case 'L': {
#ifdef BL_NO_LIST
      c->err = "this program has no List type"; return;
#endif
      if (depth >= BL_MAX_DEPTH) { c->err = "list nested too deep"; return; }
      if (tag != BL_LIST || c->end - c->p < 4) { c->err = "expected a List"; return; }
      u32 n = bl_rd32(c->p); c->p += 4;
      if ((u64)n > (u64)(c->end - c->p)) { c->err = "list count past the request"; return; }
      c->items += n;
      if (c->items > BENDLER_MAX_ITEMS) { c->err = "too many list items"; return; }
      const char* elem = *ty;
      for (u32 i = 0; i < n && !c->err; i += 1) { const char* t2 = elem; bl_check(c, &t2, depth + 1); }
      *ty = bl_skip_type(elem);
      return;
    }
    default: c->err = "bad type spec"; return;
  }
}

// The request body after the function index. fn must already be in range.
static const char* bl_validate(u32 fn, const u8* p, const u8* end) {
  BlCheck c = { p, end, 0, NULL };
  const char* ty = BENDLER_ARG_SPECS[fn];
  while (*ty && !c.err) bl_check(&c, &ty, 0);
  if (c.err) return c.err;
  if (c.p != end) return "trailing bytes in the request";
  return NULL;
}

// Bytes: Bytes{len, buf} with buf a BUF block of one u32 slot per byte,
// 2^c slots for the smallest c with 2^c >= len (the rest zero); the same
// layout `[0 : U32*n]` and Array.set build in Bend.
#ifdef BENDLER_CID_BYTES
static Term bl_bytes(Env e, const u8* p, u32 n) {
  u32 c = 0;
  while ((1ull << c) < n) c += 1;
  Loc l = heap_alloc(e, buf_wcls(c));
  if (err_seen(e.mem)) bl_fail("bytes allocation failed");
  for (u64 i = 0; i < (1ull << c); i += 1) blk_write(e.mem, false, l, (u32)i, i < n ? p[i] : 0);
  return io_node(e, BENDLER_CID_BYTES, (Term)n, term_blk(false, c, l));
}

static void bl_bytes_out(Env e, Term x, BlBuf* b) {
  Term fb[2];
  spare_free(e, cls_fit(2), ctr_take(e, x, 2, fb));
  u32  n   = (u32)fb[0];
  Term blk = fb[1];
  u64  cap = 1ull << blk_cls(blk);
  if (n > cap) bl_fail("Bytes len past its buffer");
  bl_put8(b, BL_BYTES); bl_put32(b, n);
  u8 chunk[256];
  for (u64 i = 0; i < n; i += 256) {
    u64 m = n - i < 256 ? n - i : 256;
    for (u64 j = 0; j < m; j += 1) chunk[j] = (u8)blk_read(e.mem, false, term_loc(blk), (u32)(i + j));
    bl_put(b, chunk, m);
  }
  blk_free(e, blk);
}
#endif

// Decoding (only ever after bl_validate)
// ======================================
static Term bl_decode(Env e, const char** ty, int depth) {
  char c = *(*ty)++;
  if (bl_req >= bl_end) bl_fail("decode past the request");
  u8 tag = *bl_req++;
  Term t;
  switch (c) {
    case 'u': t = (Term)bl_rd32(bl_req); bl_req += 4; break;
    case 'n': t = (Term)bl_rd64(bl_req); bl_req += 8; break;
    case 's': { u32 n = bl_rd32(bl_req); bl_req += 4; t = io_str(e, (const char*)bl_req, n); bl_req += n; break; }
    case 'b': t = term_pak(*bl_req++ ? CID_TRUE : CID_FALSE, 0); break;
    case 't': t = term_pak(CID_UNIT, 0); break;
    case 'y': {
#ifdef BENDLER_CID_BYTES
      u32 n = bl_rd32(bl_req); bl_req += 4;
      t = bl_bytes(e, bl_req, n); bl_req += n;
#else
      bl_fail("no Bytes type"); t = 0;
#endif
      break;
    }
    case 'L': {
      u32 n = bl_rd32(bl_req); bl_req += 4;
      const char* elem = *ty;
      Term* items = bl_alloc(sizeof(Term) * n);
      for (u32 i = 0; i < n; i += 1) { const char* t2 = elem; items[i] = bl_decode(e, &t2, depth + 1); }
      *ty = bl_skip_type(elem);
      t = term_pak(CID_NIL, 0);
      for (u32 i = n; i > 0; i -= 1) t = io_node(e, CID_CON, items[i - 1], t);
      free(items); break;
    }
    default: bl_fail("bad type spec"); t = 0;
  }
  (void)tag;
  return t;
}

// Encoding: writes the Term x, of the type spelled at *ty, consuming it.
static void bl_encode(Env e, const char** ty, Term x, BlBuf* b, int depth) {
  char c = *(*ty)++;
  switch (c) {
    case 'u': bl_put8(b, BL_U32); bl_put32(b, (u32)x); break;
    case 'n': bl_put8(b, BL_NAT); bl_put64(b, (u64)x); break;
    case 'b': bl_put8(b, BL_BOOL); bl_put8(b, term_aux(x) == CID_TRUE); break;
    case 't': bl_put8(b, BL_UNIT); break;
    case 'y':
#ifdef BENDLER_CID_BYTES
      bl_bytes_out(e, x, b);
#else
      bl_fail("no Bytes type");
#endif
      break;
    case 's': {
      u64 n = 0; char* s = io_cstr(e, x, &n);
      if (n > BENDLER_MAX_FRAME) { free(s); bl_fail("reply String past BENDLER_MAX_FRAME"); }
      bl_put8(b, BL_STR); bl_put32(b, (u32)n); bl_put(b, s, n); free(s); break;
    }
    case 'L': {
#ifdef BL_NO_LIST
      bl_fail("this program has no List type");
#endif
      if (depth >= BL_MAX_DEPTH) bl_fail("list nested too deep");
      const char* elem = *ty;
      bl_put8(b, BL_LIST);
      u64 at = b->len; bl_put32(b, 0);
      u32 n = 0;
      while (term_aux(x) == CID_CON) {
        Term fb[2];
        spare_free(e, cls_fit(2), ctr_take(e, x, 2, fb));
        const char* t2 = elem;
        bl_encode(e, &t2, fb[0], b, depth + 1);
        x = fb[1]; n += 1;
      }
      *ty = bl_skip_type(elem);
      u8 cnt[4] = { n >> 24, n >> 16, n >> 8, n }; memcpy(b->p + at, cnt, 4);
      break;
    }
    default: bl_fail("bad return type spec");
  }
}

static void bl_put_err(BlBuf* b, const char* msg) {
  bl_put8(b, BL_ERR); bl_put32(b, (u32)strlen(msg)); bl_put(b, msg, strlen(msg));
}

// A spec String argument as a C string (freed by the caller).
static char* bl_spec(Env e, Term s) { u64 n = 0; return io_cstr(e, s, &n); }
#endif
