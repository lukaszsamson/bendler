# MIX_ENV=test mix run scripts/check_nif_init.exs
# Fault injection uses a separate library and a disposable BEAM, never a
# replacement for a production artifact that might already be loaded.
defmodule Bendler.NifInitCheck do
  @moduledoc false
  @probe Bendler.NifInitProbe

  def run do
    case System.get_env("BENDLER_NIF_INIT_PROBE") do
      nil -> parent()
      path -> child(path)
    end
  end

  defp parent do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "bendler-init-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    try do
      for mode <- [1, 2] do
        library = build_probe(tmp, mode)
        executable = System.find_executable("elixir") || raise "elixir is not on PATH"
        paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

        port =
          Port.open({:spawn_executable, Bendler.Build.launcher_path(:bendler, "unused")}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [executable | paths ++ [__ENV__.file]],
            env: [{~c"BENDLER_NIF_INIT_PROBE", String.to_charlist(library)}]
          ])

        {status, output} = collect(port, System.monotonic_time(:millisecond) + 15_000, [])

        unless status == 0 and output =~ "NIF init: failure rejected" do
          raise "initialization probe failed (#{status}):\n#{output}"
        end

        IO.write(output)
      end
    after
      File.rm_rf!(tmp)
    end
  end

  defp build_probe(tmp, mode) do
    build = Path.join(Bendler.Build.build_scope(:bendler), "bendler_examples_fib_nif")
    source = File.read!(Path.join(build, "shim_nif.c"))
    glue = File.read!("priv/c/bendler_nif_glue.c") |> Bendler.Gen.nif_glue(@probe)
    glue_path = Path.join(tmp, "glue.c")
    File.write!(glue_path, glue)
    library = Path.join(tmp, "init_failure_#{mode}")

    include =
      Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "include"])

    platform = if :os.type() == {:unix, :darwin}, do: ["-undefined", "dynamic_lookup"], else: []

    ids =
      Enum.flat_map(~w(BYTES DU DF DN DS DB DL DK), fn name ->
        case Regex.run(~r/^#define (CID_\S*BENDLER_#{name}) \d+$/m, source) do
          [_, cid] -> ["-DBENDLER_CID_#{name}=#{cid}"]
          nil -> []
        end
      end)

    args =
      [
        "-std=c11",
        "-O1",
        "-shared",
        "-fPIC",
        "-I#{build}",
        "-I#{include}",
        "-DBENDLER_TRANSPORT=\"bendler_nif.h\"",
        "-DBENDLER_TEST_INIT_FAILURE=#{mode}"
      ] ++
        ids ++
        platform ++
        [Path.join(build, "shim_nif.c"), glue_path, "-o", library <> ".so", "-lpthread", "-lm"]

    {output, status} = System.cmd(System.get_env("CC", "clang"), args, stderr_to_stdout: true)
    if status != 0, do: raise("fault-injected NIF build failed:\n#{output}")
    library
  end

  defp collect(port, deadline, chunks) do
    receive do
      {^port, {:data, chunk}} ->
        collect(port, deadline, [chunk | chunks])

      {^port, {:exit_status, status}} ->
        {status, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        raise "initialization child timed out"
    end
  end

  defp child(path) do
    Process.register(self(), :bendler_init_probe_owner)

    Code.compile_quoted(
      quote do
        defmodule unquote(@probe) do
          @on_load :load
          def load do
            result =
              with :ok <- :erlang.load_nif(unquote(String.to_charlist(path)), {1, 1, 1}) do
                __bendler_init__()
              end

            send(Process.whereis(:bendler_init_probe_owner), {:probe_init, result})
            result
          end

          def __bendler_init__, do: :erlang.nif_error(:not_loaded)
          def __bendler_submit(_, _, _), do: :erlang.nif_error(:not_loaded)
          def __bendler_subscribe(_, _, _), do: :erlang.nif_error(:not_loaded)
          def __bendler_ack(_, _, _), do: :erlang.nif_error(:not_loaded)
          def __bendler_answer(_, _, _), do: :erlang.nif_error(:not_loaded)
          def __bendler_cancel(_), do: :erlang.nif_error(:not_loaded)
        end
      end
    )

    receive do
      {:probe_init, {:error, :init_failed}} -> :ok
      {:probe_init, other} -> raise "expected checked init failure, got #{inspect(other)}"
    after
      5_000 -> raise "initialization did not return"
    end

    false = Code.loaded?(@probe)
    IO.puts("NIF init: failure rejected")
  end
end

Bendler.NifInitCheck.run()
