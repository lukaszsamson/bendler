import Base
import ./bendler.bend as B

# A recursive sphere raytracer whose scene comes from Elixir.
#
# The scene is a user datatype (`Scene`, holding a `List<&2, Sphere>` of
# `Sphere{center: Vec, radius, color: Vec, mirror}`), so the whole
# description crosses the boundary as tagged tuples; the pixels come back
# as the prelude's `B.Bytes`, three bytes per pixel, row-major inside the
# requested tile. `render_tiles` forks the tiles, and every tile forks its
# rows, so one call uses every core.
#
# Per pixel: 2x2 supersampling (four primary rays through the pixel
# quarters), a point light with a shadow ray, five levels of mirror
# bounce in accumulator form (acc += w * (1 - kr) * colour * lum, w *=
# kr), the sky colour on a miss, then clamp and quantise to bytes.
#
# The float code is the one from Bend's own `bench/runtime/raytrace`
# (Apache-2.0): `fl`, `isect5`, `fmax0`, `clamp01` and `shade` are that
# kernel's, and `upstream_checksum` keeps its fixed nine-sphere scene
# verbatim as a bit-exact anchor -- `upstream_checksum(6, 80)` must be
# 402971. The generic renderer below reuses the same primitives with the
# scene taken from the caller and colour added.

type Vec is Data:
  Vec{x: F32, y: F32, z: F32}

type Sphere is Data:
  Sphere{center: Vec, radius: F32, color: Vec, mirror: F32}

type Scene is Data:
  Scene{spheres: List<&2, Sphere>, light: Vec, eye: Vec, sky: Vec}

# a sphere flattened to eight machine words: centre, radius, colour,
# mirror. One flat node, so the ray loops never clone a nested `Vec`.
type Sph8 is Data:
  Sph8{cx: F32, cy: F32, cz: F32, r: F32, cr: F32, cg: F32, cb: F32, kr: F32}

# a hit: whether the ray hit anything, the distance, and the sphere it hit,
# flattened so that a bounce reads its fields straight out of the pattern
type Hit is Data:
  Hit{hit: Bool, t: F32, cx: F32, cy: F32, cz: F32, r: F32,
      cr: F32, cg: F32, cb: F32, kr: F32}

# the upstream kernel's own hit record: a flag, a distance, a sphere index
type UHit is Data:
  UHit{ms: Bool, t: F32, i: U32}

# Float helpers (upstream's, shared by both renderers)
# ===================================================

# float literal n/d (Bend has no float literal syntax that survives an
# aliased import unharmed; one correctly rounded division instead)
def fl(n: U32, d: U32) -> F32:
  F32.div(U32.to_f32(n), U32.to_f32(d))

def f0() -> F32:
  U32.to_f32(0)

def f1() -> F32:
  U32.to_f32(1)

# the miss distance: 1e9, exactly representable as an F32
def fmiss() -> F32:
  U32.to_f32(1000000000)

def isect.t2(t: F32, z: Bool) -> F32:
  match z:
    case True{}:
      U32.to_f32(1000000000)
    case False{}:
      t

def isect.t(+t: F32) -> F32:
  isect.t2(t, F32.is_lt(t, fl(1, 1000)))

def isect.go2(b: F32, disc: F32, z: Bool) -> F32:
  match z:
    case True{}:
      U32.to_f32(1000000000)
    case False{}:
      isect.t(F32.sub(F32.sub(U32.to_f32(0), b), F32.sqrt(disc)))

def isect.go(b: F32, +disc: F32) -> F32:
  isect.go2(b, disc, F32.is_lt(disc, U32.to_f32(0)))

# ray-sphere: t of the near root, or 1e9 for a miss (disc < 0 or t < eps)
def isect5(cx: F32, cy: F32, cz: F32, +r: F32, ox: F32, oy: F32,
           oz: F32, dx: F32, dy: F32, dz: F32) -> F32:
  +px = F32.sub(ox, cx)
  +py = F32.sub(oy, cy)
  +pz = F32.sub(oz, cz)
  +b = F32.add(F32.add(F32.mul(px, dx), F32.mul(py, dy)), F32.mul(pz, dz))
  isect.go(b, F32.sub(F32.mul(b, b), F32.sub(F32.add(F32.add(F32.mul(px, px), F32.mul(py, py)), F32.mul(pz, pz)), F32.mul(r, r))))

def fmax0.go(x: F32, z: Bool) -> F32:
  match z:
    case True{}:
      U32.to_f32(0)
    case False{}:
      x

def fmax0(+x: F32) -> F32:
  fmax0.go(x, F32.is_lt(x, U32.to_f32(0)))

# diffuse term, zeroed when the shadow ray hits something before the light
def shade(st: F32, ll: F32, df: F32) -> F32:
  fmax0.go(df, F32.is_lt(st, ll))

def clamp01.hi.go(x: F32, z: Bool) -> F32:
  match z:
    case True{}:
      U32.to_f32(1)
    case False{}:
      x

def clamp01.hi(+x: F32) -> F32:
  clamp01.hi.go(x, F32.is_lt(U32.to_f32(1), x))

def clamp01.go(x: F32, z: Bool) -> F32:
  match z:
    case True{}:
      U32.to_f32(0)
    case False{}:
      clamp01.hi(x)

def clamp01(+x: F32) -> F32:
  clamp01.go(x, F32.is_lt(x, U32.to_f32(0)))

# The upstream anchor
# ===================
#
# Bend's own raytrace benchmark, unchanged but for the `up.` prefix and
# the `rowf!` GPU call becoming an ordinary one: a fixed nine-sphere
# scene, a point light at (-3, 8, 1), the camera at the origin looking
# +z, and a U32 wrapping sum over the quantised pixels as the checksum.
# The sphere table rides four pure-word selectors so the whole fold
# compiles to one machine segment.

