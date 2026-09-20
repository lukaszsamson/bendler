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

type Shape is Data:
  Circle{r: U32}
  Rect{w: U32, h: U32, name: String}
  Dot{}

type Tree is Data:
  Leaf{v: U32}
  Node{l: Tree, ms: Maybe<&2, Tree>, ts: List<&2, Tree>, tag: String}

type Lst is Data:
  LNil{}
  LCons{h: U32, t: Lst}

type Rec is Type:
  Rec{shape: Shape, blob: B.Bytes, pairs: List<(String & F32)>, opt: Maybe<Result<U32, Char>>}

def area(s: Shape) -> U32:
  match s:
    case Circle{+r}:
      (3 * r * r : U32)
    case Rect{w, h, name}:
      (w * h : U32)
    case Dot{}:
      0

def area_all.go(xs: List<&2, Shape>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case x <> rest:
      area_all.go(rest, U32.add(acc, area(x)))

def area_all(xs: List<&2, Shape>) -> U32:
  area_all.go(xs, 0)

def grow(s: Shape) -> Shape:
  match s:
    case Circle{r}:
      Circle{U32.add(r, 1)}
    case Rect{w, h, name}:
      Rect{U32.add(w, 1), U32.add(h, 1), name}
    case Dot{}:
      Circle{1}

def tree_opt(m: Maybe<&2, Tree>) -> List<&2, Tree>:
  match m:
    case None{}:
      []
    case Some{t}:
      [t]

def tree_sum.go(fuel: Nat, ts: List<&2, Tree>) -> U32:
  match fuel:
    case 0n:
      0
    case 1n++p:
      match ts:
        case Nil{}:
          0
        case t <> rest:
          match t:
            case Leaf{v}:
              U32.add(v, tree_sum.go(p, rest))
            case Node{l, ms, tts, tag}:
              U32.add(U32.add(U32.add(tree_sum.go(p, [l]), tree_sum.go(p, tree_opt(ms))), tree_sum.go(p, tts)), tree_sum.go(p, rest))

def tree_sum(t: Tree) -> U32:
  tree_sum.go(1000000n, [t])

def tree_echo(t: Tree) -> Tree:
  t

def lst_len(l: Lst) -> U32:
  match l:
    case LNil{}:
      0
    case LCons{h, t}:
      U32.add(1, lst_len(t))

def lst_range(n: Nat) -> Lst:
  match n:
    case 0n:
      LNil{}
    case 1n++p:
      LCons{U32.from_nat(p), lst_range(p)}

def rec_echo(r: Rec) -> Rec:
  r

def shapes_maybe(m: Maybe<Shape>) -> Maybe<Shape>:
  m

def shape_pair(p: Shape & U32) -> Shape & U32:
  p

def shape_result(r: Result<String, Shape>) -> Result<String, Shape>:
  r
