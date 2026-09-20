import Base
import ./bendler.bend as B

def fib(n: Nat, a: U32, +b: U32) -> U32:
  match n:
    case 0n:
      a
    case 1n+p:
      fib(p, b, (a + b : U32))

def sum(xs: List<U32>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      sum(t, (acc + h : U32))

def shout(s: String) -> String:
  s ++ "!"

def range(+n: Nat, acc: List<U32>) -> List<U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      range(p, U32.from_nat(p) <> acc)

def is_big(x: U32) -> Bool:
  (x > 1000 : U32)

def square(+n: Nat) -> Nat:
  Nat.mul(n, n)

def pow2(+n: Nat) -> U32:
  match n:
    case 0n:
      1
    case 1n+p:
      a b = pow2(p) pow2(p)
      (a + b : U32)

def words(s: String) -> List<&2, String>:
  String.split(s, ' ')

def nest(xs: List<List<U32>>) -> List<List<U32>>:
  xs

def slow(+n: Nat) -> U32:
  pow2(n)

# Bytes: the prelude's type, an Elixir binary on the other side
def byte_sum.go(xs: List<U32>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{x, t}:
      byte_sum.go(t, (acc + x : U32))

def byte_sum(b: B.Bytes) -> U32:
  byte_sum.go(B.Bytes.to_list(b), 0)

def rev_bytes(b: B.Bytes) -> B.Bytes:
  B.Bytes.from_list(List.reverse(&1, U32, B.Bytes.to_list(b)))

def second_byte.fin(r: B.Bytes & U32) -> U32:
  (b2, x) = r
  x

def second_byte(b: B.Bytes) -> U32:
  second_byte.fin(B.Bytes.at(b, 1))

# a multi-line signature and Bytes.from_list_n
def pack_bytes(
  n: U32,
  xs: List<U32>
) -> B.Bytes:
  B.Bytes.from_list_n(n, xs)
