import Base
import ./bendler.bend as B

# ThumbHash encoding (Evan Wallace's algorithm), ported from
# `Hentioe/thumbhash-ex`: an RGBA image of at most 100x100 pixels
# becomes a 5..25-byte hash. Floats stay inside Bend as F32; the
# reference computes in Elixir doubles, so a coefficient on a
# quantisation boundary may round differently (see the tests).
#
# Bytes cross as `List<U32>` (each 0..255), the interim convention
# until the codec grows a first-class binary; the result is the hash
# bytes the same way. `w * h * 4` bytes in, `5 + ceil(ac / 2)` out.

# a pixel: alpha in 0..1 and the colour channels scaled by alpha/255;
# after compositing, the same shape holds (l, p, q, a)
type Px is Data:
  Px{a: F32, r: F32, g: F32, b: F32}

# a coefficient position
type Pos is Data:
  Pos{cx: Nat, cy: Nat}

# an encoded channel: dc, the normalised ac list, the scale
type Ch is Data:
  Ch{dc: F32, ac: List<&2, F32>, scale: F32}

# Floats and rounding
# -------------------

def th_f(+n: U32) -> F32:
  U32.to_f32(n)

# round half up on a non-negative value: the reference's round/1
# only ever sees non-negative arguments here
def th_round(x: F32) -> U32:
  F32.to_u32(F32.floor((x + 0.5 : F32)))

def th_nat_f(n: Nat) -> F32:
  U32.to_f32(U32.from_nat(n))

# Lists
# -----

# rows of w from a flat list, one pass: cur collects a row (reversed),
# acc the rows (reversed); both are put right at the end
# a partial last row is dropped (the input is exactly w * h values)
def th_rows_put(cur: List<&2, F32>, acc: List<&2, List<&2, F32>>) -> List<&2, List<&2, F32>>:
  List.reverse(&2, List<&2, F32>, acc)

# after a step, the row either closes (i reached w) or grows
def th_rows_next(full: Bool, i: Nat, cur: List<&2, F32>, acc: List<&2, List<&2, F32>>) ->
  Nat & List<&2, F32> & List<&2, List<&2, F32>>:
  match full:
    case True{}:
      (0n, Nil{}, List.reverse(&2, F32, cur) <> acc)
    case False{}:
      (i, cur, acc)

def th_rows_go(xs: List<F32>, +w: Nat, st: Nat & List<&2, F32> & List<&2, List<&2, F32>>) ->
  List<&2, List<&2, F32>>:
  match xs:
    case Nil{}:
      (_, cur, acc) = st
      th_rows_put(cur, acc)
    case Con{+x, t}:
      (+i, cur, acc) = st
      th_rows_go(t, w, th_rows_next(Nat.is_eq(1n+i, w), 1n+i, x <> cur, acc))

def th_rows(xs: List<F32>, +w: Nat) -> List<&2, List<&2, F32>>:
  th_rows_go(xs, w, (0n, Nil{}, Nil{}))

# an affine list of Data becomes a reusable one by rebuilding it
def th_share(xs: List<F32>) -> List<&2, F32>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+h, t}:
      h <> th_share(t)

def th_sum_max(xs: List<&2, F32>, m: F32) -> F32:
  match xs:
    case Nil{}:
      m
    case Con{h, t}:
      th_sum_max(t, F32.max(m, F32.abs(h)))

# Pixels
# ------
# rgba bytes -> per pixel (alpha, r, g, b) with alpha in 0..1 and the
# colour channels premultiplied by alpha/255, as the reference does.

def th_pixels(bytes: List<U32>) -> List<&2, Px>:
  match bytes:
    case r <> g <> b <> a <> rest:
      +alpha = F32.div(th_f(a), 255.0)
      +k = (alpha / 255.0 : F32)
      Px{alpha, F32.mul(k, th_f(r)), F32.mul(k, th_f(g)), F32.mul(k, th_f(b))} <> th_pixels(rest)
    case _:
      Nil{}

# sums of (alpha, r, g, b) over the pixels
def th_avg_go(px: List<&2, Px>, sa: F32, sr: F32, sg: F32, sb: F32) ->
  F32 & F32 & F32 & F32:
  match px:
    case Nil{}:
      (sa, sr, sg, sb)
    case Con{Px{a, r, g, b}, t}:
      th_avg_go(t, (sa + a : F32), (sr + r : F32), (sg + g : F32), (sb + b : F32))

