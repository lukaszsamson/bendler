// Bendler: the codec between the BEAM and a Bend program, shared by every transport.
// Spliced into the Bend runtime's C source, so every runtime symbol is in scope.
// bendler_specs.h (generated per module) declares the exports' type specs.
#ifndef BENDLER_COMMON_H
#define BENDLER_COMMON_H
#include "bendler_specs.h"

enum { BL_ERR = 0, BL_U32 = 1, BL_NAT = 2, BL_STR = 3, BL_BOOL = 4, BL_UNIT = 5, BL_LIST = 6, BL_BYTES = 7,
       BL_TUPLE = 8, BL_NONE = 9, BL_SOME = 10, BL_OK = 11, BL_FAIL = 12, BL_F32 = 13, BL_CHR = 14,
       BL_DATA = 15 };

// A Char is a code point: below 0x110000 and not a surrogate.
static bool bl_is_char(u32 c) { return c < 0x110000 && (c < 0xD800 || c > 0xDFFF); }

#ifndef BENDLER_MAX_FRAME
#define BENDLER_MAX_FRAME (64u << 20)   // a request or reply body past this is refused
#endif
#ifndef BENDLER_MAX_ITEMS
#define BENDLER_MAX_ITEMS (16u << 20)   // list items (all lists together) one request may carry
#endif
#ifndef BENDLER_MAX_DECODED
#define BENDLER_MAX_DECODED (64u << 20) // allocations made while decoding one request
#endif
#define BL_MAX_DEPTH 2048                // value nesting limit (a recursive datatype nests per level)
#define BL_MAX_SPEC_DEPTH 32             // type spec nesting limit (a D<index>: does not expand)

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

// Prefix grammar: primitives, L/M + one type, R + error/value types,
// T<arity>: + 2..16 field types. Never scan past a NUL or an unbounded depth.
// a number in the spec, `digits:`, within lo..hi (the specs are generated: a bad one is a bendler bug)
static int bl_num(const char** ty, int lo, int hi) {
  int n = 0, digits = 0;
  while (**ty >= '0' && **ty <= '9' && digits < 4) {
    n = n * 10 + *(*ty)++ - '0'; digits += 1;
  }
  if (**ty != ':' || digits == 0 || n < lo || n > hi) bl_fail("bad number in a type spec");
  *ty += 1;
  return n;
}
static int bl_tuple_arity(const char** ty) { return bl_num(ty, 2, 16); }
static const char* bl_skip_at(const char* ty, int depth) {
  if (depth > BL_MAX_SPEC_DEPTH) bl_fail("type spec nested too deep");
  char k = *ty;
  if (k == 0) bl_fail("truncated type spec");
  ty += 1;
  if (k == 'u' || k == 'n' || k == 's' || k == 'b' || k == 't' || k == 'y' || k == 'f' || k == 'c') return ty;
  if (k == 'D') { bl_num(&ty, 0, 9999); return ty; }
  int n = k == 'L' || k == 'M' ? 1 : k == 'R' ? 2 : k == 'T' ? bl_tuple_arity(&ty) : 0;
  if (n == 0) bl_fail("bad type spec");
  for (int i = 0; i < n; i += 1) ty = bl_skip_at(ty, depth + 1);
  return ty;
}

static const char* bl_skip_type(const char* ty) { return bl_skip_at(ty, 0); }

// The field specs of constructor `ctor` of user datatype `idx`, and how
// many; NULL when the type has no such constructor.
static const char* bl_ctor_fields(int idx, int ctor, int* nfields) {
  const char* ts = BENDLER_TYPE_SPECS[idx];
  int nctors = bl_num(&ts, 1, 255);
  if (ctor >= nctors) return NULL;
  for (int c = 0; c < ctor; c += 1) {
    int k = bl_num(&ts, 0, 255);
    for (int i = 0; i < k; i += 1) ts = bl_skip_type(ts);
  }
  *nfields = bl_num(&ts, 0, 255);
  return ts;
}

// Validation
// ==========
// Walks a request against the export's spec without allocating anything.
// Answers NULL when the request is exactly one well-formed value per
// parameter, else a message. This is the only gate malformed input meets.
typedef struct { const u8* p; const u8* end; u64 items; u64 decoded; const char* err; } BlCheck;

static void bl_charge(BlCheck* c, u64 n) {
  if (c->err) return;
  if (n > BENDLER_MAX_DECODED - c->decoded) { c->err = "decoded memory budget exceeded"; return; }
  c->decoded += n;
}

