import Base
import ./bendler.bend as B

# A byte-oriented CSV subset following NimbleCSV.RFC4180's eager parser.
# State modes: 0 field start, 1 unquoted, 2 quoted, 3 closed quote, 4 CR after quote.
type State is Type:
  S{mode: Nat, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>, dirty: Bool, err: Maybe<(U32 & Nat & String)>}

def failed(code: U32, pos: Nat, msg: String) -> State:
  S{0n, Nil{}, Nil{}, Nil{}, False{}, Some{(code, pos, msg)}}

def cr_pick(cr: Bool, xs: List<&2, U32>, tail: List<&2, U32>) -> List<&2, U32>:
  match cr:
    case True{}:
      tail
    case False{}:
      xs

def strip_cr(+xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      cr_pick(U32.is_eq(h, 13), xs, t)

def newline(field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> State:
  line = List.reverse(&2, List<&2, U32>, List.reverse(&2, U32, field) <> row)
  S{0n, Nil{}, Nil{}, line <> rows, False{}, None{}}

def quote_start(start: Bool, pos: Nat, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> State:
  match start:
    case True{}:
      S{2n, field, row, rows, True{}, None{}}
    case False{}:
      failed(1, pos, "quote in unquoted field")

def unquoted(sep: Bool, quote: Bool, lf: Bool, start: Bool, ch: U32, pos: Nat, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> State:
  match sep quote lf:
    case True{} _ _:
      S{0n, Nil{}, List.reverse(&2, U32, field) <> row, rows, True{}, None{}}
    case False{} True{} _:
      quote_start(start, pos, field, row, rows)
    case False{} False{} True{}:
      newline(strip_cr(field), row, rows)
    case False{} False{} False{}:
      S{1n, ch <> field, row, rows, True{}, None{}}

def quoted(quote: Bool, ch: U32, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> State:
  match quote:
    case True{}:
      S{3n, field, row, rows, True{}, None{}}
    case False{}:
      S{2n, ch <> field, row, rows, True{}, None{}}

def closed(sep: Bool, quote: Bool, lf: Bool, cr: Bool, pos: Nat, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> State:
  match sep quote lf cr:
    case True{} _ _ _:
      S{0n, Nil{}, List.reverse(&2, U32, field) <> row, rows, True{}, None{}}
    case False{} True{} _ _:
      S{2n, 34 <> field, row, rows, True{}, None{}}
    case False{} False{} True{} _:
      newline(field, row, rows)
    case False{} False{} False{} True{}:
      S{4n, field, row, rows, True{}, None{}}
    case False{} False{} False{} False{}:
      failed(2, pos, "data after closing quote")

def after_cr(lf: Bool, pos: Nat, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> State:
  match lf:
    case True{}:
      newline(field, row, rows)
    case False{}:
      failed(2, pos, "expected LF after closing quote and CR")

def step_mode(mode: Nat, +ch: U32, sep: U32, pos: Nat, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> State:
  match mode:
    case 0n:
      unquoted(U32.is_eq(ch, sep), U32.is_eq(ch, 34), U32.is_eq(ch, 10), True{}, ch, pos, field, row, rows)
    case 1n:
      unquoted(U32.is_eq(ch, sep), U32.is_eq(ch, 34), U32.is_eq(ch, 10), False{}, ch, pos, field, row, rows)
    case 2n:
      quoted(U32.is_eq(ch, 34), ch, field, row, rows)
    case 3n:
      closed(U32.is_eq(ch, sep), U32.is_eq(ch, 34), U32.is_eq(ch, 10), U32.is_eq(ch, 13), pos, field, row, rows)
    case _:
      after_cr(U32.is_eq(ch, 10), pos, field, row, rows)

def step_err(err: Maybe<(U32 & Nat & String)>, ch: U32, sep: U32, pos: Nat, mode: Nat, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> State:
  match err:
    case None{}:
      step_mode(mode, ch, sep, pos, field, row, rows)
    case Some{e}:
      S{0n, Nil{}, Nil{}, Nil{}, False{}, Some{e}}

def step(ch: U32, sep: U32, pos: Nat, st: State) -> State:
  match st:
    case S{mode, field, row, rows, dirty, err}:
      step_err(err, ch, sep, pos, mode, field, row, rows)

def field_bytes(+xs: List<&2, U32>) -> B.Bytes:
  +n = U32.from_nat(List.length(&2, U32, xs))
  B.Bytes.from_list.fin(B.Bytes.fill(xs, (Array.new(U32, B.Bytes.depth(n), 0), 0)))

def row_bytes(xs: List<&2, List<&2, U32>>) -> List<B.Bytes>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      field_bytes(h) <> row_bytes(t)

def rows_bytes(xs: List<&2, List<&2, List<&2, U32>>>) -> List<List<B.Bytes>>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      row_bytes(h) <> rows_bytes(t)

def success(+rows: List<&2, List<&2, List<&2, U32>>>) -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>:
  Done{(rows_bytes(List.reverse(&2, List<&2, List<&2, U32>>, rows)), List.length(&2, List<&2, List<&2, U32>>, rows))}

def finish_dirty(dirty: Bool, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>:
  match dirty:
    case False{}:
      success(rows)
    case True{}:
      line = List.reverse(&2, List<&2, U32>, List.reverse(&2, U32, field) <> row)
      success(line <> rows)

def finish_mode(mode: Nat, pos: Nat, dirty: Bool, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>:
  match mode:
    case 2n:
      Fail{(3, pos, "unterminated quoted field")}
    case 4n:
      Fail{(2, pos, "expected LF after closing quote and CR")}
    case _:
      finish_dirty(dirty, field, row, rows)

def finish_err(err: Maybe<(U32 & Nat & String)>, mode: Nat, pos: Nat, dirty: Bool, field: List<&2, U32>, row: List<&2, List<&2, U32>>, rows: List<&2, List<&2, List<&2, U32>>>) -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>:
  match err:
    case Some{e}:
      Fail{e}
    case None{}:
      finish_mode(mode, pos, dirty, field, row, rows)

def finish(st: State, pos: Nat) -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>:
  match st:
    case S{mode, field, row, rows, dirty, err}:
      finish_err(err, mode, pos, dirty, field, row, rows)

def scan(xs: List<U32>, +sep: U32, +pos: Nat, st: State) -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>:
  match xs:
    case Nil{}:
      finish(st, pos)
    case h <> t:
      scan(t, sep, 1n+pos, step(h, sep, pos, st))

def separator_valid(valid: Bool, data: B.Bytes, sep: U32) -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>:
  match valid:
    case True{}:
      scan(B.Bytes.to_list(data), sep, 0n, S{0n, Nil{}, Nil{}, Nil{}, False{}, None{}})
    case False{}:
      Fail{(4, 0n, "separator must be a byte other than quote, CR or LF")}

def parse_with(data: B.Bytes, +sep: U32) -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>:
  separator_valid(Bool.and(U32.is_le(sep, 255), Bool.and(U32.is_ne(sep, 34), Bool.and(U32.is_ne(sep, 13), U32.is_ne(sep, 10)))), data, sep)

def parse_csv(data: B.Bytes, separator: Maybe<U32>) -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>:
  match separator:
    case None{}:
      parse_with(data, 44)
    case Some{sep}:
      parse_with(data, sep)
