# MIX_ENV=test mix run demos/csv/check_ask_asan.exs
# External process only: never load an ASan-instrumented NIF into the VM.
alias Bendler.Demos.CsvAskPort

build = Path.join(Bendler.Build.build_scope(:bendler), "bendler_demos_csv_ask_port")
source = File.read!(Path.join(build, "shim.c"))
preserve = "#define PRESERVE(A) __attribute__((A))"
if length(:binary.matches(source, preserve)) != 1, do: raise("unexpected PRESERVE definition")

File.write!(
  Path.join(build, "shim_ask_asan.c"),
  String.replace(source, preserve, "#define PRESERVE(A)")
)

[_, bytes] = Regex.run(~r/^#define (CID_\S*BENDLER_BYTES) \d+$/m, source)
exe = Path.join(build, "ask_asan")

args =
  ~w(-std=c11 -O1 -g -fsanitize=address -fno-omit-frame-pointer -I.) ++
    [
      "-DBENDLER_TRANSPORT=\"bendler_port.h\"",
      "-DBENDLER_CID_BYTES=#{bytes}",
      "shim_ask_asan.c",
      "-o",
      exe,
      "-lpthread",
      "-lm"
    ]

{log, status} = System.cmd(System.get_env("CC", "clang"), args, cd: build, stderr_to_stdout: true)
if status != 0, do: raise("ASan compile failed: #{log}")
System.put_env("ASAN_OPTIONS", "detect_leaks=0:halt_on_error=1:handle_segv=2")
{:ok, owner} = CsvAskPort.start_link(exe: exe, timeout: 30_000)
Process.unlink(owner)

try do
  # A large response forces the input buffer to realloc while the original
  # request is retained. Repeated small responses exercise cursor restoration.
  for size <- [1, 7, 16_384, 65_536] do
    length = if size < 100, do: 128, else: 65_536
    input = :binary.copy("x", length)

    handler = fn {offset, count} ->
      if offset >= byte_size(input),
        do: {:ok, :none},
        else: {:ok, {:some, binary_part(input, offset, min(count, byte_size(input) - offset))}}
    end

    {:ok, {1, 1, ^length}} = CsvAskPort.aggregate(size, 65_536, 100_000, handler)
  end

  {:error, {6, 0, "read failed"}} =
    CsvAskPort.aggregate(100, 100, 10, fn _ -> {:error, "read failed"} end)

  {:ok, {0, 0, 0}} = CsvAskPort.aggregate(100, 100, 10, fn _ -> {:ok, :none} end)
  frame = Bendler.Codec.request(0, [{100, :u32}, {100, :u32}, {10, :u32}])
  {:error, :exited} = Bendler.Port.ask_call(CsvAskPort, frame, fn _ -> <<11, 10, 7, 0, 1>> end)

  IO.puts(
    "CSV ask ASan: repeated callbacks, input realloc, typed errors, reuse and malformed reply passed"
  )
after
  # The malformed-response probe deliberately makes the owner exit; it may
  # finish between an alive? check and stop/1.
  try do
    GenServer.stop(owner)
  catch
    :exit, _ -> :ok
  end
end