def up.sx(i: Nat) -> F32:
  match i:
    case 0n: U32.to_f32(0)
    case 1n: U32.to_f32(0)
    case 2n: U32.to_f32(2)
    case 3n: F32.sub(U32.to_f32(0), U32.to_f32(2))
    case 4n: U32.to_f32(1)
    case 5n: F32.sub(U32.to_f32(0), U32.to_f32(1))
    case 6n: U32.to_f32(0)
    case 7n: fl(35, 10)
    case 8n+k: F32.sub(U32.to_f32(0), fl(35, 10))

def up.sy(i: Nat) -> F32:
  match i:
    case 0n: F32.sub(U32.to_f32(0), U32.to_f32(10001))
    case 1n: U32.to_f32(0)
    case 2n: fl(5, 10)
    case 3n: fl(5, 10)
    case 4n: F32.sub(U32.to_f32(0), fl(6, 10))
    case 5n: F32.sub(U32.to_f32(0), fl(6, 10))
    case 6n: fl(16, 10)
    case 7n: fl(2, 10)
    case 8n+k: fl(2, 10)

def up.sz(i: Nat) -> F32:
  match i:
    case 0n: U32.to_f32(5)
    case 1n: U32.to_f32(5)
    case 2n: U32.to_f32(6)
    case 3n: U32.to_f32(6)
    case 4n: fl(35, 10)
    case 5n: fl(35, 10)
    case 6n: U32.to_f32(7)
    case 7n: U32.to_f32(8)
    case 8n+k: U32.to_f32(8)

def up.sr(i: Nat) -> F32:
  match i:
    case 0n: U32.to_f32(10000)
    case 1n: U32.to_f32(1)
    case 2n: U32.to_f32(1)
    case 3n: U32.to_f32(1)
    case 4n: fl(4, 10)
    case 5n: fl(4, 10)
    case 6n: fl(12, 10)
    case 7n: U32.to_f32(1)
    case 8n+k: U32.to_f32(1)

def up.skr(i: Nat) -> F32:
  match i:
    case 0n: fl(3, 10)
    case 1n: fl(7, 10)
    case 2n: fl(4, 10)
    case 3n: fl(4, 10)
    case 4n: fl(9, 10)
    case 5n: fl(9, 10)
    case 6n: fl(1, 10)
    case 7n: fl(6, 10)
    case 8n+k: fl(6, 10)

# nearest hit: a min-fold over the spheres, 8 down to 0, strict <. The
# previous iteration's compare rides in as the `lt` column.
def up.nearest(+i: Nat, +ox: F32, +oy: F32, +oz: F32, +dx: F32, +dy: F32,
               +dz: F32, +pt: F32, +pk: U32, +bt: F32, +bi: U32,
               lt: Bool) -> UHit:
  match i lt:
    case 0n False{}:
      UHit{U32.is_eq(bi, 9), bt, bi}
    case 0n True{}:
      UHit{U32.is_eq(pk, 9), pt, pk}
    case 1n++k False{}:
      +t = isect5(up.sx(k), up.sy(k), up.sz(k), up.sr(k), ox, oy, oz, dx, dy, dz)
      up.nearest(k, ox, oy, oz, dx, dy, dz, t, U32.from_nat(k), bt, bi, F32.is_lt(t, bt))
    case 1n++k True{}:
      +t = isect5(up.sx(k), up.sy(k), up.sz(k), up.sr(k), ox, oy, oz, dx, dy, dz)
      up.nearest(k, ox, oy, oz, dx, dy, dz, t, U32.from_nat(k), pt, pk, F32.is_lt(t, pt))

# the same fold answering the bare minimum distance, for the shadow probe
def up.nearest.t(+i: Nat, +ox: F32, +oy: F32, +oz: F32, +dx: F32, +dy: F32,
                 +dz: F32, +pt: F32, +bt: F32, lt: Bool) -> F32:
  match i lt:
    case 0n False{}:
      bt
    case 0n True{}:
      pt
    case 1n++k False{}:
      +t = isect5(up.sx(k), up.sy(k), up.sz(k), up.sr(k), ox, oy, oz, dx, dy, dz)
      up.nearest.t(k, ox, oy, oz, dx, dy, dz, t, bt, F32.is_lt(t, bt))
    case 1n++k True{}:
      +t = isect5(up.sx(k), up.sy(k), up.sz(k), up.sr(k), ox, oy, oz, dx, dy, dz)
      up.nearest.t(k, ox, oy, oz, dx, dy, dz, t, pt, F32.is_lt(t, pt))

