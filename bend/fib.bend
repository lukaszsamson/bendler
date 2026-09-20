import Base

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
