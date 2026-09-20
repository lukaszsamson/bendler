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