# the bounce loop, one self-recursive def, pipelined across `nearest`:
# each turn receives the hit of its own ray as the `ht` column, so the
# miss early-out is a plain column match
def up.trace(dep: Nat, ht: UHit, +sox: F32, +soy: F32, +soz: F32, +rdx: F32,
             +rdy: F32, +rdz: F32, acc: F32, +w: F32) -> F32:
  match dep ht:
    case d2 UHit{True{}, mt, mi}:
      acc
    case 0n UHit{False{}, +t, i}:
      +si = U32.to_nat(i)
      +rr = up.sr(si)
      +hx = F32.add(sox, F32.mul(t, rdx))
      +hy = F32.add(soy, F32.mul(t, rdy))
      +hz = F32.add(soz, F32.mul(t, rdz))
      +nx2 = F32.div(F32.sub(hx, up.sx(si)), rr)
      +ny2 = F32.div(F32.sub(hy, up.sy(si)), rr)
      +nz2 = F32.div(F32.sub(hz, up.sz(si)), rr)
      +lvx = F32.sub(F32.sub(U32.to_f32(0), U32.to_f32(3)), hx)
      +lvy = F32.sub(U32.to_f32(8), hy)
      +lvz = F32.sub(U32.to_f32(1), hz)
      +ll = F32.sqrt(F32.add(F32.add(F32.mul(lvx, lvx), F32.mul(lvy, lvy)), F32.mul(lvz, lvz)))
      +lx = F32.div(lvx, ll)
      +ly = F32.div(lvy, ll)
      +lz = F32.div(lvz, ll)
      df = fmax0(F32.add(F32.add(F32.mul(nx2, lx), F32.mul(ny2, ly)), F32.mul(nz2, lz)))
      sox2 = F32.add(hx, F32.mul(fl(1, 1000), nx2))
      soy2 = F32.add(hy, F32.mul(fl(1, 1000), ny2))
      soz2 = F32.add(hz, F32.mul(fl(1, 1000), nz2))
      st = up.nearest.t(9n, sox2, soy2, soz2, lx, ly, lz, U32.to_f32(1000000000), U32.to_f32(1000000000), False{})
      F32.add(acc, F32.mul(w, F32.add(fl(1, 10), F32.mul(fl(85, 100), shade(st, ll, df)))))
    case 1n+k UHit{False{}, +t, i}:
      +si = U32.to_nat(i)
      +rr = up.sr(si)
      +hx = F32.add(sox, F32.mul(t, rdx))
      +hy = F32.add(soy, F32.mul(t, rdy))
      +hz = F32.add(soz, F32.mul(t, rdz))
      +nx2 = F32.div(F32.sub(hx, up.sx(si)), rr)
      +ny2 = F32.div(F32.sub(hy, up.sy(si)), rr)
      +nz2 = F32.div(F32.sub(hz, up.sz(si)), rr)
      +lvx = F32.sub(F32.sub(U32.to_f32(0), U32.to_f32(3)), hx)
      +lvy = F32.sub(U32.to_f32(8), hy)
      +lvz = F32.sub(U32.to_f32(1), hz)
      +ll = F32.sqrt(F32.add(F32.add(F32.mul(lvx, lvx), F32.mul(lvy, lvy)), F32.mul(lvz, lvz)))
      +lx = F32.div(lvx, ll)
      +ly = F32.div(lvy, ll)
      +lz = F32.div(lvz, ll)
      df = fmax0(F32.add(F32.add(F32.mul(nx2, lx), F32.mul(ny2, ly)), F32.mul(nz2, lz)))
      +sox2 = F32.add(hx, F32.mul(fl(1, 1000), nx2))
      +soy2 = F32.add(hy, F32.mul(fl(1, 1000), ny2))
      +soz2 = F32.add(hz, F32.mul(fl(1, 1000), nz2))
      st = up.nearest.t(9n, sox2, soy2, soz2, lx, ly, lz, U32.to_f32(1000000000), U32.to_f32(1000000000), False{})
      +lum2 = F32.add(fl(1, 10), F32.mul(fl(85, 100), shade(st, ll, df)))
      +kr2 = up.skr(si)
      +k2 = F32.mul(U32.to_f32(2), F32.add(F32.add(F32.mul(rdx, nx2), F32.mul(rdy, ny2)), F32.mul(rdz, nz2)))
      +rd2x = F32.sub(rdx, F32.mul(k2, nx2))
      +rd2y = F32.sub(rdy, F32.mul(k2, ny2))
      +rd2z = F32.sub(rdz, F32.mul(k2, nz2))
      php = up.nearest(9n, sox2, soy2, soz2, rd2x, rd2y, rd2z, U32.to_f32(1000000000), 9, U32.to_f32(1000000000), 9, False{})
      up.trace(k, php, sox2, soy2, soz2, rd2x, rd2y, rd2z,
        F32.add(acc, F32.mul(F32.mul(w, lum2), F32.sub(U32.to_f32(1), kr2))), F32.mul(w, kr2))

def up.subray(+fx: F32, +fy: F32) -> F32:
  +dl = F32.sqrt(F32.add(F32.add(F32.mul(fx, fx), F32.mul(fy, fy)), U32.to_f32(1)))
  +dx = F32.div(fx, dl)
  +dy = F32.div(fy, dl)
  +dz = F32.div(U32.to_f32(1), dl)
  php = up.nearest(9n, U32.to_f32(0), U32.to_f32(0), U32.to_f32(0), dx, dy, dz, U32.to_f32(1000000000), 9, U32.to_f32(1000000000), 9, False{})
  up.trace(4n, php, U32.to_f32(0), U32.to_f32(0), U32.to_f32(0), dx, dy, dz, U32.to_f32(0), U32.to_f32(1))

def up.pixel(x: U32, y: U32, +hw: F32, +hh: F32) -> U32:
  +xf = U32.to_f32(x)
  +yf = U32.to_f32(y)
  l1 = up.subray(F32.div(F32.sub(F32.add(xf, fl(1, 4)), hw), hw), F32.div(F32.sub(hh, F32.add(yf, fl(1, 4))), hw))
  l2 = up.subray(F32.div(F32.sub(F32.add(xf, fl(3, 4)), hw), hw), F32.div(F32.sub(hh, F32.add(yf, fl(1, 4))), hw))
  l3 = up.subray(F32.div(F32.sub(F32.add(xf, fl(1, 4)), hw), hw), F32.div(F32.sub(hh, F32.add(yf, fl(3, 4))), hw))
  l4 = up.subray(F32.div(F32.sub(F32.add(xf, fl(3, 4)), hw), hw), F32.div(F32.sub(hh, F32.add(yf, fl(3, 4))), hw))
  F32.to_u32(F32.mul(U32.to_f32(255), clamp01(F32.mul(F32.add(F32.add(l1, l2), F32.add(l3, l4)), fl(1, 4)))))

def up.colf.px.go(t: Bool, xx: U32, y: U32, hw: F32, hh: F32) -> U32:
  match t:
    case False{}:
      0
    case True{}:
      up.pixel(xx, y, hw, hh)