def th_avg_div(some: Bool, +sa: F32, sr: F32, sg: F32, sb: F32) -> F32 & F32 & F32 & F32:
  match some:
    case True{}:
      (sa, (sr / sa : F32), (sg / sa : F32), (sb / sa : F32))
    case False{}:
      (sa, sr, sg, sb)

def th_avg_fin(sums: F32 & F32 & F32 & F32) -> F32 & F32 & F32 & F32:
  (+sa, sr, sg, sb) = sums
  th_avg_div(F32.is_gt(sa, 0.0), sa, sr, sg, sb)

# LPQA of one pixel composited atop the average colour: (l, p, q, a)
def th_lpqa(px: List<&2, Px>, +ar: F32, +ag: F32, +ab: F32) ->
  List<&2, Px>:
  match px:
    case Nil{}:
      Nil{}
    case Con{Px{+alpha, pr, pg, pb}, t}:
      +k = (1.0 - alpha : F32)
      +r = (ar * k + pr : F32)
      +g = (ag * k + pg : F32)
      +b = (ab * k + pb : F32)
      Px{alpha, (((r + g : F32) + b : F32) / 3.0 : F32), ((r + g : F32) / 2.0 - b : F32), (r - g : F32)} <> th_lpqa(t, ar, ag, ab)

def th_ch_l(xs: List<&2, Px>) -> List<F32>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{Px{_, l, _, _}, t}:
      l <> th_ch_l(t)

def th_ch_p(xs: List<&2, Px>) -> List<F32>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{Px{_, _, p, _}, t}:
      p <> th_ch_p(t)

def th_ch_q(xs: List<&2, Px>) -> List<F32>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{Px{_, _, _, q}, t}:
      q <> th_ch_q(t)

def th_ch_a(xs: List<&2, Px>) -> List<F32>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{Px{a, _, _, _}, t}:
      a <> th_ch_a(t)

# DCT
# ---

# cos(pi / n * c * (i + 0.5)) for i in 0..n-1
def th_cos_row(count: Nat, +c: F32, +n: F32, +i: Nat) -> List<&2, F32>:
  match count:
    case 0n:
      Nil{}
    case 1n+p:
      +x = th_nat_f(i)
      F32.cos(F32.mul(F32.mul(F32.div(F32.pi(), n), c), (x + 0.5 : F32))) <> th_cos_row(p, c, n, 1n+i)

def th_dot(row: List<&2, F32>, fx: List<&2, F32>) -> F32:
  match row fx:
    case Con{r, rt} Con{f, ft}:
      F32.add((r * f : F32), th_dot(rt, ft))
    case _ _:
      0.0

# sum over rows y of fy(y) * dot(row, fx)
def th_dct_rows(rows: List<&2, List<&2, F32>>, fys: List<&2, F32>, +fx: List<&2, F32>) -> F32:
  match rows fys:
    case Con{row, rt} Con{fy, ft}:
      F32.add(F32.mul(fy, th_dot(row, fx)), th_dct_rows(rt, ft, fx))
    case _ _:
      0.0

# the coefficient (cx, cy) of a channel, already divided by w*h
def th_coeff(+rows: List<&2, List<&2, F32>>, +w: Nat, +h: Nat, cx: Nat, cy: Nat) -> F32:
  +fw = th_nat_f(w)
  +fh = th_nat_f(h)
  +fx = th_cos_row(w, th_nat_f(cx), fw, 0n)
  +fy = th_cos_row(h, th_nat_f(cy), fh, 0n)
  F32.div(th_dct_rows(rows, fy, fx), (fw * fh : F32))

# the (cx, cy) pairs the encoder visits: cy in 0..ny-1 outer, cx inner,
# keeping those with cx * ny < nx * (ny - cy)
def th_keep(keep: Bool, +pair: Pos, rest: List<&2, Pos>) -> List<&2, Pos>:
  match keep:
    case True{}:
      pair <> rest
    case False{}:
      rest

def th_pairs_cx(fuel: Nat, +nx: Nat, +ny: Nat, +cy: Nat, +cx: Nat) -> List<&2, Pos>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      th_keep(Nat.is_lt(Nat.mul(cx, ny), Nat.mul(nx, Nat.sub(ny, cy))), Pos{cx, cy}, th_pairs_cx(p, nx, ny, cy, 1n+cx))

