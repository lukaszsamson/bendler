# MIX_ENV=test mix run demos/csv/check_asan.exs
# Instruments an external Port executable, never the BEAM or a loaded NIF.
alias Bendler.Test.CompositePort

build =
  Path.expand(
    Path.join([Mix.Project.build_path(), "bendler", "bendler", "bendler_test_composite_port"])
  )

source = File.read!(Path.join(build, "shim.c"))
[_, cid] = Regex.run(~r/^#define (CID_\S*BENDLER_BYTES) \d+$/m, source)
exe = Path.join(build, "composite_asan")

args = [
  "-std=c11",
  "-O1",
  "-g",
  "-fsanitize=address",
  "-fno-omit-frame-pointer",
  "-I.",
  "-DBENDLER_TRANSPORT=\"bendler_port.h\"",
  "-DBENDLER_CID_BYTES=#{cid}",
  "shim.c",
  "-o",
  exe,
  "-lpthread",
  "-lm"
]

{output, status} =
  System.cmd(System.get_env("CC", "clang"), args, cd: build, stderr_to_stdout: true)

if status != 0, do: raise("sanitizer build failed: #{output}")
System.put_env("ASAN_OPTIONS", "detect_leaks=0:halt_on_error=1")
{:ok, pid} = CompositePort.start_link(exe: exe, threads: 1)

try do
  for _ <- 1..100 do
    [] = CompositePort.empty([])
    {:some, :none} = CompositePort.optional({:some, :none})
    {:error, {7, "bad"}} = CompositePort.result({:error, {7, "bad"}})
    {1, "a", true} = CompositePort.triple({1, "a", true})
    bytes = {:some, {:ok, {<<0, 255>>, {:some, <<>>}}}}
    ^bytes = CompositePort.blob(bytes)
    frame = Bendler.Port.call(CompositePort, <<0::32, 8, 2, 1, 0::32>>)
    {{:error, _}, ""} = Bendler.Codec.decode(frame)
  end

  IO.puts(
    "ASan: 100 composite round-trip and malformed-frame cycles passed (leak detection disabled)"
  )
after
  GenServer.stop(pid)
end