def up.colf.px(+xx: U32, y: U32, w: U32, hw: F32, hh: F32) -> U32:
  up.colf.px.go(U32.is_lt(xx, w), xx, y, hw, hh)

def up.colf(+d: Nat, +x: U32, +y: U32, +w: U32, +hw: F32, +hh: F32) -> U32:
  match d:
    case 0n:
      up.colf.px(U32.and(U32.mul(x, 2654435761), 16383), y, w, hw, hh)
    case 1n+p:
      a b = up.colf(p, x, y, w, hw, hh) up.colf(p, U32.add(x, U32.shln(1, p)), y, w, hw, hh)
      U32.add(a, b)

def up.rowf(+d: Nat, +y: U32, +m: U32, +w: U32, +hw: F32, +hh: F32) -> U32:
  match d:
    case 0n:
      up.colf(14n, 0, U32.and(U32.mul(y, 1588635697), m), w, hw, hh)
    case 1n+p:
      a b = up.rowf(p, y, m, w, hw, hh) up.rowf(p, U32.add(y, U32.shln(1, p)), m, w, hw, hh)
      U32.add(a, b)

# The upstream checksum over 2^rows image rows of `width` pixels: the
# wrapping U32 sum of every quantised pixel. (6, 80) is 402971.
def upstream_checksum(+rows: U32, +width: U32) -> U32:
  +rr = U32.to_nat(rows)
  hw = U32.to_f32(U32.div(width, 2))
  hh = U32.to_f32(U32.div(U32.shln(1, rr), 2))
  hm = U32.sub(U32.shln(1, rr), 1)
  up.rowf(rr, 0, hm, width, hw, hh)

# the same on the GPU (`!` ships the call and every fork under it to the
# device; with `--gpu off` it runs on the CPU pool)
def upstream_checksum_gpu(+rows: U32, +width: U32) -> U32:
  +rr = U32.to_nat(rows)
  hw = U32.to_f32(U32.div(width, 2))
  hh = U32.to_f32(U32.div(U32.shln(1, rr), 2))
  hm = U32.sub(U32.shln(1, rr), 1)
  up.rowf!(rr, 0, hm, width, hw, hh)

# The scene from Elixir
# =====================

# Sphere -> eight words, in three steps because a constructor's fields
# come out of a `match`, and a `match` may not follow a local binding
def flat3(cx: F32, cy: F32, cz: F32, r: F32, col: Vec, m: F32) -> Sph8:
  match col:
    case Vec{er, eg, eb}:
      Sph8{cx, cy, cz, r, er, eg, eb, m}

def flat2(c: Vec, r: F32, col: Vec, m: F32) -> Sph8:
  match c:
    case Vec{cx, cy, cz}:
      flat3(cx, cy, cz, r, col, m)

def flat1(s: Sphere) -> Sph8:
  match s:
    case Sphere{c, r, col, m}:
      flat2(c, r, col, m)

def flatten(xs: List<&2, Sphere>) ->
  List<&2, Sph8>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{s, rest}:
      flat1(s) <> flatten(rest)

def sph_zero() -> Sph8:
  Sph8{f0(), f0(), f0(), f0(), f0(), f0(), f0(), f0()}

def isect_sph(s: Sph8, ox: F32, oy: F32, oz: F32,
              dx: F32, dy: F32, dz: F32) -> F32:
  match s:
    case Sph8{cx, cy, cz, r, er, eg, eb, m}:
      isect5(cx, cy, cz, r, ox, oy, oz, dx, dy, dz)

# the winner of the fold, flattened into a Hit
def mk_hit(s: Sph8, hit: Bool, t: F32) -> Hit:
  match s:
    case Sph8{cx, cy, cz, r, cr, cg, cb, kr}:
      Hit{hit, t, cx, cy, cz, r, cr, cg, cb, kr}

# nearest hit over the scene list, the same guard-shifted min-fold as
# upstream's: the pending candidate is (pt, ps), the best so far (bt, bs),
# and the previous comparison rides in as `lt`
def nearest(xs: List<&2, Sph8>,
            +ox: F32, +oy: F32, +oz: F32, +dx: F32, +dy: F32, +dz: F32,
            +pt: F32, +ps: Sph8,
            +bt: F32, +bs: Sph8,
            lt: Bool) -> Hit:
  match xs lt:
    case Nil{} False{}:
      mk_hit(bs, F32.is_lt(bt, fmiss()), bt)
    case Nil{} True{}:
      mk_hit(ps, F32.is_lt(pt, fmiss()), pt)
    case Con{+s, rest} False{}:
      +t = isect_sph(s, ox, oy, oz, dx, dy, dz)
      nearest(rest, ox, oy, oz, dx, dy, dz, t, s, bt, bs, F32.is_lt(t, bt))
    case Con{+s, rest} True{}:
      +t = isect_sph(s, ox, oy, oz, dx, dy, dz)
      nearest(rest, ox, oy, oz, dx, dy, dz, t, s, pt, ps, F32.is_lt(t, pt))

# the same fold answering only the distance, for the shadow probe
def nearest_t(xs: List<&2, Sph8>,
              +ox: F32, +oy: F32, +oz: F32, +dx: F32, +dy: F32, +dz: F32,
              +pt: F32, +bt: F32, lt: Bool) -> F32:
  match xs lt:
    case Nil{} False{}:
      bt
    case Nil{} True{}:
      pt
    case Con{s, rest} False{}:
      +t = isect_sph(s, ox, oy, oz, dx, dy, dz)
      nearest_t(rest, ox, oy, oz, dx, dy, dz, t, bt, F32.is_lt(t, bt))
    case Con{s, rest} True{}:
      +t = isect_sph(s, ox, oy, oz, dx, dy, dz)
      nearest_t(rest, ox, oy, oz, dx, dy, dz, t, pt, F32.is_lt(t, pt))

