# Adapted from bendlang/bend revision 7561656155a4285c1e4ccfcb3505ab59524de973
# bench/runtime/tree-bitonic/main.bend (Apache-2.0).
# warp/flow are upstream; list adaptation and set operations are new.
import Base
# CPU bitonic network over a balanced tree. List input is padded to a
# power of two, then trimmed back to its original length after sorting.

type Tree is Data:
  Leaf{v: U32}
  Node{l: Tree, r: Tree}

# compare-and-swap of two leaves; s flips the order (Bend3's
# swap(s ^ (x > y), x, y))
def warp_leaf.go(x: U32, y: U32, t: Bool) -> Tree:
  match t:
    case False{}:
      Node{Leaf{x}, Leaf{y}}
    case True{}:
      Node{Leaf{y}, Leaf{x}}

def warp_leaf(+x: U32, +y: U32, s: Bool) -> Tree:
  warp_leaf.go(x, y, Bool.xor(s, U32.is_gt(x, y)))

def warp_zip(wa: Tree, wb: Tree) -> Tree:
  match wa wb:
    case Node{a0, a1} Node{b0, b1}:
      Node{Node{a0, b0}, Node{a1, b1}}
    case Node{a0, a1} Leaf{bv}:
      Leaf{0}
    case Leaf{av} Node{b0, b1}:
      Leaf{0}
    case Leaf{av} Leaf{bv}:
      Leaf{0}

def warp(a: Tree, b: Tree, +s: Bool) -> Tree:
  match a b:
    case Leaf{av} Leaf{bv}:
      warp_leaf(av, bv, s)
    case Leaf{av} Node{ba, bb}:
      Leaf{0}
    case Node{aa, ab} Leaf{bv}:
      Leaf{0}
    case Node{aa, ab} Node{ba, bb}:
      wa wb = warp(aa, ba, s) warp(ab, bb, s)
      warp_zip(wa, wb)

# warp of a whole subtree: compare-and-swap its root pair
def warp_node(t: Tree, +s: Bool) -> Tree:
  match t:
    case Leaf{v}:
      Leaf{v}
    case Node{a, b}:
      warp(a, b, s)

# bitonic merge, root pair already warped: flow(d, s, w) finishes a
# merge of depth 1+d whose root warp the CALLER did (a match may only
# scrutinize a parameter or a field, so the warped tree rides in as
# the argument and each half's warp feeds the next self-call)
def flow(+d: Nat, +s: Bool, w: Tree) -> Tree:
  match d w:
    case 0n Leaf{v}:
      Leaf{v}
    case 0n Node{wa, wb}:
      Node{wa, wb}
    case 1n+p Leaf{v}:
      Leaf{v}
    case 1n+p Node{wa, wb}:
      fa fb = flow(p, s, warp_node(wa, s)) flow(p, s, warp_node(wb, s))
      Node{fa, fb}

def bit(b: Bool) -> Nat:
  match b:
    case True{}:
      1n
    case False{}:
      0n

# ceil(log2(n)), with explicit bounded fuel. Empty input uses a padded leaf.
def depth_go(fuel: Nat, +x: U32) -> Nat:
  match fuel:
    case 0n:
      0n
    case 1n+p:
      Nat.add(bit(U32.is_ne(x, 0)), depth_go(p, U32.shrn(x, 1n)))

def leaf(xs: List<&2, U32>) -> Tree:
  match xs:
    case Nil{}:
      Leaf{4294967295}
    case h <> t:
      Leaf{h}

def build(+d: Nat, +xs: List<&2, U32>) -> Tree:
  match d:
    case 0n:
      leaf(xs)
    case 1n+p:
      +half = U32.to_nat(U32.shln(1, p))
      a b = build(p, List.take(&2, U32, xs, half)) build(p, List.drop(&2, U32, xs, half))
      Node{a, b}

