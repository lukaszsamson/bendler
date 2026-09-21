import Base
import ./bendler.bend as B
import ./stream.bend as S

type Progress is Type:
  Progress{eof: Bool, offset: Nat, state: Result<(U32 & Nat & String), ((Nat & Nat & U32 & B.Bytes & List<B.Bytes> & Bool) & List<List<B.Bytes>>)>}

# Totals are records, fields and decoded field bytes (quotes/separators excluded).
def add_field(len: B.Bytes & U32, rest: Nat & Nat) -> Nat & Nat:
  (unused, n) = len
  (count, bytes) = rest
  (1n+count, Nat.add(U32.to_nat(n), bytes))

def fields(xs: List<B.Bytes>) -> Nat & Nat:
  match xs:
    case Nil{}:
      (0n, 0n)
    case h <> t:
      add_field(B.Bytes.len(h), fields(t))

def add_row(acc: Nat & Nat & Nat, row: Nat & Nat) -> Nat & Nat & Nat:
  (rows, count, bytes) = acc
  (c, b) = row
  (1n+rows, Nat.add(count, c), Nat.add(bytes, b))

def totals(xs: List<List<B.Bytes>>, acc: Nat & Nat & Nat) -> Nat & Nat & Nat:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      totals(t, add_row(acc, fields(h)))

def consume_bytes(pair: B.Bytes & U32, cursor: Nat & Nat & U32 & B.Bytes & List<B.Bytes> & Bool, offset: Nat, limit: U32) -> Progress:
  (data, n) = pair
  Progress{False{}, Nat.add(offset, U32.to_nat(n)), S.feed_csv(cursor, data, False{}, 44, limit)}

def consume(reply: Result<String, Maybe<B.Bytes>>, cursor: Nat & Nat & U32 & B.Bytes & List<B.Bytes> & Bool, +offset: Nat, +limit: U32) -> Progress:
  match reply:
    case Fail{why}:
      Progress{True{}, offset, Fail{(6, offset, why)}}
    case Done{None{}}:
      Progress{True{}, offset, S.feed_csv(cursor, B.Bytes.from_list(Nil{}), True{}, 44, limit)}
    case Done{Some{chunk}}:
      consume_bytes(B.Bytes.len(chunk), cursor, offset, limit)

def loop(~ask: (Nat & U32) -> IO(Result<String, Maybe<B.Bytes>>), fuel: Nat, progress: Progress, acc: Nat & Nat & Nat, +chunk: U32, +limit: U32) -> IO(Result<(U32 & Nat & String), (Nat & Nat & Nat)>):
  match fuel progress:
    case _ Progress{_, _, Fail{why}}:
      IO.pure(Result<(U32 & Nat & String), (Nat & Nat & Nat)>, Fail{why})
    case _ Progress{True{}, offset, Done{(cursor, rows)}}:
      IO.pure(Result<(U32 & Nat & String), (Nat & Nat & Nat)>, Done{totals(rows, acc)})
    case 0n Progress{False{}, offset, Done{(cursor, rows)}}:
      IO.pure(Result<(U32 & Nat & String), (Nat & Nat & Nat)>, Fail{(8, offset, "max_chunks exhausted")})
    case 1n+p Progress{False{}, +offset, Done{(cursor, rows)}}:
      do IO<Result<(U32 & Nat & String), (Nat & Nat & Nat)>>:
        reply : Result<String, Maybe<B.Bytes>> <- ask((offset, chunk))
        loop(~ask, p, consume(reply, cursor, offset, limit), totals(rows, acc), chunk, limit)

def aggregate(~ask: (Nat & U32) -> IO(Result<String, Maybe<B.Bytes>>), chunk: U32, limit: U32, max_chunks: U32) -> IO(Result<(U32 & Nat & String), (Nat & Nat & Nat)>):
  loop(~ask, U32.to_nat(max_chunks), Progress{False{}, 0n, Done{((0n, 0n, 0, B.Bytes.from_list(Nil{}), Nil{}, False{}), Nil{})}}, (0n, 0n, 0n), chunk, limit)
