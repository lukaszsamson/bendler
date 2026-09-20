import Base

# Bendler's prelude: the types Bendler marshals beyond Base's.
#
# Bendler writes this file next to any Bend source that uses it; import it
# as `import ./bendler.bend as B` and take or answer `B.Bytes`. Do not edit
# it: the build overwrites an outdated copy.

# A byte string: `len` bytes, one per slot of `buf`, whose size is the
# power of two at or above `len` (the slots past `len` are zero). An
# Elixir binary crosses as one of these without a list cell per byte.
type Bytes is Type:
  Bytes{len: U32, buf: Array<U32>}

def Bytes.len(b: Bytes) -> Bytes & U32:
  match b:
    case Bytes{+len, buf}:
      (Bytes{len, buf}, len)

# the byte at i (wrapping past len, as the buffer does)
def Bytes.at.fin(len: U32, r: Array<U32> & U32) -> Bytes & U32:
  (buf, x) = r
  (Bytes{len, buf}, x)

def Bytes.at(b: Bytes, i: U32) -> Bytes & U32:
  match b:
    case Bytes{len, buf}:
      Bytes.at.fin(len, buf[i])

# the bytes as a list, first byte first
def Bytes.to_list.step(r: Array<U32> & U32, i: U32, acc: List<U32>) ->
  Array<U32> & U32 & List<U32>:
  (buf, x) = r
  (buf, i, x <> acc)

def Bytes.to_list.go(fuel: Nat, st: Array<U32> & U32 & List<U32>) -> List<U32>:
  match fuel:
    case 0n:
      (buf, i, acc) = st
      acc
    case 1n+p:
      (buf, +i, acc) = st
      +j = (i - 1 : U32)
      Bytes.to_list.go(p, Bytes.to_list.step(buf[j], j, acc))

def Bytes.to_list(b: Bytes) -> List<U32>:
  match b:
    case Bytes{+len, buf}:
      Bytes.to_list.go(U32.to_nat(len), (buf, len, Nil{}))

# the depth d with 2^d >= n (0 for n <= 1); the recursion is bounded by
# the 32 bits of n and evaluated eagerly (Bool.pick), which is cheap here
def Bytes.depth.go(fuel: Nat, +n: U32, +d: Nat) -> Nat:
  match fuel:
    case 0n:
      d
    case 1n+p:
      Bool.pick(Nat, U32.is_le(n, U32.shln(1, d)), d, Bytes.depth.go(p, n, 1n+d))

def Bytes.depth(+n: U32) -> Nat:
  Bytes.depth.go(32n, n, 0n)

# a byte string from a list of bytes
def Bytes.fill(xs: List<&2, U32>, st: Array<U32> & U32) -> Array<U32> & U32:
  match xs:
    case Nil{}:
      st
    case Con{x, t}:
      (buf, +i) = st
      Bytes.fill(t, (Array.set(U32, buf, i, x), (i + 1 : U32)))

def Bytes.from_list.fin(r: Array<U32> & U32) -> Bytes:
  (buf, len) = r
  Bytes{len, buf}

# an affine list of bytes, rebuilt as a reusable one
def Bytes.share(xs: List<U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+h, t}:
      h <> Bytes.share(t)

def Bytes.from_list(xs: List<U32>) -> Bytes:
  +ys = Bytes.share(xs)
  +n = U32.from_nat(List.length(&2, U32, ys))
  Bytes.from_list.fin(Bytes.fill(ys, (Array.new(U32, Bytes.depth(n), 0), 0)))

# a byte string of a known length from an affine list of bytes, in one
# pass (from_list walks the list three times to learn the length); bytes
# past n are dropped, a short list leaves zeros
def Bytes.fill1(xs: List<U32>, st: Array<U32> & U32) -> Array<U32> & U32:
  match xs:
    case Nil{}:
      st
    case Con{x, t}:
      (buf, +i) = st
      Bytes.fill1(t, (Array.set(U32, buf, i, x), (i + 1 : U32)))

def Bytes.from_list_n(+n: U32, xs: List<U32>) -> Bytes:
  Bytes.from_list.fin(Bytes.fill1(List.take(&1, U32, xs, U32.to_nat(n)), (Array.new(U32, Bytes.depth(n), 0), 0)))

# Dyn
# ===

# A dynamic value: the shape every user datatype crosses in. The host
# builds one of these for an argument that holds a user datatype and reads
# one back for such a result; generated defs in the shim convert between a
# Dyn and the user's type. Numbers, strings and bytes are leaves; a list, a
# tuple and an option (zero or one element) are a DL; a constructor (a user
# one, or a Result's Fail/Done as 0/1) is a DK with its fields as kids.
type Dyn is Type:
  DU{w: U32}
  DF{f: F32}
  DN{n: Nat}
  DS{s: String}
  DB{len: U32, buf: Array<U32>}
  DL{xs: List<&1, Dyn>}
  DK{tag: U32, kids: List<&1, Dyn>}

def Dyn.u32(d: Dyn) -> U32:
  match d:
    case DU{w}:
      w
    case _:
      0

def Dyn.bool(d: Dyn) -> Bool:
  match d:
    case DU{w}:
      U32.is_eq(w, 1)
    case _:
      False{}

def Dyn.chr(d: Dyn) -> Char:
  match d:
    case DU{w}:
      Char.from_u32(w)
    case _:
      Char.from_u32(0)

def Dyn.f32(d: Dyn) -> F32:
  match d:
    case DF{f}:
      f
    case _:
      0.0

def Dyn.nat(d: Dyn) -> Nat:
  match d:
    case DN{n}:
      n
    case _:
      0n

def Dyn.str(d: Dyn) -> String:
  match d:
    case DS{s}:
      s
    case _:
      ""

def Dyn.bytes(d: Dyn) -> Bytes:
  match d:
    case DB{len, buf}:
      Bytes{len, buf}
    case _:
      Bytes{0, Array.new(U32, 0n, 0)}

def Dyn.of_bytes(b: Bytes) -> Dyn:
  match b:
    case Bytes{len, buf}:
      DB{len, buf}

def Dyn.list(d: Dyn) -> List<&1, Dyn>:
  match d:
    case DL{xs}:
      xs
    case _:
      []

def Dyn.unit(d: Dyn) -> Unit:
  match d:
    case _:
      Unit{}

def Dyn.of_unit(u: Unit) -> Dyn:
  match u:
    case Unit{}:
      DU{0}
