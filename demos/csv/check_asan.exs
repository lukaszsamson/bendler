# MIX_ENV=test mix run demos/csv/check_asan.exs
# Instruments an external Port executable, never the BEAM or a loaded NIF.
alias Bendler.Test.CompositePort

build =
  Path.expand(
    Path.join([Mix.Project.build_path(), "bendler", "bendler", "bendler_test_composite_port"])
  )

source = File.read!(Path.join(build, "shim.c"))

flags =
  Enum.map(~w(BYTES DU DF DN DS DB DL DK), fn name ->
    [_, cid] = Regex.run(~r/^#define (CID_\S*BENDLER_#{name}) \d+$/m, source)
    "-DBENDLER_CID_#{name}=#{cid}"
  end)

exe = Path.join(build, "composite_asan")

args =
  [
    "-std=c11",
    "-O1",
    "-g",
    "-fsanitize=address",
    "-fno-omit-frame-pointer",
    "-I.",
    "-DBENDLER_TRANSPORT=\"bendler_port.h\"",
    "shim.c",
    "-o",
    exe,
    "-lpthread",
    "-lm"
  ] ++ flags

{output, status} =
  System.cmd(System.get_env("CC", "clang"), args, cd: build, stderr_to_stdout: true)

if status != 0, do: raise("sanitizer build failed: #{output}")
System.put_env("ASAN_OPTIONS", "detect_leaks=0:halt_on_error=1:handle_segv=2")
{:ok, pid} = CompositePort.start_link(exe: exe, threads: 1)

try do
  for cycle <- 1..100 do
    if cycle == 1, do: IO.puts("ASan: Base composites")
    [] = CompositePort.empty([])
    {:some, :none} = CompositePort.optional({:some, :none})
    {:error, {7, "bad"}} = CompositePort.result({:error, {7, "bad"}})
    {1, "a", true} = CompositePort.triple({1, "a", true})
    bytes = {:some, {:ok, {<<0, 255>>, {:some, <<>>}}}}
    ^bytes = CompositePort.blob(bytes)
    if cycle == 1, do: IO.puts("ASan: Dyn record")
    record = {:rec, :dot, <<0, 255>>, [{"f", 1.5}], {:some, {:error, ?x}}}
    ^record = CompositePort.rec_echo(record)
    if cycle == 1, do: IO.puts("ASan: recursive Dyn list")
    300 = CompositePort.lst_len(Enum.reduce(1..300, :l_nil, fn _, tail -> {:l_cons, 1, tail} end))
    frame = Bendler.Port.call(CompositePort, <<0::32, 8, 2, 1, 0::32>>)
    {{:error, _}, ""} = Bendler.Codec.decode(frame)
  end

  {sigs, _, _} = Bendler.Sig.parse(File.read!("bend/composite.bend"))
  index = Enum.find_index(sigs, &(&1.name == "area"))

  for frame <- [<<index::32, 15, 255, 0>>, <<index::32, 15, 0, 0>>] do
    {{:error, _}, ""} = CompositePort |> Bendler.Port.call(frame) |> Bendler.Codec.decode()
  end

  IO.puts(
    "ASan: 100 composite round-trip and malformed-frame cycles passed (leak detection disabled)"
  )
after
  GenServer.stop(pid)
end
