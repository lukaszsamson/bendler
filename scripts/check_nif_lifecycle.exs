# MIX_ENV=test mix run scripts/check_nif_lifecycle.exs
# Run destructive module lifecycle checks in a disposable BEAM, guarded by
# the same POSIX launcher used for Port workers.
defmodule Bendler.NifLifecycleCheck do
  @moduledoc false
  @module Bendler.Examples.FibNif

  def run do
    if System.get_env("BENDLER_NIF_LIFECYCLE_CHILD") == "1", do: child(), else: parent()
  end

  defp parent do
    executable = System.find_executable("elixir") || raise "elixir is not on PATH"
    launcher = Bendler.Build.launcher_path(:bendler, "unused")
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    port =
      Port.open({:spawn_executable, launcher}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [executable, "--no-halt" | paths ++ [__ENV__.file]],
        env: [{~c"BENDLER_NIF_LIFECYCLE_CHILD", ~c"1"}]
      ])

    {status, output} = collect(port, System.monotonic_time(:millisecond) + 20_000, [])
    unless status == 0, do: raise("NIF lifecycle child failed (#{status}):\n#{output}")

    for marker <- [
          "initial call passed",
          "upgrade refused",
          "reply after purge",
          "halting normally"
        ] do
      unless output =~ marker, do: raise("missing #{marker}:\n#{output}")
    end

    IO.write(output)
  end

  defp collect(port, deadline, chunks) do
    receive do
      {^port, {:data, data}} ->
        collect(port, deadline, [data | chunks])

      {^port, {:exit_status, status}} ->
        {status, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        raise "NIF lifecycle child timed out"
    end
  end

  defp child do
    Code.ensure_loaded!(@module)
    55 = apply(@module, :fib, [10, 0, 1])
    IO.puts("NIF lifecycle: initial call passed")
    {@module, beam, path} = :code.get_object_code(@module)
    {:error, :on_load_failure} = :code.load_binary(@module, path, beam)
    55 = apply(@module, :fib, [10, 0, 1])
    IO.puts("NIF lifecycle: upgrade refused")

    {sigs, _, _} = Bendler.Sig.parse(File.read!("bend/fib.bend"))
    index = Enum.find_index(sigs, &(&1.name == "slow"))
    sig = Enum.at(sigs, index)
    frame = Bendler.Codec.request(index, Enum.zip([28], Enum.map(sig.params, & &1.type)))
    ref = make_ref()
    {:ok, _handle} = apply(@module, :__bendler_submit, [frame, :infinity, ref])

    receive do
      {:bendler_reply, ^ref, _} -> raise "slow probe finished before purge; increase its workload"
    after
      0 -> :ok
    end

    true = :code.delete(@module)
    true = :code.soft_purge(@module)
    false = :erlang.check_old_code(@module)
    false = Code.loaded?(@module)

    receive do
      {:bendler_reply, ^ref, reply} -> 268_435_456 = Bendler.Codec.reply(reply)
    after
      15_000 -> raise "no native reply after code purge"
    end

    IO.puts("NIF lifecycle: reply after purge")
    IO.puts("NIF lifecycle: halting normally")
    :init.stop()
    # Do not return to the CLI after OTP has begun stopping Elixir's tables.
    Process.sleep(:infinity)
  end
end

Bendler.NifLifecycleCheck.run()