def th_pairs_cy(fuel: Nat, +nx: Nat, +ny: Nat, +cy: Nat) -> List<&2, Pos>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+p:
      List.append(&2, Pos, th_pairs_cx(nx, nx, ny, cy, 0n), th_pairs_cy(p, nx, ny, 1n+cy))

# every coefficient, in visiting order, computed in parallel
def th_coeffs(pairs: List<&2, Pos>, +rows: List<&2, List<&2, F32>>, +w: Nat, +h: Nat) -> List<F32>:
  match pairs:
    case Nil{}:
      Nil{}
    case Con{Pos{cx, cy}, rest}:
      c cs = th_coeff(rows, w, h, cx, cy) th_coeffs(rest, rows, w, h)
      c <> cs

# ac normalised to 0..1 by the scale (when the scale is not zero)
def th_norm(ac: List<&2, F32>, +k: F32) -> List<&2, F32>:
  match ac:
    case Nil{}:
      Nil{}
    case Con{f, t}:
      (0.5 + (k * f : F32) : F32) <> th_norm(t, k)

# 0.5 / scale, or 0 when the scale is zero (then every ac is 0 and stays 0.5... as the reference: unscaled)
def th_norm_k(zero: Bool, scale: F32) -> F32:
  match zero:
    case True{}:
      0.0
    case False{}:
      (0.5 / scale : F32)

# encode one channel: (dc, ac normalised, scale)
def th_channel_fin(cs: List<F32>) -> Ch:
  match cs:
    case Nil{}:
      Ch{0.0, Nil{}, 0.0}
    case Con{dc, ac}:
      +ac2 = th_share(ac)
      +scale = th_sum_max(ac2, 0.0)
      Ch{dc, th_norm(ac2, th_norm_k(F32.is_eq(scale, 0.0), scale)), scale}

def th_channel(flat: List<F32>, +w: Nat, +h: Nat, +nx: Nat, +ny: Nat) -> Ch:
  +rows = th_rows(flat, w)
  th_channel_fin(th_coeffs(th_pairs_cy(ny, nx, ny, 0n), rows, w, h))

# Packing
# -------

def th_nibbles(fs: List<&2, F32>) -> List<U32>:
  match fs:
    case Nil{}:
      Nil{}
    case Con{f, t}:
      th_round((15.0 * f : F32)) <> th_nibbles(t)

def th_pack(ns: List<U32>) -> List<U32>:
  match ns:
    case Nil{}:
      Nil{}
    case lo <> Nil{}:
      lo <> Nil{}
    case lo <> hi <> rest:
      U32.or(lo, U32.shln(hi, 4n)) <> th_pack(rest)

def th_bool_bit(b: Bool) -> U32:
  match b:
    case True{}:
      1
    case False{}:
      0

# the tail of the hash: an alpha byte when present, then the ac nibbles
def th_finish(has_alpha: Bool, head: List<U32>, l_ac: List<&2, F32>, p_ac: List<&2, F32>, q_ac: List<&2, F32>, a: Ch) -> List<U32>:
  match has_alpha:
    case True{}:
      Ch{a_dc, a_ac, a_scale} = a
      alpha_byte = U32.or(th_round((15.0 * a_dc : F32)), U32.shln(th_round((15.0 * a_scale : F32)), 4n))
      acs = List.append(&2, F32, l_ac, List.append(&2, F32, p_ac, List.append(&2, F32, q_ac, a_ac)))
      List.append(&1, U32, head, alpha_byte <> th_pack(th_nibbles(acs)))
    case False{}:
      acs = List.append(&2, F32, l_ac, List.append(&2, F32, p_ac, q_ac))
      List.append(&1, U32, head, th_pack(th_nibbles(acs)))

