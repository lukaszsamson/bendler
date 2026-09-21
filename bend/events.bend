import Base

# The fixture for typed, bounded events: defs that answer `IO(T)` and take
# a typed emitter, `~emit: T -> IO(Bool)`. The emitter is a Bend template
# (`~`), because a function type is Type-kinded and a closure binder can
# therefore never be `+`; a template is inlined at compile time and may be
# used once per turn of a loop.
#
# Every loop here is the same shape: the answer of the previous emit rides
# in as the `ok` column, so the early-out is an ordinary column match and
# the recursive call stays in the tail of the `do` block (a `match` may not
# head a term inside one).

type Point is Data:
  Point{x: U32, y: U32}

# an ordinary pure export, unaffected by any of this
def double(n: U32) -> U32:
  U32.mul(n, 2)

# an effectful export that emits nothing
def tick(n: U32) -> IO(U32):
  IO.pure(U32, U32.add(n, 1))

# counts up from 0, emitting each number, and answers how many it emitted
def count.go(~emit: U32 -> IO(Bool), n: Nat, +i: U32, ok: Bool) -> IO(U32):
  match n ok:
    case 0n o:
      IO.pure(U32, i)
    case 1n+p False{}:
      IO.pure(U32, i)
    case 1n+p True{}:
      do IO<U32>:
        ok2 : Bool <- emit(i)
        count.go(~emit, p, U32.add(i, 1), ok2)

def count(~emit: U32 -> IO(Bool), n: U32) -> IO(U32):
  count.go(~emit, U32.to_nat(n), 0, True{})

# the same, with a user datatype as the event type
def points.go(~emit: Point -> IO(Bool), n: Nat, +i: U32, ok: Bool) -> IO(U32):
  match n ok:
    case 0n o:
      IO.pure(U32, i)
    case 1n+p False{}:
      IO.pure(U32, i)
    case 1n+p True{}:
      do IO<U32>:
        ok2 : Bool <- emit(Point{i, U32.mul(i, i)})
        points.go(~emit, p, U32.add(i, 1), ok2)

def points(~emit: Point -> IO(Bool), n: U32) -> IO(U32):
  points.go(~emit, U32.to_nat(n), 0, True{})

# a product event, to show composites cross as events exactly as replies do
def pairs.go(~emit: (U32 & String) -> IO(Bool), n: Nat, +i: U32, ok: Bool) -> IO(U32):
  match n ok:
    case 0n o:
      IO.pure(U32, i)
    case 1n+p False{}:
      IO.pure(U32, i)
    case 1n+p True{}:
      do IO<U32>:
        ok2 : Bool <- emit((i, U32.show(i)))
        pairs.go(~emit, p, U32.add(i, 1), ok2)

def pairs(~emit: (U32 & String) -> IO(Bool), n: U32) -> IO(U32):
  pairs.go(~emit, U32.to_nat(n), 0, True{})
