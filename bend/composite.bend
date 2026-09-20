import Base
import ./bendler.bend as B

def pair(x: U32 & String) -> U32 & String:
  x

def triple(x: U32 & String & Bool) -> U32 & String & Bool:
  x

def nested(x: (U32 & String) & List<Maybe<U32>>) -> (U32 & String) & List<Maybe<U32>>:
  x

def optional(x: Maybe<Maybe<U32>>) -> Maybe<Maybe<U32>>:
  x

def result(x: Result<(U32 & String), List<Maybe<U32>>>) -> Result<(U32 & String), List<Maybe<U32>>>:
  x

def blob(x: Maybe<Result<U32, (B.Bytes & Maybe<B.Bytes>)>>) -> Maybe<Result<U32, (B.Bytes & Maybe<B.Bytes>)>>:
  x

def empty(x: List<Maybe<Result<(U32 & String), List<U32>>>>) -> List<Maybe<Result<(U32 & String), List<U32>>>>:
  x

def right(x: U32 & (String & Bool)) -> U32 & (String & Bool):
  x

def wide(x: U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32) -> U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32:
  x

def half(x: F32) -> F32:
  F32.div(x, 2.0)

def f32_div(x: F32, y: F32) -> F32:
  F32.div(x, y)

def upper(c: Char) -> Char:
  Char.to_upper(c)

def chars(s: String) -> List<&2, Char>:
  String.to_list(s)

def from_chars(cs: List<&2, Char>) -> String:
  String.from_list(cs)

def tally.bump(w: String, r: Map<&2, U32> & U32) -> Map<&2, U32>:
  (m, n) = r
  Map.set(&2, U32, m, w, U32.add(n, 1))

def tally.go(ws: List<String>, m: Map<&2, U32>) -> Map<&2, U32>:
  match ws:
    case Nil{}:
      m
    case +w <> rest:
      tally.go(rest, tally.bump(w, Map.get(U32, 0, m, w)))

def tally(ws: List<String>) -> Map<&2, U32>:
  tally.go(ws, Map.new(&2, U32))

def total.go(kvs: List<&2, Sigma<&2, &2, String, _ => U32>>, acc: U32) -> U32:
  match kvs:
    case Nil{}:
      acc
    case kv <> rest:
      (k, v) = kv
      total.go(rest, U32.add(acc, v))

def total(m: Map<&2, U32>) -> U32:
  total.go(Map.to_list(&2, U32, m), 0)

def scale.go(kvs: List<&1, Sigma<&2, &1, String, _ => F32>>, +k: F32) -> List<&1, Sigma<&2, &1, String, _ => F32>>:
  match kvs:
    case Nil{}:
      Nil{}
    case kv <> rest:
      (key, v) = kv
      (key, F32.mul(v, k)) <> scale.go(rest, k)

def scale(m: Map<F32>, k: F32) -> Map<F32>:
  Map.from_list(&1, F32, scale.go(Map.to_list(&1, F32, m), k))

def blobs(m: Map<List<B.Bytes>>) -> Map<List<B.Bytes>>:
  m
