# Ask-driven CSV aggregation (Port only)

This complements the host-driven `CsvStream.parse_stream/2` demo. One Bend
invocation owns the parser cursor and aggregate, asks Elixir for input, and
returns `{records, fields, decoded_field_bytes}`. Rows do not cross back to
Elixir. Headers count as ordinary rows. The CSV subset and record-size limits
are the same as the existing parser; this demo uses comma as the separator.

```elixir
alias Bendler.Demos.CsvAskPort
{:ok, supervisor} = Supervisor.start_link([CsvAskPort], strategy: :one_for_one)
CsvAskPort.aggregate_file("data.csv", chunk_bytes: 16_384)
#=> {:ok, {100_000, 300_000, 2_488_895}} # illustrative totals
Supervisor.stop(supervisor)
```

The callback contract is explicit in Bend:

```text
~ask: (Nat & U32) -> IO(Result<String, Maybe<B.Bytes>>)
```

The request is `{absolute_offset, requested_bytes}`. A callback returns
`{:ok, {:some, binary}}`, `{:ok, :none}` for EOF, or `{:error, message}`.
The generated function takes the handler as its final Elixir argument:

```elixir
CsvAskPort.aggregate(16_384, 65_536, 1_000_000, fn {offset, count} ->
  case :file.pread(io_device, offset, count) do
    {:ok, bytes} -> {:ok, {:some, bytes}}
    :eof -> {:ok, :none}
    {:error, reason} -> {:error, inspect(reason)}
  end
end)
```

`aggregate_file/2` opens a non-raw file device and closes it in `after`.
Handlers run in fresh processes, so raw file handles and process-dictionary
state must not be shared with them. Use a host-owned IO device/GenServer/ETS
table for state. Offsets make this particular handler stateless.

## Bounds and failure semantics

- One outstanding ask, no speculative input reads and no event mailbox.
- Default chunk 16 KiB, record cap 64 KiB. The file wrapper validates both
  options in `1..65_536`; the low-level generated function is not that wrapper.
- Default one million asks, including EOF. Exhaustion returns error code 8.
  Empty non-EOF chunks cannot create an unbounded loop because asks consume fuel.
- File read errors return code 6 with the current byte offset; parser errors
  retain their existing codes. These are normal typed results; the worker survives.
- The demo's total native-call deadline is 30 seconds, including callbacks and
  queue time. Each handler separately has a fixed five-second deadline.
- Handler raise/throw/exit, invalid response or handler timeout raises
  `Bendler.Error` with `:callback` and stops the Port owner and worker. The
  supervisor replaces them; no retry is attempted. The total deadline yields
  `:timeout`. Caller death cancels by stopping the occupied worker too.
- Direct callback reentry into the same worker raises `:reentrant`; indirect
  cycles through other processes are not detected. Keep finite deadlines.
- Reply values use the normal codec budgets and are validated again in C
  before allocation/decoding. A malformed raw reply kills only the Port worker.
- This is sequential parsing and aggregation, not a parallel CSV algorithm.
  Partial fields still undergo conversions inside Bend between chunks. This is
  bounded by the record cap, but tiny chunks remain expensive.

## Benchmark

```sh
ROWS=10000,100000 SAMPLES=5 MIX_ENV=test mix run demos/csv/ask_bench.exs
MIX_ENV=test mix run demos/csv/check_ask_asan.exs
```

Apple M2 Pro, macOS arm64, Elixir 1.20.3 / OTP 28 / Bend 2.0.20. Five warmed
samples, median wall time, one Bend CPU worker, 16 KiB chunks. All three
paths read the same file and verify the same aggregate. Fixture creation is
excluded; file IO, callback processes and encoding are included. The ask
wrapper uses a non-raw file device; the other paths use `File.stream!`.

| Records | NimbleCSV | Host-driven Port | Ask-driven Port | Asks including EOF |
|---:|---:|---:|---:|---:|
| 10,000 | 7.017 ms | 26.055 ms | 18.522 ms | 24 |
| 100,000 | 85.805 ms | 265.978 ms | 193.700 ms | 233 |

Ask-driven aggregation was about 27% faster than the host-driven Bend path at
100k rows, but about 2.26 times slower than NimbleCSV. This demonstrates the
value of avoiding row transfer, not a reason to replace NimbleCSV. No peak-RSS
or isolated callback-latency measurement is claimed.

## Deliberately deferred

Only Port supports ask. An export has one callback channel, ask **or** emit,
not both. `ask` is currently a reserved callback parameter name. Multiple
handlers, configurable handler deadlines, NIF callbacks/events and concurrent
native requests are not included. The next useful workload is batched graph
expansion over host-owned data, where Bend decides what data to request.
