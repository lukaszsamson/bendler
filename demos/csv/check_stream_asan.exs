# MIX_ENV=test mix run demos/csv/check_stream_asan.exs
# Instruments the external Port, never a NIF loaded in the VM.
alias Bendler.Demos.{CsvStream, CsvStreamPort}
alias NimbleCSV.RFC4180, as: CSV

build = Path.join(Bendler.Build.build_scope(:bendler), "bendler_demos_csv_stream_port")
source = File.read!(Path.join(build, "shim.c"))
preserve = "#define PRESERVE(A) __attribute__((A))"

if length(:binary.matches(source, preserve)) != 1,
  do: raise("unexpected Bend PRESERVE definition")

# Same instrumented platform-ABI workaround as check_asan.exs.
File.write!(
  Path.join(build, "shim_stream_asan.c"),
  String.replace(source, preserve, "#define PRESERVE(A)")
)

[_, bytes] = Regex.run(~r/^#define (CID_\S*BENDLER_BYTES) \d+$/m, source)
exe = Path.join(build, "stream_asan")

args =
  ~w(-std=c11 -O1 -g -fsanitize=address -fno-omit-frame-pointer -I.) ++
    [
      "-DBENDLER_TRANSPORT=\"bendler_port.h\"",
      "-DBENDLER_CID_BYTES=#{bytes}",
      "shim_stream_asan.c",
      "-o",
      exe,
      "-lpthread",
      "-lm"
    ]

{log, code} = System.cmd(System.get_env("CC", "clang"), args, cd: build, stderr_to_stdout: true)
if code != 0, do: raise("ASan compilation failed: #{log}")
System.put_env("ASAN_OPTIONS", "detect_leaks=0:halt_on_error=1:handle_segv=2")
{:ok, port} = CsvStreamPort.start_link(exe: exe, timeout: 30_000)
Process.unlink(port)

try do
  rows = [["", "a,\"b", "line\nżółć"], [<<255, 0>>, "", "last"]]
  input = rows |> CSV.dump_to_iodata() |> IO.iodata_to_binary()

  IO.puts("CSV stream ASan: partitioned records")

  for _ <- 1..50, size <- [1, 7, 64] do
    ^rows =
      [input] |> CsvStream.parse_stream(skip_headers: false, chunk_bytes: size) |> Enum.to_list()
  end

  field = :binary.copy("x", 65_536)
  IO.puts("CSV stream ASan: maximum record")
  [[^field]] = [field] |> CsvStream.parse_stream(skip_headers: false) |> Enum.to_list()

  IO.puts("CSV stream ASan: errors and recovery")

  for chunks <- [["\"", "unfinished"], ["ab", "\""], [field, "x"]] do
    try do
      chunks |> CsvStream.parse_stream(skip_headers: false) |> Enum.to_list()
      raise "expected a parser error"
    rescue
      Bendler.Demos.CsvStream.Error -> :ok
    end
  end

  [["ok"]] = ["ok"] |> CsvStream.parse_stream(skip_headers: false) |> Enum.to_list()

  IO.puts(
    "CSV stream ASan: 150 partitioned round trips, maximum record and error recovery passed"
  )
after
  if Process.alive?(port), do: GenServer.stop(port)
end