// Bytes use a power-of-two u32 buffer plus the two-word Bytes/DB node.
// Zero bytes still allocate the runtime's smallest one-word block.
static void bl_charge_bytes(BlCheck* c, u32 n) {
  u64 slots = 1;
  while (slots < n) slots <<= 1;
  u64 buffer = slots * 4;
  bl_charge(c, 16 + (buffer < 8 ? 8 : buffer));
}

static bool bl_spec_has_dyn(const char* p, const char* end) {
  while (p < end) if (*p++ == 'D') return true;
  return false;
}

static void bl_check(BlCheck* c, const char** ty, int depth, bool dyn) {
  if (c->err) return;
  if (depth > BL_MAX_DEPTH) { c->err = "value nested too deep"; return; }
  char k = *(*ty)++;
  if (c->p >= c->end) { c->err = "truncated request"; return; }
  u8 tag = *c->p++;
  switch (k) {
    case 'T': {
      int n = bl_tuple_arity(ty);
      if (tag != BL_TUPLE || c->p >= c->end || *c->p++ != n) { c->err = "expected a Tuple"; return; }
      c->items += n;
      if (c->items > BENDLER_MAX_ITEMS) { c->err = "too many items"; return; }
      bl_charge(c, dyn ? 8 + (u64)n * 16 : (u64)(n - 1) * 16);
      for (int i = 0; i < n && !c->err; i += 1) bl_check(c, ty, depth + 1, dyn);
      return;
    }
    case 'D': {
      int idx = bl_num(ty, 0, BENDLER_TYPE_COUNT - 1);
      if (tag != BL_DATA || c->end - c->p < 2) { c->err = "expected a datatype value"; return; }
      u8 ctor = c->p[0], n = c->p[1]; c->p += 2;
      int k = 0;
      const char* fs = bl_ctor_fields(idx, ctor, &k);
      if (fs == NULL) { c->err = "no such constructor"; return; }
      if (k != n) { c->err = "wrong field count for the constructor"; return; }
      c->items += k;
      if (c->items > BENDLER_MAX_ITEMS) { c->err = "too many items"; return; }
      // Dyn.DK is two words; its fields are a runtime list and a temporary Term array.
      bl_charge(c, 16 + (u64)k * 24);
      for (int i = 0; i < k && !c->err; i += 1) bl_check(c, &fs, depth + 1, true);
      return;
    }
    case 'M': {
      const char* end = bl_skip_type(*ty);
      bl_charge(c, dyn ? 8 + (tag == BL_SOME ? 16 : 0) : (tag == BL_SOME ? 8 : 0));
      if (tag == BL_SOME) bl_check(c, ty, depth + 1, dyn);
      else if (tag != BL_NONE) c->err = "expected a Maybe";
      *ty = end; return;
    }
    case 'R': {
      const char* value = bl_skip_type(*ty);
      const char* end = bl_skip_type(value);
      bl_charge(c, dyn ? 32 : 8);
      if (tag == BL_OK) { *ty = value; bl_check(c, ty, depth + 1, dyn); }
      else if (tag == BL_FAIL) bl_check(c, ty, depth + 1, dyn);
      else c->err = "expected a Result";
      *ty = end; return;
    }
    case 'u': if (tag != BL_U32 || c->end - c->p < 4) { c->err = "expected a U32"; return; } c->p += 4; return;
    case 'f': if (tag != BL_F32 || c->end - c->p < 4) { c->err = "expected an F32"; return; } c->p += 4; return;
    case 'c':
      if (tag != BL_CHR || c->end - c->p < 4 || !bl_is_char(bl_rd32(c->p))) { c->err = "expected a Char"; return; }
      c->p += 4; return;
    case 'n':
      if (tag != BL_NAT || c->end - c->p < 8) { c->err = "expected a Nat"; return; }
      if (bl_rd64(c->p) > NAT_IMM) { c->err = "a Nat past 2^48-1"; return; }
      if (dyn) bl_charge(c, 8); // Dyn.DN box
      c->p += 8; return;
    case 's': {
      if (tag != BL_STR || c->end - c->p < 4) { c->err = "expected a String"; return; }
      u32 n = bl_rd32(c->p); c->p += 4;
      if ((u64)(c->end - c->p) < n) { c->err = "truncated String"; return; }
      // io_str allocates one two-word cons per decoded code point. Invalid UTF-8
      // can produce one replacement code point per byte, so bytes is the safe bound.
      bl_charge(c, (u64)n * 16 + (dyn ? 8 : 0));
      c->p += n; return;
    }
    case 'b':
      if (tag != BL_BOOL || c->p >= c->end || *c->p > 1) { c->err = "expected a Bool"; return; }
      c->p += 1; return;
    case 't': if (tag != BL_UNIT) c->err = "expected a Unit"; return;
    case 'y': {
// A datatype field uses Dyn.DB, even when no export uses canonical Bytes.
#if !defined(BENDLER_CID_BYTES) && !defined(BENDLER_CID_DB)
      c->err = "this program has no Bytes type"; return;
#endif
      if (tag != BL_BYTES || c->end - c->p < 4) { c->err = "expected Bytes"; return; }
      u32 n = bl_rd32(c->p); c->p += 4;
      if ((u64)(c->end - c->p) < n) { c->err = "truncated Bytes"; return; }
      if (n > (1u << 30)) { c->err = "Bytes past 2^30"; return; }
      bl_charge_bytes(c, n);
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
      // Both decoders hold an 8-byte Term array while building 16-byte cons
      // cells. Dyn additionally boxes the completed list in DL.
      bl_charge(c, (u64)n * 24 + (dyn ? 8 : 0));
      const char* elem = *ty;
      for (u32 i = 0; i < n && !c->err; i += 1) { const char* t2 = elem; bl_check(c, &t2, depth + 1, dyn); }
      *ty = bl_skip_type(elem);
      return;
    }
    default: c->err = "bad type spec"; return;
  }
}

