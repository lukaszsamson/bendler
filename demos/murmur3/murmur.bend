import Base

# Murmur3 x86_32 (Austin Appleby's algorithm, as in `preciz/murmur`).
#
# Reference: `Murmur.Hash32X86.hash_x86_32/2` (binary in, U32 out,
# little-endian blocks, all arithmetic mod 2^32). Bend's `U32`
# already wraps mod 2^32 (`Word.add/mul` on 32 bits), so `U32.mul`
# is the reference's `mul32`, and rotation is `shln/shrn/or`.
# `h * 5 + n` is written `(h << 2) + h + n`, equal mod 2^32.
#
# Bytes cross as `List<U32>` (each 0..255): the interim bytes
# convention until track 3 grows a first-class binary. Hashing is
# over raw bytes, so UTF-8 multibyte text needs no code-point
# story: `:binary.bin_to_list/1` on Elixir's side, nothing more.
#
# `murmur3_x86_32/2` mirrors `Murmur.hash_x86_32/2` argument order
# (data, seed). `batch_murmur3/2` hashes many inputs under one
# seed and runs the independent hashes as parallel calls
# (`hd tl = ... ...`), like `batch_levenshtein/2`.

def mur_rotl(+x: U32, +r: Nat) -> U32:
  U32.or(U32.shln(x, r), U32.shrn(x, Nat.sub(32n, r)))

def mur_mix_k(k: U32) -> U32:
  k1 = U32.mul(k, 3432918353)
  k2 = mur_rotl(k1, 15n)
  U32.mul(k2, 461845907)

def mur_block(h: U32, k: U32) -> U32:
  h1 = U32.xor(h, mur_mix_k(k))
  +h2 = mur_rotl(h1, 13n)
  h3 = U32.add(U32.shln(h2, 2n), h2)
  U32.add(h3, 3864292196)

def mur_tail_mix(h: U32, k: U32) -> U32:
  U32.xor(h, mur_mix_k(k))

def mur_fmix(+h: U32) -> U32:
  +a = U32.xor(h, U32.shrn(h, 16n))
  +b = U32.mul(a, 2246822507)
  +c = U32.xor(b, U32.shrn(b, 13n))
  +d = U32.mul(c, 3266489909)
  U32.xor(d, U32.shrn(d, 16n))

# Body over the byte list, shrinking list first so the
# termination check sees it. Returns (h, len); the 1..3-byte
# tail is mixed on the way out, little-endian like the blocks.
def mur_body_cons(r: U32 & U32) -> U32 & U32:
  (h2, ln) = r
  (h2, (ln + 4 : U32))

def mur_body(xs: List<U32>, h: U32) -> U32 & U32:
  match xs:
    case Nil{}:
      (h, 0)
    case b0 <> Nil{}:
      (mur_tail_mix(h, b0), 1)
    case b0 <> b1 <> Nil{}:
      k = U32.or(b0, U32.shln(b1, 8n))
      (mur_tail_mix(h, k), 2)
    case b0 <> b1 <> b2 <> Nil{}:
      k = U32.or(b0, U32.or(U32.shln(b1, 8n), U32.shln(b2, 16n)))
      (mur_tail_mix(h, k), 3)
    case b0 <> b1 <> b2 <> b3 <> t:
      k = U32.or(b0, U32.or(U32.shln(b1, 8n), U32.or(U32.shln(b2, 16n), U32.shln(b3, 24n))))
      mur_body_cons(mur_body(t, mur_block(h, k)))

def mur_final(h: U32, len: U32) -> U32:
  mur_fmix(U32.xor(h, len))

def mur_wrap(r: U32 & U32) -> U32:
  (h, len) = r
  mur_final(h, len)

def murmur3_x86_32(data: List<U32>, seed: U32) -> U32:
  mur_wrap(mur_body(data, seed))

def batch_murmur3(datas: List<List<U32>>, +seed: U32) -> List<U32>:
  match datas:
    case Nil{}:
      Nil{}
    case d <> t:
      hd tl = murmur3_x86_32(d, seed) batch_murmur3(t, seed)
      hd <> tl