# the bounce loop: one self-recursive def, its own ray's hit riding in as
# the `ht` column, five levels (4n) before the last one stops reflecting
def trace(dep: Nat, ht: Hit,
          +fs: List<&2, Sph8>,
          +lpx: F32, +lpy: F32, +lpz: F32,
          +skyr: F32, +skyg: F32, +skyb: F32,
          +sox: F32, +soy: F32, +soz: F32,
          +rdx: F32, +rdy: F32, +rdz: F32,
          ar: F32, ag: F32, ab: F32, +w: F32) -> Vec:
  match dep ht:
    case d2 Hit{False{}, mt, mcx, mcy, mcz, mr, mcr, mcg, mcb, mkr}:
      Vec{F32.add(ar, F32.mul(w, skyr)), F32.add(ag, F32.mul(w, skyg)), F32.add(ab, F32.mul(w, skyb))}
    case 0n Hit{True{}, +t, +cx, +cy, +cz, +rr, er, eg, eb, m}:
      +hx = F32.add(sox, F32.mul(t, rdx))
      +hy = F32.add(soy, F32.mul(t, rdy))
      +hz = F32.add(soz, F32.mul(t, rdz))
      +nx2 = F32.div(F32.sub(hx, cx), rr)
      +ny2 = F32.div(F32.sub(hy, cy), rr)
      +nz2 = F32.div(F32.sub(hz, cz), rr)
      +lvx = F32.sub(lpx, hx)
      +lvy = F32.sub(lpy, hy)
      +lvz = F32.sub(lpz, hz)
      +ll = F32.sqrt(F32.add(F32.add(F32.mul(lvx, lvx), F32.mul(lvy, lvy)), F32.mul(lvz, lvz)))
      +lx = F32.div(lvx, ll)
      +ly = F32.div(lvy, ll)
      +lz = F32.div(lvz, ll)
      df = fmax0(F32.add(F32.add(F32.mul(nx2, lx), F32.mul(ny2, ly)), F32.mul(nz2, lz)))
      sox2 = F32.add(hx, F32.mul(fl(1, 1000), nx2))
      soy2 = F32.add(hy, F32.mul(fl(1, 1000), ny2))
      soz2 = F32.add(hz, F32.mul(fl(1, 1000), nz2))
      st = nearest_t(fs, sox2, soy2, soz2, lx, ly, lz, fmiss(), fmiss(), False{})
      +lum = F32.add(fl(1, 10), F32.mul(fl(85, 100), shade(st, ll, df)))
      Vec{F32.add(ar, F32.mul(F32.mul(w, lum), er)),
          F32.add(ag, F32.mul(F32.mul(w, lum), eg)),
          F32.add(ab, F32.mul(F32.mul(w, lum), eb))}
    case 1n+k Hit{True{}, +t, +cx, +cy, +cz, +rr, er, eg, eb, +m}:
      +hx = F32.add(sox, F32.mul(t, rdx))
      +hy = F32.add(soy, F32.mul(t, rdy))
      +hz = F32.add(soz, F32.mul(t, rdz))
      +nx2 = F32.div(F32.sub(hx, cx), rr)
      +ny2 = F32.div(F32.sub(hy, cy), rr)
      +nz2 = F32.div(F32.sub(hz, cz), rr)
      +lvx = F32.sub(lpx, hx)
      +lvy = F32.sub(lpy, hy)
      +lvz = F32.sub(lpz, hz)
      +ll = F32.sqrt(F32.add(F32.add(F32.mul(lvx, lvx), F32.mul(lvy, lvy)), F32.mul(lvz, lvz)))
      +lx = F32.div(lvx, ll)
      +ly = F32.div(lvy, ll)
      +lz = F32.div(lvz, ll)
      df = fmax0(F32.add(F32.add(F32.mul(nx2, lx), F32.mul(ny2, ly)), F32.mul(nz2, lz)))
      +sox2 = F32.add(hx, F32.mul(fl(1, 1000), nx2))
      +soy2 = F32.add(hy, F32.mul(fl(1, 1000), ny2))
      +soz2 = F32.add(hz, F32.mul(fl(1, 1000), nz2))
      st = nearest_t(fs, sox2, soy2, soz2, lx, ly, lz, fmiss(), fmiss(), False{})
      +lum = F32.add(fl(1, 10), F32.mul(fl(85, 100), shade(st, ll, df)))
      +k2 = F32.mul(U32.to_f32(2), F32.add(F32.add(F32.mul(rdx, nx2), F32.mul(rdy, ny2)), F32.mul(rdz, nz2)))
      +rd2x = F32.sub(rdx, F32.mul(k2, nx2))
      +rd2y = F32.sub(rdy, F32.mul(k2, ny2))
      +rd2z = F32.sub(rdz, F32.mul(k2, nz2))
      php = nearest(fs, sox2, soy2, soz2, rd2x, rd2y, rd2z, fmiss(), sph_zero(), fmiss(), sph_zero(), False{})
      trace(k, php, fs, lpx, lpy, lpz, skyr, skyg, skyb, sox2, soy2, soz2, rd2x, rd2y, rd2z,
        F32.add(ar, F32.mul(F32.mul(F32.mul(w, lum), er), F32.sub(f1(), m))),
        F32.add(ag, F32.mul(F32.mul(F32.mul(w, lum), eg), F32.sub(f1(), m))),
        F32.add(ab, F32.mul(F32.mul(F32.mul(w, lum), eb), F32.sub(f1(), m))),
        F32.mul(w, m))