// The request body after the function index. fn must already be in range.
static const char* bl_validate(u32 fn, const u8* p, const u8* end) {
  BlCheck c = { p, end, 0, 0, NULL };
  const char* ty = BENDLER_ARG_SPECS[fn];
  while (*ty && !c.err) {
    const char* type_end = bl_skip_type(ty);
    bool dyn = bl_spec_has_dyn(ty, type_end);
    bl_check(&c, &ty, 0, dyn);
  }
  if (c.err) return c.err;
  if (c.p != end) return "trailing bytes in the request";
  return NULL;
}

// Bytes: Bytes{len, buf} with buf a BUF block of one u32 slot per byte,
// 2^c slots for the smallest c with 2^c >= len (the rest zero); the same
// layout `[0 : U32*n]` and Array.set build in Bend.
// a {len, buf} node of constructor `cid` (the prelude's Bytes, or its Dyn DB)
static Term bl_bytes_as(Env e, u64 cid, const u8* p, u32 n) {
  u32 c = 0;
  while ((1ull << c) < n) c += 1;
  Loc l = heap_alloc(e, buf_wcls(c));
  if (err_seen(e.mem)) bl_fail("bytes allocation failed");
  for (u64 i = 0; i < (1ull << c); i += 1) blk_write(e.mem, false, l, (u32)i, i < n ? p[i] : 0);
  return io_node(e, cid, (Term)n, term_blk(false, c, l));
}
static void bl_blk_out(Env e, u32 n, Term blk, BlBuf* b) {
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
#ifdef BENDLER_CID_BYTES
static Term bl_bytes(Env e, const u8* p, u32 n) { return bl_bytes_as(e, BENDLER_CID_BYTES, p, n); }
static void bl_bytes_out(Env e, Term x, BlBuf* b) {
  Term fb[2];
  spare_free(e, cls_fit(2), ctr_take(e, x, 2, fb));
  bl_blk_out(e, (u32)fb[0], fb[1], b);
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
    case 'T': {
      int n = bl_tuple_arity(ty); bl_req += 1; // validated wire arity
      Term fields[16];
      for (int i = 0; i < n; i += 1) fields[i] = bl_decode(e, ty, depth + 1);
      t = fields[n - 1];
      for (int i = n - 2; i >= 0; i -= 1) t = io_node(e, CID_TUPLE, fields[i], t);
      break;
    }
    case 'M': {
      const char* end = bl_skip_type(*ty);
      t = tag == BL_NONE ? term_pak(CID_NONE, 0) : io_box(e, CID_SOME, bl_decode(e, ty, depth + 1));
      *ty = end; break;
    }
    case 'R': {
      const char* value = bl_skip_type(*ty);
      const char* end = bl_skip_type(value);
      if (tag == BL_OK) *ty = value;
      t = io_box(e, tag == BL_OK ? CID_DONE : CID_FAIL, bl_decode(e, ty, depth + 1));
      *ty = end; break;
    }
    case 'u': case 'f': case 'c': t = (Term)bl_rd32(bl_req); bl_req += 4; break; // F32 bits and Char are bare words
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
  if (depth > BL_MAX_DEPTH) bl_fail("reply nested too deep");
  char c = *(*ty)++;
  switch (c) {
    case 'T': {
      int n = bl_tuple_arity(ty);
      bl_put8(b, BL_TUPLE); bl_put8(b, (u8)n);
      for (int i = 0; i < n - 1; i += 1) {
        Term fields[2];
        spare_free(e, cls_fit(2), ctr_take(e, x, 2, fields));
        bl_encode(e, ty, fields[0], b, depth + 1); x = fields[1];
      }
      bl_encode(e, ty, x, b, depth + 1); break;
    }
    case 'M': {
      const char* end = bl_skip_type(*ty);
      if (term_aux(x) == CID_NONE) bl_put8(b, BL_NONE);
      else if (term_aux(x) == CID_SOME) {
        Term fields[1]; spare_free(e, cls_fit(1), ctr_take(e, x, 1, fields));
        bl_put8(b, BL_SOME); bl_encode(e, ty, fields[0], b, depth + 1);
      } else bl_fail("bad Maybe constructor");
      *ty = end; break;
    }
    case 'R': {
      const char* value = bl_skip_type(*ty);
      const char* end = bl_skip_type(value);
      bool ok = term_aux(x) == CID_DONE;
      if (!ok && term_aux(x) != CID_FAIL) bl_fail("bad Result constructor");
      if (ok) *ty = value;
      Term fields[1]; spare_free(e, cls_fit(1), ctr_take(e, x, 1, fields));
      bl_put8(b, ok ? BL_OK : BL_FAIL); bl_encode(e, ty, fields[0], b, depth + 1);
      *ty = end; break;
    }
    case 'u': bl_put8(b, BL_U32); bl_put32(b, (u32)x); break;
    case 'f': bl_put8(b, BL_F32); bl_put32(b, (u32)x); break;
    case 'c': bl_put8(b, BL_CHR); bl_put32(b, (u32)x); break; // the host checks the range
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

// Dyn: a value whose type mentions a user datatype crosses as the
// prelude's Dyn tree (see the Bend prelude), which the shim's generated
// defs convert. The host builds leaves and DL/DK nodes only; it never lays
// out a user constructor.
// =====================================================================
static bool bl_has_dyn(const char* spec) { return strchr(spec, 'D') != NULL; }

#ifdef BENDLER_CID_DK
static Term bl_dyn_list(Env e, const Term* items, u32 n) {
  Term t = term_pak(CID_NIL, 0);
  for (u32 i = n; i > 0; i -= 1) t = io_node(e, CID_CON, items[i - 1], t);
  return t;
}

// reads a Dyn of the type spelled at *ty from the request (validated)
static Term bl_dyn_decode(Env e, const char** ty, int depth) {
  if (depth > BL_MAX_DEPTH) bl_fail("value nested too deep");
  char c = *(*ty)++;
  u8 tag = *bl_req++;
  Term t = 0;
  switch (c) {
    case 'u': case 'c': t = term_pak(BENDLER_CID_DU, bl_rd32(bl_req)); bl_req += 4; break;
    case 'f': t = term_pak(BENDLER_CID_DF, bl_rd32(bl_req)); bl_req += 4; break;
    case 'b': t = term_pak(BENDLER_CID_DU, *bl_req++); break;
    case 't': t = term_pak(BENDLER_CID_DU, 0); break;
    case 'n': t = io_box(e, BENDLER_CID_DN, (Term)bl_rd64(bl_req)); bl_req += 8; break;
    case 's': {
      u32 n = bl_rd32(bl_req); bl_req += 4;
      t = io_box(e, BENDLER_CID_DS, io_str(e, (const char*)bl_req, n)); bl_req += n; break;
    }
    case 'y': { u32 n = bl_rd32(bl_req); bl_req += 4; t = bl_bytes_as(e, BENDLER_CID_DB, bl_req, n); bl_req += n; break; }
    case 'L': {
      u32 n = bl_rd32(bl_req); bl_req += 4;
      const char* elem = *ty;
      Term* items = bl_alloc(sizeof(Term) * (n ? n : 1));
      for (u32 i = 0; i < n; i += 1) { const char* t2 = elem; items[i] = bl_dyn_decode(e, &t2, depth + 1); }
      *ty = bl_skip_type(elem);
      t = io_box(e, BENDLER_CID_DL, bl_dyn_list(e, items, n));
      free(items); break;
    }
    case 'T': {
      int n = bl_tuple_arity(ty); bl_req += 1; // validated wire arity
      Term items[16];
      for (int i = 0; i < n; i += 1) items[i] = bl_dyn_decode(e, ty, depth + 1);
      t = io_box(e, BENDLER_CID_DL, bl_dyn_list(e, items, (u32)n)); break;
    }
    case 'M': {
      const char* end = bl_skip_type(*ty);
      Term item = 0; u32 n = 0;
      if (tag == BL_SOME) { item = bl_dyn_decode(e, ty, depth + 1); n = 1; }
      *ty = end;
      t = io_box(e, BENDLER_CID_DL, bl_dyn_list(e, &item, n)); break;
    }
    case 'R': {
      const char* value = bl_skip_type(*ty);
      const char* end = bl_skip_type(value);
      if (tag == BL_OK) *ty = value;
      Term item = bl_dyn_decode(e, ty, depth + 1);
      *ty = end;
      t = io_node(e, BENDLER_CID_DK, (Term)(tag == BL_OK ? 1 : 0), bl_dyn_list(e, &item, 1)); break;
    }
    case 'D': {
      int idx = bl_num(ty, 0, BENDLER_TYPE_COUNT - 1);
      u8 ctor = bl_req[0], n = bl_req[1]; bl_req += 2; // validated
      int k = 0;
      const char* fs = bl_ctor_fields(idx, ctor, &k);
      if (fs == NULL || k != n) bl_fail("constructor mismatch after validation");
      Term* items = bl_alloc(sizeof(Term) * (n ? n : 1));
      for (int i = 0; i < k; i += 1) items[i] = bl_dyn_decode(e, &fs, depth + 1);
      t = io_node(e, BENDLER_CID_DK, (Term)ctor, bl_dyn_list(e, items, (u32)k));
      free(items); break;
    }
    default: bl_fail("bad type spec");
  }
  (void)tag;
  return t;
}

// the fields of a Dyn node of constructor `cid`, or a bendler bug
static void bl_dyn_take(Env e, Term x, u64 cid, u32 n, Term* out) {
  if (term_aux(x) != cid) bl_fail("a Dyn of the wrong shape came back from the converter");
  spare_free(e, cls_fit(n), ctr_take(e, x, n, out));
}
static u32 bl_dyn_word(Term x, u64 cid) {
  if (term_aux(x) != cid) bl_fail("a Dyn of the wrong shape came back from the converter");
  return (u32)term_loc(x);
}
// the next cell of a Dyn list: its head, advancing `*l`
static Term bl_dyn_next(Env e, Term* l) {
  if (term_aux(*l) != CID_CON) bl_fail("a Dyn list shorter than its type");
  Term fb[2];
  spare_free(e, cls_fit(2), ctr_take(e, *l, 2, fb));
  *l = fb[1];
  return fb[0];
}

// writes the Dyn x, of the type spelled at *ty, consuming it
static void bl_dyn_encode(Env e, const char** ty, Term x, BlBuf* b, int depth) {
  if (depth > BL_MAX_DEPTH) bl_fail("reply nested too deep");
  char c = *(*ty)++;
  switch (c) {
    case 'u': bl_put8(b, BL_U32); bl_put32(b, bl_dyn_word(x, BENDLER_CID_DU)); break;
    case 'c': bl_put8(b, BL_CHR); bl_put32(b, bl_dyn_word(x, BENDLER_CID_DU)); break;
    case 'b': bl_put8(b, BL_BOOL); bl_put8(b, bl_dyn_word(x, BENDLER_CID_DU) != 0); break;
    case 't': bl_put8(b, BL_UNIT); break;
    case 'f': bl_put8(b, BL_F32); bl_put32(b, bl_dyn_word(x, BENDLER_CID_DF)); break;
    case 'n': { Term f[1]; bl_dyn_take(e, x, BENDLER_CID_DN, 1, f); bl_put8(b, BL_NAT); bl_put64(b, (u64)f[0]); break; }
    case 's': {
      Term f[1]; bl_dyn_take(e, x, BENDLER_CID_DS, 1, f);
      u64 n = 0; char* s = io_cstr(e, f[0], &n);
      if (n > BENDLER_MAX_FRAME) { free(s); bl_fail("reply String past BENDLER_MAX_FRAME"); }
      bl_put8(b, BL_STR); bl_put32(b, (u32)n); bl_put(b, s, n); free(s); break;
    }
    case 'y': { Term f[2]; bl_dyn_take(e, x, BENDLER_CID_DB, 2, f); bl_blk_out(e, (u32)f[0], f[1], b); break; }
    case 'L': {
      const char* elem = *ty;
      Term f[1]; bl_dyn_take(e, x, BENDLER_CID_DL, 1, f);
      bl_put8(b, BL_LIST);
      u64 at = b->len; bl_put32(b, 0);
      u32 n = 0; Term l = f[0];
      while (term_aux(l) == CID_CON) {
        const char* t2 = elem;
        bl_dyn_encode(e, &t2, bl_dyn_next(e, &l), b, depth + 1);
        n += 1;
      }
      *ty = bl_skip_type(elem);
      u8 cnt[4] = { n >> 24, n >> 16, n >> 8, n }; memcpy(b->p + at, cnt, 4);
      break;
    }
    case 'T': {
      int n = bl_tuple_arity(ty);
      Term f[1]; bl_dyn_take(e, x, BENDLER_CID_DL, 1, f);
      bl_put8(b, BL_TUPLE); bl_put8(b, (u8)n);
      Term l = f[0];
      for (int i = 0; i < n; i += 1) bl_dyn_encode(e, ty, bl_dyn_next(e, &l), b, depth + 1);
      break;
    }
    case 'M': {
      const char* end = bl_skip_type(*ty);
      Term f[1]; bl_dyn_take(e, x, BENDLER_CID_DL, 1, f);
      Term l = f[0];
      if (term_aux(l) == CID_CON) { bl_put8(b, BL_SOME); bl_dyn_encode(e, ty, bl_dyn_next(e, &l), b, depth + 1); }
      else bl_put8(b, BL_NONE);
      *ty = end; break;
    }
    case 'R': {
      const char* value = bl_skip_type(*ty);
      const char* end = bl_skip_type(value);
      Term f[2]; bl_dyn_take(e, x, BENDLER_CID_DK, 2, f);
      bool ok = (u32)f[0] != 0;
      Term l = f[1];
      if (ok) *ty = value;
      bl_put8(b, ok ? BL_OK : BL_FAIL);
      bl_dyn_encode(e, ty, bl_dyn_next(e, &l), b, depth + 1);
      *ty = end; break;
    }
    case 'D': {
      int idx = bl_num(ty, 0, BENDLER_TYPE_COUNT - 1);
      Term f[2]; bl_dyn_take(e, x, BENDLER_CID_DK, 2, f);
      u32 ctor = (u32)f[0];
      int k = 0;
      const char* fs = bl_ctor_fields(idx, (int)ctor, &k);
      if (fs == NULL) bl_fail("a constructor index outside its type came back");
      bl_put8(b, BL_DATA); bl_put8(b, (u8)ctor); bl_put8(b, (u8)k);
      Term l = f[1];
      for (int i = 0; i < k; i += 1) bl_dyn_encode(e, &fs, bl_dyn_next(e, &l), b, depth + 1);
      break;
    }
    default: bl_fail("bad return type spec");
  }
}
#else
static Term bl_dyn_decode(Env e, const char** ty, int depth) { (void)e; (void)ty; (void)depth; bl_fail("this program has no datatypes"); return 0; }
static void bl_dyn_encode(Env e, const char** ty, Term x, BlBuf* b, int depth) { (void)e; (void)ty; (void)x; (void)b; (void)depth; bl_fail("this program has no datatypes"); }
#endif

// one argument or result of the spec: canonical Base terms, or a Dyn when
// the spec mentions a datatype
static Term bl_decode_spec(Env e, const char* spec) {
  const char* ty = spec;
  return bl_has_dyn(spec) ? bl_dyn_decode(e, &ty, 0) : bl_decode(e, &ty, 0);
}
static void bl_encode_spec(Env e, const char* spec, Term x, BlBuf* b) {
  const char* ty = spec;
  if (bl_has_dyn(spec)) bl_dyn_encode(e, &ty, x, b, 0); else bl_encode(e, &ty, x, b, 0);
}
#endif
