# Small CSV parser

An original Bend implementation of a useful subset of
[NimbleCSV](https://github.com/dashbitco/nimble_csv)'s eager byte-oriented
parsing semantics. NimbleCSV 1.3.0 is pinned as a test-only dependency and
used as the differential oracle and benchmark baseline. No NimbleCSV source
is copied. Reference revision: `edd9687688c080cc99ae8d0c18fc0879aa5be1c0`
(Apache-2.0).

This demo delivers tuples, Maybe and Result in the shared codec rather than
hiding errors inside an ad-hoc string. The public Bend signature is:

```text
parse_csv(data: B.Bytes, separator: Maybe<U32>)
  -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>
```

The signature above is wrapped for readability. Private state is a Bend datatype and never crosses
the boundary. No arbitrary-user-datatype converter is needed.

## Run

From the repository root, with Bend 2.0.25 and clang installed:

```sh
mix deps.get
mix test demos/csv/test test/composite_test.exs
MIX_ENV=test mix run demos/csv/bench.exs
ROWS=10,1000,10000 SAMPLES=5 MIX_ENV=test mix run demos/csv/bench.exs
MIX_ENV=test mix run demos/csv/check_asan.exs
```

The demo modules compile only in the test environment, like other demos.
Start `{Bendler.Demos.CsvPort, []}` under a supervisor before calling:

```elixir
alias Bendler.Demos.CsvPort
CsvPort.parse_string("name,age\nAlice,30\n")
# {:ok, [["Alice", "30"]]}

CsvPort.parse_csv("a,b\nc,d", :none)
# {:ok, {[["a", "b"], ["c", "d"]], 2}}

CsvPort.parse_csv("a\tb", {:some, 9})
# {:ok, {[["a", "b"]], 1}}

CsvPort.parse_string("\"unterminated", skip_headers: false)
# {:error, {3, 13, "..."}}  # diagnostic text is not a compatibility contract
```

`parse_string/2` accepts at most 1 MiB and defaults to `skip_headers: true`,
matching NimbleCSV. Set `separator: "\t"` for TSV. The raw generated
`parse_csv/2` keeps every row and bypasses this demo input-size limit; use
the bounded wrapper for untrusted input. Input size alone does not guarantee
a wall-time or memory bound: configure port deadlines and OS limits as needed.

Supported: comma or one-byte separator, double-quoted fields, doubled quotes,
LF and CRLF records, multiline quoted fields, blank records, trailing empty
fields, no final newline, Unicode and arbitrary non-UTF-8 bytes. Fields are
Bytes, not Bend Strings, so binary content is preserved. Whitespace is data.

Errors are `{code, zero_based_byte_offset, message}`: 1 quote inside an
unquoted field, 2 data after a closing quote, 3 EOF inside quotes, 4 invalid
separator (quote, CR, LF or outside a byte). EOF's offset is input byte size.
Errors return through Result; a subsequent request still works. Parser errors
do not promise NimbleCSV's wording. Transport errors remain exceptions.

The eager API is `parse_string/2`. A separate bounded incremental
API is described below.

Not implemented: dumping, arbitrary escape
strings, multi-byte separators, alternate newline configurations, BOM removal
or UTF-16 conversion. This is not a drop-in NimbleCSV replacement. Parsing is
a sequential state machine; it neither requests GPU builds nor pretends a
single CSV document can be split safely at arbitrary newlines.

## Benchmark

M2 Pro, Elixir 1.20.3 / OTP 28, Bend 2.0.20, clang 21, one Bend CPU worker.
Five warmed samples, median milliseconds; input construction and correctness
checks excluded, the entire call and output materialization included. Both
parsers keep all rows. Each deterministic row has four fields. Quoted rows
exercise separators, escaped quotes and multiline content. Large-case spread
is substantial (GC/allocation), so do not treat these as stable microbenchmarks.

| Rows | Shape | Bytes | NimbleCSV | Bend Port |
|---:|---|---:|---:|---:|
| 10 | plain | 192 | 0.010 | 0.077 |
| 10 | quoted | 422 | 0.020 | 0.069 |
| 1,000 | plain | 22,786 | 0.305 | 1.968 |
| 1,000 | quoted | 45,786 | 1.257 | 3.563 |
| 10,000 | plain | 247,788 | 5.675 | 28.439 |
| 10,000 | quoted | 477,788 | 35.170 | 98.129 |

At 10,000 rows the min–max ranges were 5.070–13.816 / 25.345–45.866 ms
(plain, NimbleCSV / Bend) and 30.605–81.679 / 90.579–120.724 ms (quoted).
The script prints the ranges on each run and checks every result.

**Keep ordinary CSV parsing in NimbleCSV.** Its binary-pattern parser wins
every measured case. This Bend parser converts input into a byte list,
allocates field buffers and transfers the entire nested result to the BEAM.
The [ask-driven parser](ASK.md) keeps the reduction in Bend and returns
a compact aggregate; its separate benchmark measures that trade-off.

## Streaming over Port and experimental NIF

`stream.bend` reuses the eager parser's state transitions and makes them
resumable. For the single-call, callback-driven variant that keeps rows and
aggregation inside Bend, see [Ask-driven CSV aggregation](ASK.md). `CsvStream.parse_stream/2` accepts an Enumerable of **arbitrary
binary chunks** and lazily yields rows. It supports quoted multiline fields,
doubled quotes, split CRLF, arbitrary bytes and EOF without a terminator.

```elixir
alias Bendler.Demos.{CsvStream, CsvStreamPort}

# The demo modules are compiled in MIX_ENV=test, like the other demos.
{:ok, supervisor} = Supervisor.start_link([CsvStreamPort], strategy: :one_for_one)

"large.csv"
|> File.stream!(16_384)
|> CsvStream.parse_stream(backend: :port, skip_headers: true)
|> Enum.reduce(0, fn _row, count -> count + 1 end)

# Same API, without starting a Port. All experimental NIF hazards still apply.
["name,value\nAlice,", "\"a,b\"\n"]
|> CsvStream.parse_stream(backend: :nif)
|> Enum.to_list()
# [["Alice", "a,b"]]

Supervisor.stop(supervisor)
```

Options:

| Option | Default | Contract |
|---|---|---|
| `backend` | `:port` | `:port` or experimental `:nif` |
| `separator` | `","` | one byte, not quote/CR/LF |
| `skip_headers` | `true` | discard the first parsed row, even across chunks |
| `chunk_bytes` | 16,384 | maximum bytes sent per call, 1–65,536 |
| `max_record_bytes` | 65,536 | maximum physical record size, 1–65,536; includes quotes, separators and terminators |

Syntax and record-limit errors raise `CsvStream.Error` with `code` and an
absolute zero-based `byte_offset`. Code 5 means record limit exceeded; the
other codes match the eager parser. Rows already delivered are not rolled
back. A failing batch is not partially delivered, so the exact delivered
prefix before an error can depend on chunking. Valid-input results and error
offsets do not. Transport errors remain `Bendler.Error`.

### Demand, cancellation and limitations

This is **host-driven incremental parsing**, not a long-running Bend `IO`
export with `ask`/`emit`. This incremental API does not use BEAM effects
or change the native transport (see [ASK.md](ASK.md) for the callback variant).
Each ordinary typed call returns a bounded
row batch and an opaque cursor containing partial field/row buffers. The
Elixir enumeration owns that cursor; neither backend holds a parser session.

- Demand drives source reads and native calls. There is no background
  producer or subscriber mailbox. A paused consumer starts no more work.
- A native call handles at most `chunk_bytes`; completed rows are delivered
  one at a time from that batch before asking for more input. Tiny source
  chunks are not coalesced automatically.
- `Enum.take/2` and normal consumer errors halt/close a compliant source
  Enumerable without flushing EOF. No native cancellation is needed between
  batches. Death during a call retains the existing backend semantics: a NIF
  computation is abandoned, not interrupted; Port ownership is unchanged.
- Both bindings use one CPU worker and a 5-second **per-call** timeout. This
  is not a whole-stream deadline or a timeout on user-provided source IO.
- Application buffering is bounded by a partial record plus one input/output
  batch, not total file size. That is not an OS RSS cap: Bend's arena, allocator
  retention, concurrent enumerations, source buffering and consumer storage
  are outside it. A source yielding a huge binary can retain that binary while
  its slices are consumed; use fixed-size file chunks for bounded source IO.
- Cursor copying costs time, especially a long partial field arriving in tiny
  chunks. Such input can cause quadratic cumulative copying within the
  configured record limit. This demo does not claim faster CSV parsing.
- The raw generated `feed_csv/5` functions expose implementation details;
  use `parse_stream/2` for validated limits. No cursor persistence/versioning
  contract is provided.

### Streaming validation and benchmark

```sh
MIX_ENV=test mix test demos/csv/test/csv_stream_test.exs --warnings-as-errors
MIX_ENV=test mix run demos/csv/check_stream_asan.exs
ROWS=10000,100000 SAMPLES=5 MIX_ENV=test mix run demos/csv/stream_bench.exs
```

The shared streaming suite covers both backends: every two-part split of
representative binary/quoted fixtures, one-byte chunks, generated tables,
concurrent cursors, lazy reads, source and consumer failures, early halt,
maximum-size records, limits across chunks, EOF diagnostics and reuse after
errors. The ASan probe instruments the external Port with the existing
platform-ABI workaround; it does not instrument a NIF inside the BEAM.

The benchmark writes a temporary CSV file with quoted/multiline/Unicode
fields, then reads fixed-size chunks. Every full run reduces output to a row
count and checksum instead of retaining all rows. NimbleCSV uses
`to_line_stream/1` before `parse_stream/2`. Fixture generation and warmup are
outside timing; file reading, parsing and reduction are inside. Time to first
row uses a separate early-halting run. Results are warmed medians, not cold
disk IO or peak-RSS measurements.

Local Apple M2 Pro, Elixir 1.20.3 / OTP 28 / Bend 2.0.20, 16 KiB chunks,
one Bend CPU worker, five samples:

| Rows | Input bytes | NimbleCSV total / first row | Port total / first row | NIF total / first row |
|---:|---:|---:|---:|---:|
| 10,000 | 507,788 | 10.51 / 0.135 ms | 36.07 / 1.173 ms | 33.33 / 1.137 ms |
| 100,000 | 5,277,790 | 100.32 / 0.118 ms | 350.63 / 1.363 ms | 358.86 / 1.139 ms |

NimbleCSV remains the recommendation for CSV alone. Port and NIF are close;
this workload does not justify accepting NIF isolation hazards for speed.
The gain over the eager demo is incremental consumption and bounded parser
state, not a measured throughput advantage. Tiny chunks and very long partial
records make cursor copying more expensive.

## Safety checks

`check_asan.exs`, `check_stream_asan.exs` and `check_ask_asan.exs` build
AddressSanitizer-instrumented copies of the external Port executable and
drive them from Elixir: Base composite values, `Dyn` values, malformed
frames, 100 composite and malformed-request cycles, partitioned streaming
round trips, a 64 KiB record and error recovery. Leak detection is off.

The instrumented copy compiles a separate `shim_asan.c` with Bend's
`PRESERVE` attributes disabled and the platform ABI, because an
ASan-instrumented `preserve_none` segment clobbers the arm64 register
holding `corpus_eval`'s spill-frame address. ASan stays enabled across the
codec and the runtime, and the production shim keeps the attributes.

These probes instrument an external port only, never a NIF loaded into the
BEAM, and no UndefinedBehaviorSanitizer result is claimed.

Correctness tests compare fixed cases, all 781 strings of length 0 to 4 over
quote, comma, CR, LF and `a`, and 40 deterministic generated tables against
NimbleCSV, including invalid UTF-8 and embedded newlines. Composite tests
exercise both native backends, nested empty values and malformed frames.
