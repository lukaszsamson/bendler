import Base

# Batched Levenshtein distance (code points, not graphemes).
#
# Reference: `Simetric.Levenshtein` (two-row DP) and
# `TheFuzz.Similarity.Levenshtein` (code-point semantics via
# `String.to_charlist/1`). A Bend `String` is a list of `Char`
# code points, and the Bendler codec maps an Elixir binary to
# code points (invalid bytes become U+FFFD), so this matches a
# code-point reference exactly and matches `Simetric` only where
# graphemes and code points coincide (pure ASCII, precomposed
# text). Combining sequences diverge on purpose: e.g. "e\x0301"
# vs "\xe9" is 2 here (substitute + delete) and 1 in `Simetric`.
#
# `levenshtein/2` is one pair; `batch_levenshtein/2` maps over
# two same-length lists pairwise and runs the independent
# comparisons as parallel calls (`hd tl = ... ...`), so a batch
# spreads across every core while one request is in flight.
# Unequal lengths truncate to the shorter list; two empty
# lists answer `[]`. Empty strings answer the other length
# (`Simetric` semantics; `the_fuzz` answers `nil` there).

def lev_cost_pick(eq: Bool) -> U32:
  match eq:
    case True{}:
      0
    case False{}:
      1

def lev_cost(c1: Char, c2: Char) -> U32:
  lev_cost_pick(Char.is_eq(c1, c2))

def lev_len(xs: List<&2, Char>, n: U32) -> U32:
  match xs:
    case Nil{}:
      n
    case h <> t:
      lev_len(t, (n + 1 : U32))

def lev_init(cs2: List<&2, Char>, +i: U32) -> List<U32>:
  match cs2:
    case Nil{}:
      [i]
    case h <> t:
      i <> lev_init(t, (i + 1 : U32))

# One DP row body: prev_tail is prev[1..], diag is prev[j-1],
# cur_prev is cur[j-1]. Cells are sequential by construction.
def lev_row(cs2: List<&2, Char>, prev_tail: List<U32>, +c1: Char, cur_prev: U32, diag: U32) -> List<U32>:
  match cs2 prev_tail:
    case Nil{} Nil{}:
      Nil{}
    case Nil{} _:
      Nil{}
    case _ Nil{}:
      Nil{}
    case h2 <> t2 +p <> pt:
      cost = lev_cost(c1, h2)
      del = (p + 1 : U32)
      ins = (cur_prev + 1 : U32)
      sub = (diag + cost : U32)
      +cur = U32.min(U32.min(del, ins), sub)
      cur <> lev_row(t2, pt, c1, cur, p)

# Split prev into head/tail and build the full next row [i, ...].
def lev_next(cs2: List<&2, Char>, prev: List<U32>, c1: Char, +i: U32) -> List<U32>:
  match prev:
    case Nil{}:
      Nil{}
    case p0 <> pt:
      i <> lev_row(cs2, pt, c1, i, p0)

def lev_last_tail(xs: List<U32>, cur: U32) -> U32:
  match xs:
    case Nil{}:
      cur
    case h <> t:
      lev_last_tail(t, h)

def lev_last(xs: List<U32>, d: U32) -> U32:
  match xs:
    case Nil{}:
      d
    case h <> t:
      lev_last_tail(t, h)

# Outer loop over s1; prev always holds len(s2)+1 cells.
def lev_outer(cs1: List<&2, Char>, +cs2: List<&2, Char>, prev: List<U32>, +i: U32) -> U32:
  match cs1:
    case Nil{}:
      lev_last(prev, 0)
    case +h <> t:
      lev_outer(t, cs2, lev_next(cs2, prev, h, i), (i + 1 : U32))

def lev_lists(+cs1: List<&2, Char>, +cs2: List<&2, Char>) -> U32:
  match cs1 cs2:
    case Nil{} _:
      lev_len(cs2, 0)
    case _ Nil{}:
      lev_len(cs1, 0)
    case h1 <> t1 h2 <> t2:
      prev = lev_init(cs2, 0)
      lev_outer(cs1, cs2, prev, 1)

def levenshtein(a: String, b: String) -> U32:
  lev_lists(String.to_list(a), String.to_list(b))

def batch_levenshtein(a: List<String>, b: List<String>) -> List<U32>:
  match a b:
    case Nil{} _:
      Nil{}
    case _ Nil{}:
      Nil{}
    case h1 <> t1 h2 <> t2:
      hd tl = levenshtein(h1, h2) batch_levenshtein(t1, t2)
      hd <> tl