# one primary ray through the film point (fx, fy), five bounce levels
def subray(+fs: List<&2, Sph8>,
           +lpx: F32, +lpy: F32, +lpz: F32,
           +skyr: F32, +skyg: F32, +skyb: F32,
           +ox: F32, +oy: F32, +oz: F32, +fx: F32, +fy: F32) -> Vec:
  +dl = F32.sqrt(F32.add(F32.add(F32.mul(fx, fx), F32.mul(fy, fy)), U32.to_f32(1)))
  +dx = F32.div(fx, dl)
  +dy = F32.div(fy, dl)
  +dz = F32.div(U32.to_f32(1), dl)
  php = nearest(fs, ox, oy, oz, dx, dy, dz, fmiss(), sph_zero(), fmiss(), sph_zero(), False{})
  trace(4n, php, fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, dx, dy, dz, f0(), f0(), f0(), f1())

# the rendered bytes into one Bytes buffer, in a single pass: the length
# is known up front (three per pixel), so neither the prelude's copy of
# the list nor its length walk is needed
def pack.go(xs: List<&2, U32>, st: Array<U32> & U32) -> Array<U32> & U32:
  match xs:
    case Nil{}:
      st
    case Con{x, t}:
      (buf, +i) = st
      pack.go(t, (Array.set(U32, buf, i, x), U32.add(i, 1)))

def pack.fin(r: Array<U32> & U32, +len: U32) -> B.Bytes:
  (buf, i) = r
  B.Bytes{len, buf}

def pack(+len: U32, xs: List<&2, U32>) -> B.Bytes:
  pack.fin(pack.go(xs, (Array.new(U32, B.Bytes.depth(len), 0), 0)), len)

def vadd2(ax: F32, ay: F32, az: F32, b: Vec) -> Vec:
  match b:
    case Vec{bx, by, bz}:
      Vec{F32.add(ax, bx), F32.add(ay, by), F32.add(az, bz)}

def vadd(a: Vec, b: Vec) -> Vec:
  match a:
    case Vec{ax, ay, az}:
      vadd2(ax, ay, az, b)

# the averaged supersample, clamped and quantised, pushed onto the tail
def quant(v: Vec, tail: List<&2, U32>) -> List<&2, U32>:
  match v:
    case Vec{r, g, b}:
      F32.to_u32(F32.mul(U32.to_f32(255), clamp01(F32.mul(r, fl(1, 4))))) <>
        (F32.to_u32(F32.mul(U32.to_f32(255), clamp01(F32.mul(g, fl(1, 4))))) <>
          (F32.to_u32(F32.mul(U32.to_f32(255), clamp01(F32.mul(b, fl(1, 4))))) <> tail))

# one pixel: 2x2 supersampling through the pixel's quarters
def pixel(+fs: List<&2, Sph8>,
          +lpx: F32, +lpy: F32, +lpz: F32,
          +skyr: F32, +skyg: F32, +skyb: F32,
          +ox: F32, +oy: F32, +oz: F32,
          x: U32, y: U32, +hw: F32, +hh: F32, tail: List<&2, U32>) -> List<&2, U32>:
  +xf = U32.to_f32(x)
  +yf = U32.to_f32(y)
  +x1 = F32.div(F32.sub(F32.add(xf, fl(1, 4)), hw), hw)
  +x2 = F32.div(F32.sub(F32.add(xf, fl(3, 4)), hw), hw)
  +y1 = F32.div(F32.sub(hh, F32.add(yf, fl(1, 4))), hw)
  +y2 = F32.div(F32.sub(hh, F32.add(yf, fl(3, 4))), hw)
  l1 = subray(fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, x1, y1)
  l2 = subray(fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, x2, y1)
  l3 = subray(fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, x1, y2)
  l4 = subray(fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, x2, y2)
  quant(vadd(vadd(l1, l2), vadd(l3, l4)), tail)