# the hash: the two headers, then th_finish
def th_assemble(
  +has_alpha: Bool,
  +is_landscape: Bool,
  +lx: U32,
  +ly: U32,
  l: Ch,
  p: Ch,
  q: Ch,
  a: Ch
) -> List<U32>:
  Ch{l_dc, l_ac, l_scale} = l
  Ch{p_dc, p_ac, p_scale} = p
  Ch{q_dc, q_ac, q_scale} = q
  +header24 = U32.or(
    th_round((63.0 * l_dc : F32)),
    U32.or(
      U32.shln(th_round((31.5 + (31.5 * p_dc : F32) : F32)), 6n),
      U32.or(
        U32.shln(th_round((31.5 + (31.5 * q_dc : F32) : F32)), 12n),
        U32.or(U32.shln(th_round((31.0 * l_scale : F32)), 18n), U32.shln(th_bool_bit(has_alpha), 23n))
      )
    )
  )
  +header16 = U32.or(
    Bool.pick(U32, is_landscape, ly, lx),
    U32.or(
      U32.shln(th_round((63.0 * p_scale : F32)), 3n),
      U32.or(U32.shln(th_round((63.0 * q_scale : F32)), 9n), U32.shln(th_bool_bit(is_landscape), 15n))
    )
  )
  head = {[
    U32.and(header24, 255),
    U32.and(U32.shrn(header24, 8n), 255),
    U32.shrn(header24, 16n),
    U32.and(header16, 255),
    U32.shrn(header16, 8n)
  ] : List<U32>}
  th_finish(has_alpha, head, l_ac, p_ac, q_ac, a)

def th_alpha_channel(has_alpha: Bool, flat: List<F32>, +w: Nat, +h: Nat) -> Ch:
  match has_alpha:
    case True{}:
      th_channel(flat, w, h, 5n, 5n)
    case False{}:
      Ch{0.0, Nil{}, 0.0}

def th_limit(has_alpha: Bool) -> F32:
  match has_alpha:
    case True{}:
      5.0
    case False{}:
      7.0

# lx = max(1, round(limit * w / max(w, h)))
def th_axis(+limit: F32, +n: U32, +m: U32) -> U32:
  U32.max(1, th_round(F32.div(F32.mul(limit, th_f(n)), th_f(m))))

def th_encode(+w: U32, +h: U32, avg: F32 & F32 & F32 & F32, px: List<&2, Px>) -> List<U32>:
  (+sum_a, ar, ag, ab) = avg
  +wh = (w * h : U32)
  +has_alpha = F32.is_lt(sum_a, th_f(wh))
  +limit = th_limit(has_alpha)
  +m = U32.max(w, h)
  +lx = th_axis(limit, w, m)
  +ly = th_axis(limit, h, m)
  +wn = U32.to_nat(w)
  +hn = U32.to_nat(h)
  +c = th_lpqa(px, ar, ag, ab)
  l = th_channel(th_ch_l(c), wn, hn, Nat.max(3n, U32.to_nat(lx)), Nat.max(3n, U32.to_nat(ly)))
  p = th_channel(th_ch_p(c), wn, hn, 3n, 3n)
  q = th_channel(th_ch_q(c), wn, hn, 3n, 3n)
  a = th_alpha_channel(has_alpha, th_ch_a(c), wn, hn)
  th_assemble(has_alpha, U32.is_gt(w, h), lx, ly, l, p, q, a)

# Exports
# -------

# w and h in 1..100, rgba exactly w * h * 4 bytes; answers the hash bytes
# (an empty list when the input does not fit)
def th_fits(fits: Bool, +w: U32, +h: U32, rgba: List<U32>) -> List<U32>:
  match fits:
    case False{}:
      Nil{}
    case True{}:
      +px = th_pixels(rgba)
      th_encode(w, h, th_avg_fin(th_avg_go(px, 0.0, 0.0, 0.0, 0.0)), px)

def thumbhash(+w: U32, +h: U32, rgba: List<U32>) -> List<U32>:
  th_fits(Bool.and(U32.is_le(w, 100), U32.is_le(h, 100)), w, h, rgba)

# many images of one size, encoded in parallel
def batch_thumbhash(+w: U32, +h: U32, images: List<List<U32>>) -> List<List<U32>>:
  match images:
    case Nil{}:
      Nil{}
    case Con{img, rest}:
      hd tl = thumbhash(w, h, img) batch_thumbhash(w, h, rest)
      hd <> tl

# the same, with the pixels crossing as one Bytes buffer
def thumbhash_bytes(+w: U32, +h: U32, rgba: B.Bytes) -> List<U32>:
  thumbhash(w, h, B.Bytes.to_list(rgba))

def batch_thumbhash_bytes(+w: U32, +h: U32, images: List<B.Bytes>) -> List<List<U32>>:
  match images:
    case Nil{}:
      Nil{}
    case Con{img, rest}:
      hd tl = thumbhash_bytes(w, h, img) batch_thumbhash_bytes(w, h, rest)
      hd <> tl