def tree_sort(+d: Nat, +s: Bool, t: Tree) -> Tree:
  match d t:
    case 0n Leaf{v}:
      Leaf{v}
    case 0n Node{a, b}:
      Node{a, b}
    case 1n+p Leaf{v}:
      Leaf{v}
    case 1n+p Node{a, b}:
      sa sb = tree_sort(p, False{}, a) tree_sort(p, True{}, b)
      flow(p, s, warp(sa, sb, s))

def flatten(t: Tree, acc: List<&2, U32>) -> List<&2, U32>:
  match t:
    case Leaf{v}:
      v <> acc
    case Node{a, b}:
      flatten(a, flatten(b, acc))

def sort_nonempty(xs: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  +d = depth_go(32n, U32.sub(U32.from_nat(n), 1))
  List.take(&2, U32, flatten(tree_sort(d, False{}, build(d, xs)), Nil{}), n)

# The original length, not a sentinel comparison, removes padding. Real MAX_U32 stays.
def sort(+xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      sort_nonempty(xs, List.length(&2, U32, xs))

def unique_go(xs: List<&2, U32>, last: U32, +acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      List.reverse(&2, U32, acc)
    case +h <> t:
      unique_go(t, h, Bool.pick(List<&2, U32>, U32.is_eq(h, last), acc, h <> acc))

def unique_sorted(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      unique_go(t, h, [h])

def unique(xs: List<&2, U32>) -> List<&2, U32>:
  unique_sorted(sort(xs))

def union(a: List<&2, U32>, b: List<&2, U32>) -> List<&2, U32>:
  unique(List.append(&2, U32, a, b))

# mode=True: intersection; mode=False: left difference.
def merge_order(less: Bool, equal: Bool, mode: Bool, +a: U32, at: List<&2, U32>, +b: U32, bt: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32> & List<&2, U32> & List<&2, U32>:
  match less equal:
    case True{} _:
      (at, b <> bt, Bool.pick(List<&2, U32>, mode, acc, a <> acc))
    case False{} True{}:
      (at, bt, Bool.pick(List<&2, U32>, mode, a <> acc, acc))
    case False{} False{}:
      (a <> at, bt, acc)

def merge_lists(mode: Bool, xs: List<&2, U32>, ys: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32> & List<&2, U32> & List<&2, U32>:
  match xs ys:
    case Nil{} _:
      (Nil{}, Nil{}, acc)
    case +a <> at Nil{}:
      (at, Nil{}, Bool.pick(List<&2, U32>, mode, acc, a <> acc))
    case +a <> at +b <> bt:
      merge_order(U32.is_lt(a, b), U32.is_eq(a, b), mode, a, at, b, bt, acc)

def merge_step(mode: Bool, st: List<&2, U32> & List<&2, U32> & List<&2, U32>) -> List<&2, U32> & List<&2, U32> & List<&2, U32>:
  (xs, ys, acc) = st
  merge_lists(mode, xs, ys, acc)

def merge_go(fuel: Nat, +mode: Bool, st: List<&2, U32> & List<&2, U32> & List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      (xs, ys, acc) = st
      List.reverse(&2, U32, acc)
    case 1n+p:
      merge_go(p, mode, merge_step(mode, st))

def combine(mode: Bool, +a: List<&2, U32>, +b: List<&2, U32>) -> List<&2, U32>:
  n = Nat.add(List.length(&2, U32, a), List.length(&2, U32, b))
  merge_go(n, mode, (a, b, Nil{}))

def intersection(a: List<&2, U32>, b: List<&2, U32>) -> List<&2, U32>:
  sa sb = unique(a) unique(b)
  combine(True{}, sa, sb)

def difference(a: List<&2, U32>, b: List<&2, U32>) -> List<&2, U32>:
  sa sb = unique(a) unique(b)
  combine(False{}, sa, sb)

def identity(xs: List<&2, U32>) -> List<&2, U32>:
  xs