# one row of the tile, left to right; `n` counts the pixels left
# one row, right to left, each pixel pushed onto the words so far: a tail
# loop, so a row costs no frame per pixel (a flat loop on the GPU)
def row_go(n: Nat, +fs: List<&2, Sph8>,
           +lpx: F32, +lpy: F32, +lpz: F32,
           +skyr: F32, +skyg: F32, +skyb: F32,
           +ox: F32, +oy: F32, +oz: F32,
           +x0: U32, +y: U32, +hw: F32, +hh: F32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n++p:
      row_go(p, fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, x0, y, hw, hh,
        pixel(fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, U32.add(x0, U32.from_nat(p)), y, hw, hh, acc))

def row_or_nil(ok: Bool, +fs: List<&2, Sph8>,
               +lpx: F32, +lpy: F32, +lpz: F32,
               +skyr: F32, +skyg: F32, +skyb: F32,
               +ox: F32, +oy: F32, +oz: F32,
               +x0: U32, +y: U32, +tw: U32, +hw: F32, +hh: F32) -> List<&2, U32>:
  match ok:
    case False{}:
      Nil{}
    case True{}:
      row_go(U32.to_nat(tw), fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, x0, y, hw, hh, Nil{})

# The rows of a tile as a balanced fork tree: 2^d leaves, the ones past
# the tile's last row contributing nothing. The tree is kept as a tree
# (a leaf per row) rather than appended into one list: List.append is
# not tail recursive, and on the GPU a frame per pixel word overflows the
# device stack; the tree is flattened once, straight into the buffer.
type Rows is Data:
  RLeaf{px: List<&2, U32>}
  RFork{a: Rows, b: Rows}

def rows_fork(d: Nat, +fs: List<&2, Sph8>,
              +lpx: F32, +lpy: F32, +lpz: F32,
              +skyr: F32, +skyg: F32, +skyb: F32,
              +ox: F32, +oy: F32, +oz: F32,
              +x0: U32, +y: U32, +ylim: U32, +tw: U32, +hw: F32, +hh: F32) -> Rows:
  match d:
    case 0n:
      RLeaf{row_or_nil(U32.is_lt(y, ylim), fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, x0, y, tw, hw, hh)}
    case 1n++p:
      a b = rows_fork(p, fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, x0, y, ylim, tw, hw, hh) rows_fork(p, fs, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, x0, U32.add(y, U32.shln(1, p)), ylim, tw, hw, hh)
      RFork{a, b}

# the rows' words into the buffer, leaf by leaf (the tree is log2(rows) deep)
def pack_rows(t: Rows, st: Array<U32> & U32) -> Array<U32> & U32:
  match t:
    case RLeaf{px}:
      pack.go(px, st)
    case RFork{a, b}:
      pack_rows(b, pack_rows(a, st))

def tile_go(sps: List<&2, Sphere>, +lpx: F32, +lpy: F32, +lpz: F32,
            +skyr: F32, +skyg: F32, +skyb: F32,
            +ox: F32, +oy: F32, +oz: F32,
            +w: U32, +h: U32, +x0: U32, +y0: U32, +tw: U32, +th: U32) -> B.Bytes:
  hw = F32.div(U32.to_f32(w), U32.to_f32(2))
  hh = F32.div(U32.to_f32(h), U32.to_f32(2))
  +len = U32.mul(U32.mul(tw, th), 3)
  pack.fin(pack_rows(rows_fork(B.Bytes.depth(th), flatten(sps), lpx, lpy, lpz,
    skyr, skyg, skyb, ox, oy, oz, x0, y0, U32.add(y0, th), tw, hw, hh),
    (Array.new(U32, B.Bytes.depth(len), 0), 0)), len)

def tile_sky(sky: Vec, sps: List<&2, Sphere>, +lpx: F32, +lpy: F32, +lpz: F32,
             +ox: F32, +oy: F32, +oz: F32,
             +w: U32, +h: U32, +x0: U32, +y0: U32, +tw: U32, +th: U32) -> B.Bytes:
  match sky:
    case Vec{skyr, skyg, skyb}:
      tile_go(sps, lpx, lpy, lpz, skyr, skyg, skyb, ox, oy, oz, w, h, x0, y0, tw, th)

def tile_eye(eye: Vec, sky: Vec, sps: List<&2, Sphere>, +lpx: F32, +lpy: F32, +lpz: F32,
             +w: U32, +h: U32, +x0: U32, +y0: U32, +tw: U32, +th: U32) -> B.Bytes:
  match eye:
    case Vec{ox, oy, oz}:
      tile_sky(sky, sps, lpx, lpy, lpz, ox, oy, oz, w, h, x0, y0, tw, th)

def tile_light(light: Vec, eye: Vec, sky: Vec, sps: List<&2, Sphere>,
               +w: U32, +h: U32, +x0: U32, +y0: U32, +tw: U32, +th: U32) -> B.Bytes:
  match light:
    case Vec{lpx, lpy, lpz}:
      tile_eye(eye, sky, sps, lpx, lpy, lpz, w, h, x0, y0, tw, th)

# `tw` x `th` pixels of the `w` x `h` image, starting at (x0, y0), as
# packed RGB bytes, row-major inside the tile
def render_tile(scene: Scene, +w: U32, +h: U32, +x0: U32, +y0: U32, +tw: U32, +th: U32) -> B.Bytes:
  match scene:
    case Scene{sps, light, eye, sky}:
      tile_light(light, eye, sky, sps, w, h, x0, y0, tw, th)

def render_tiles.go(tiles: List<(U32 & U32 & U32 & U32)>, +scene: Scene, +w: U32, +h: U32) ->
  List<B.Bytes>:
  match tiles:
    case Nil{}:
      Nil{}
    case Con{tl, rest}:
      (x0, y0, tw, th) = tl
      a b = render_tile(scene, w, h, x0, y0, tw, th) render_tiles.go(rest, scene, w, h)
      a <> b

# The tiles forked as a balanced tree over the list (halves by count):
# the device dies on a right spine of forks about a thousand deep
# (bendlang/bend#918), and the CPU pool prefers the balance too. A tile
# is a Data record here so the list can be shared by the two halves.
type Rect is Data:
  Rect{x0: U32, y0: U32, tw: U32, th: U32}

def to_rects(ts: List<(U32 & U32 & U32 & U32)>) -> List<&2, Rect>:
  match ts:
    case Nil{}:
      Nil{}
    case t <> rest:
      (x0, y0, tw, th) = t
      Rect{x0, y0, tw, th} <> to_rects(rest)

def rect_of(t: Rect, +scene: Scene, +w: U32, +h: U32) -> B.Bytes:
  match t:
    case Rect{x0, y0, tw, th}:
      render_tile(scene, w, h, x0, y0, tw, th)

def tiles_fork(n: Nat, +xs: List<&2, Rect>, +scene: Scene, +w: U32, +h: U32) -> List<B.Bytes>:
  match n:
    case 0n:
      Nil{}
    case 1n++p:
      match xs:
        case Nil{}:
          Nil{}
        case t <> rest:
          match rest:
            case Nil{}:
              [rect_of(t, scene, w, h)]
            case _:
              +half = Nat.div(List.length(&2, Rect, xs), 2n)
              a b = tiles_fork(p, List.take(&2, Rect, xs, half), scene, w, h) tiles_fork(p, List.drop(&2, Rect, xs, half), scene, w, h)
              List.append(&1, B.Bytes, a, b)

# every tile of `tiles` (x0, y0, tw, th), rendered in parallel as a
# balanced fork tree (twice as fast as a spine on the CPU pool too)
def render_tiles(
  +scene: Scene, +w: U32, +h: U32, tiles: List<(U32 & U32 & U32 & U32)>
) -> List<B.Bytes>:
  tiles_fork(64n, to_rects(tiles), scene, w, h)

def render_checked.go(ok: Bool, scene: Scene, +w: U32, +h: U32, +x0: U32, +y0: U32,
                      +tw: U32, +th: U32) -> Result<String, B.Bytes>:
  match ok:
    case False{}:
      Fail{"tile out of the image, or empty"}
    case True{}:
      Done{render_tile(scene, w, h, x0, y0, tw, th)}

# `render_tile` with the tile checked against the image: a `Fail` is
# ordinary return data, so Elixir gets `{:error, message}`
def render_checked(
  scene: Scene, +w: U32, +h: U32, +x0: U32, +y0: U32, +tw: U32, +th: U32
) -> Result<String, B.Bytes>:
  render_checked.go(
    Bool.and(Bool.and(Bool.not(U32.is_zero(tw)), Bool.not(U32.is_zero(th))),
      Bool.and(U32.is_le(U32.add(x0, tw), w), U32.is_le(U32.add(y0, th), h))),
    scene, w, h, x0, y0, tw, th)

# every tile of `tiles`, rendered on the GPU: one bang over the tile
# list, whose forks (tiles as a balanced tree, then rows) fill the lanes
def render_tiles_gpu(
  +scene: Scene, +w: U32, +h: U32, tiles: List<(U32 & U32 & U32 & U32)>
) -> List<B.Bytes>:
  tiles_fork!(64n, to_rects(tiles), scene, w, h)

# The fly-through
# ===============
#
# One call renders many frames and emits each as it finishes. The camera
# orbits the scene centre while the light stays where it is in the world,
# which in the tracer's fixed +z camera is the world turning about the
# vertical axis through (cx, cz) -- spheres and light together, so their
# relative geometry (and therefore the shading) is unchanged and only the
# view moves. Nothing of the tracer is duplicated: a frame is the whole
# image as one `render_tile`, whose rows already fork as a balanced tree.

def rot_vec(p: Vec, +ct: F32, +sn: F32, +cx: F32, +cz: F32) -> Vec:
  match p:
    case Vec{x, y, z}:
      +dx = F32.sub(x, cx)
      +dz = F32.sub(z, cz)
      Vec{F32.add(cx, F32.sub(F32.mul(dx, ct), F32.mul(dz, sn))), y,
          F32.add(cz, F32.add(F32.mul(dx, sn), F32.mul(dz, ct)))}

def rot_sphere(s: Sphere, +ct: F32, +sn: F32, +cx: F32, +cz: F32) -> Sphere:
  match s:
    case Sphere{c, r, col, m}:
      Sphere{rot_vec(c, ct, sn, cx, cz), r, col, m}

def rot_spheres(xs: List<&2, Sphere>, +ct: F32, +sn: F32, +cx: F32, +cz: F32) ->
  List<&2, Sphere>:
  match xs:
    case Nil{}:
      Nil{}
    case s <> rest:
      rot_sphere(s, ct, sn, cx, cz) <> rot_spheres(rest, ct, sn, cx, cz)

def rot_scene(scene: Scene, +ct: F32, +sn: F32, +cx: F32, +cz: F32) -> Scene:
  match scene:
    case Scene{sps, light, eye, sky}:
      Scene{rot_spheres(sps, ct, sn, cx, cz), rot_vec(light, ct, sn, cx, cz), eye, sky}

# frame i of `frames` covers i/frames of one full turn
def frame_angle(+i: U32, +frames: U32) -> F32:
  F32.div(F32.mul(F32.mul(U32.to_f32(2), F32.pi()), U32.to_f32(i)), U32.to_f32(frames))

def turned(scene: Scene, +i: U32, +frames: U32, +cx: F32, +cz: F32) -> Scene:
  +a = frame_angle(i, frames)
  rot_scene(scene, F32.cos(a), F32.sin(a), cx, cz)

def fly.go(~emit: B.Bytes -> IO(Bool), +scene: Scene, n: Nat, +i: U32, +frames: U32,
           +w: U32, +h: U32, +cx: F32, +cz: F32, ok: Bool) -> IO(U32):
  match n ok:
    case 0n o:
      IO.pure(U32, i)
    case 1n+p False{}:
      IO.pure(U32, i)
    case 1n+p True{}:
      do IO<U32>:
        ok2 : Bool <- emit(render_tile(turned(scene, i, frames, cx, cz), w, h, 0, 0, w, h))
        fly.go(~emit, scene, p, U32.add(i, 1), frames, w, h, cx, cz, ok2)

# Renders `frames` frames of one turn about (cx, cz) and emits each as
# packed RGB bytes; answers how many it emitted. A `False` from the
# consumer ends the turn early.
def fly(~emit: B.Bytes -> IO(Bool), +scene: Scene, +w: U32, +h: U32, +frames: U32,
        +cx: F32, +cz: F32) -> IO(U32):
  fly.go(~emit, scene, U32.to_nat(frames), 0, frames, w, h, cx, cz, True{})

def fly_gpu.go(~emit: B.Bytes -> IO(Bool), +scene: Scene, n: Nat, +i: U32, +frames: U32,
               +w: U32, +h: U32, +cx: F32, +cz: F32, ok: Bool) -> IO(U32):
  match n ok:
    case 0n o:
      IO.pure(U32, i)
    case 1n+p False{}:
      IO.pure(U32, i)
    case 1n+p True{}:
      do IO<U32>:
        ok2 : Bool <- emit(render_tile!(turned(scene, i, frames, cx, cz), w, h, 0, 0, w, h))
        fly_gpu.go(~emit, scene, p, U32.add(i, 1), frames, w, h, cx, cz, ok2)

# the same on the GPU: one bang per frame, whose row fork fills the lanes
def fly_gpu(~emit: B.Bytes -> IO(Bool), +scene: Scene, +w: U32, +h: U32, +frames: U32,
            +cx: F32, +cz: F32) -> IO(U32):
  fly_gpu.go(~emit, scene, U32.to_nat(frames), 0, frames, w, h, cx, cz, True{})
