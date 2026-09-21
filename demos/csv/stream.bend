import Base
import ./bendler.bend as B
import ./csv.bend as C

# The cursor preserves the eager parser's reversed partial field/row, but
# crosses the boundary as byte buffers instead of lists of individual bytes.
# (mode, absolute byte offset, current record bytes, field, row, dirty)
def thaw_rows(xs: List<B.Bytes>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      B.Bytes.share(B.Bytes.to_list(h)) <> thaw_rows(t)

def pack(mode: Nat, pos: Nat, size: U32, field: List<&2, U32>, row: List<&2, List<&2, U32>>, dirty: Bool) -> Nat & Nat & U32 & B.Bytes & List<B.Bytes> & Bool:
  (mode, pos, size, C.field_bytes(field), C.row_bytes(row), dirty)

def final_answer(result: Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>, pos: Nat) -> Result<(U32 & Nat & String), ((Nat & Nat & U32 & B.Bytes & List<B.Bytes> & Bool) & List<List<B.Bytes>>)>:
  match result:
    case Fail{e}:
      Fail{e}
    case Done{(out, n)}:
      Done{((0n, pos, 0, B.Bytes.from_list(Nil{}), Nil{}, False{}), out)}

def answer(st: C.State, +pos: Nat, size: U32, eof: Bool) -> Result<(U32 & Nat & String), ((Nat & Nat & U32 & B.Bytes & List<B.Bytes> & Bool) & List<List<B.Bytes>>)>:
  match st eof:
    case C.S{mode, field, row, rows, dirty, Some{e}} _:
      Fail{e}
    case C.S{mode, field, row, rows, dirty, None{}} False{}:
      Done{(pack(mode, pos, size, field, row, dirty), C.rows_bytes(List.reverse(&2, List<&2, List<&2, U32>>, rows)))}
    case C.S{mode, field, row, rows, dirty, None{}} True{}:
      final_answer(C.finish_mode(mode, pos, dirty, field, row, rows), pos)

def step_limited(over: Bool, ch: U32, sep: U32, pos: Nat, st: C.State) -> C.State:
  match over:
    case True{}:
      C.failed(5, pos, "record exceeds max_record_bytes")
    case False{}:
      C.step(ch, sep, pos, st)

def scan(xs: List<U32>, +sep: U32, +pos: Nat, +size: U32, +limit: U32, eof: Bool, st: C.State) -> Result<(U32 & Nat & String), ((Nat & Nat & U32 & B.Bytes & List<B.Bytes> & Bool) & List<List<B.Bytes>>)>:
  match xs st:
    case _ C.S{mode, field, row, rows, dirty, Some{e}}:
      Fail{e}
    case Nil{} C.S{mode, field, row, rows, dirty, None{}}:
      answer(C.S{mode, field, row, rows, dirty, None{}}, pos, size, eof)
    case h <> t C.S{mode, field, row, rows, +dirty, None{}}:
      +used = Bool.pick(U32, dirty, size, 0)
      scan(t, sep, 1n+pos, (used + 1 : U32), limit, eof, step_limited(U32.is_ge(used, limit), h, sep, pos, C.S{mode, field, row, rows, dirty, None{}}))

def feed_csv(cursor: Nat & Nat & U32 & B.Bytes & List<B.Bytes> & Bool, chunk: B.Bytes, eof: Bool, sep: U32, limit: U32) -> Result<(U32 & Nat & String), ((Nat & Nat & U32 & B.Bytes & List<B.Bytes> & Bool) & List<List<B.Bytes>>)>:
  (mode, pos, size, field, row, dirty) = cursor
  scan(B.Bytes.to_list(chunk), sep, pos, size, limit, eof, C.S{mode, B.Bytes.share(B.Bytes.to_list(field)), thaw_rows(row), Nil{}, dirty, None{}})
