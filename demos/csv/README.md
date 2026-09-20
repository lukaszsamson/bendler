# Small CSV parser

An original Bend implementation of a useful subset of
[NimbleCSV](https://github.com/dashbitco/nimble_csv)'s eager byte-oriented
parsing semantics. NimbleCSV 1.3.0 is pinned as a test-only dependency and
used as the differential oracle and benchmark baseline. No NimbleCSV source
is copied. Research reference: commit `edd9687688c080cc99ae8d0c18fc0879aa5be1c0`
(Apache-2.0).

This demo delivers tuples, Maybe and Result in the shared codec rather than
hiding errors inside an ad-hoc string. The public Bend signature is:

```text
parse_csv(data: B.Bytes, separator: Maybe<U32>)
  -> Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>
```

The signature above is wrapped for readability; actual exported signatures
must remain on one line. Private state is a Bend datatype and never crosses
the boundary. No arbitrary-user-datatype converter is needed.

## Run

From the repository root, with Bend 2.0.20 and clang installed:

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

Not implemented: streaming, incremental parsing, dumping, arbitrary escape
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
A future parse-and-compute kernel returning a small aggregate might amortize
that cost, but this benchmark does not establish it.

## Safety checks

Current status after the user-datatype extension: the expanded ASan harness
faults in generated runtime `root_done` before reaching its new Dyn tests
(at both O1 and O3). See `docs/VALIDATION.md` in the repository root. The
earlier successful codec run below is historical, not a passing result for
the current fixture. The command remains a failing reproducer; no sanitizer
finding is suppressed.

Tests compare fixed cases, all 781 strings of length 0–4 over quote/comma/CR/LF/a,
and 40 deterministic generated tables against
NimbleCSV, including invalid UTF-8 and embedded newlines. Composite tests
exercise both native backends, nested empty values and malformed frames.
`check_asan.exs` instruments an external port only, never a loaded NIF; it
checks 100 composite/malformed-request cycles with leak detection disabled.

A separate combined AddressSanitizer/UndefinedBehaviorSanitizer attempt
stopped in generated Bend runtime `root_done` with “applying zero offset to
null pointer” (`shim.c:1269`). Thus this work does **not** claim a UBSan-clean
Bend runtime or sanitizer coverage of an in-process NIF. The ASan-only
command is retained for reproducible codec checks.
