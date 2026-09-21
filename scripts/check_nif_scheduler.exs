# MIX_ENV=test mix run scripts/check_nif_scheduler.exs
# Exercise dirty-scheduler starvation in a disposable BEAM. The parent uses
# bendler_launcher so a stalled child is killed with its process group.
defmodule Bendler.NifSchedulerCheck do
  @moduledoc false
  @blocker Bendler.DirtyBlocker
  @boom Bendler.Test.BoomNif

  def run do
    case System.get_env("BENDLER_NIF_SCHEDULER_CHILD") do
      nil -> parent()
      library -> child(library)
    end
  end

  defp parent do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "bendler-nif-scheduler-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    try do
      library = build_blocker!(tmp)
      executable = System.find_executable("elixir") || raise "elixir is not on PATH"
      launcher = Bendler.Build.launcher_path(:bendler, "unused")
      paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

      port =
        Port.open({:spawn_executable, launcher}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [
            executable,
            "--erl",
            "+SDcpu 1",
            "--erl",
            "+S 2" | paths ++ [__ENV__.file]
          ],
          env: [{~c"BENDLER_NIF_SCHEDULER_CHILD", String.to_charlist(library)}]
        ])

      {status, output} = collect(port, System.monotonic_time(:millisecond) + 20_000, [])

      unless status == 0 and output =~ "NIF scheduler: normal busy admission passed" and
               output =~ "NIF scheduler: reserved cleanup passed" do
        raise "NIF scheduler child failed (#{status}):\n#{output}"
      end

      IO.write(output)
    after
      File.rm_rf!(tmp)
    end
  end

  defp build_blocker!(tmp) do
    source = Path.expand("test/fixtures/nif_dirty_blocker.c")
    library = Path.join(tmp, "nif_dirty_blocker")

    include =
      Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "include"])

    platform = if :os.type() == {:unix, :darwin}, do: ["-undefined", "dynamic_lookup"], else: []

    args =
      ["-std=c11", "-O2", "-shared", "-fPIC", "-I#{include}"] ++
        platform ++ [source, "-o", library <> ".so"]

    {output, status} = System.cmd(System.get_env("CC", "clang"), args, stderr_to_stdout: true)
    if status != 0, do: raise("dirty blocker NIF build failed:\n#{output}")
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
        raise "NIF scheduler child timed out"
    end
  end

  defp child(library) do
    define_blocker!(library)
    Code.ensure_loaded!(@boom)
    55 = @boom.fib(10, 0, 1)

    verify_normal_busy_admission()
    verify_reserved_cleanup()
    IO.puts("NIF scheduler: halting normally")
    System.halt(0)
  end

  defp define_blocker!(library) do
    Code.compile_quoted(
      quote do
        defmodule unquote(@blocker) do
          @on_load :load

          def load, do: :erlang.load_nif(unquote(String.to_charlist(library)), 0)
          def sleep_ms(_milliseconds), do: :erlang.nif_error(:not_loaded)
          def started, do: :erlang.nif_error(:not_loaded)
        end
      end
    )

    true = Code.ensure_loaded?(@blocker)
  end

  defp verify_normal_busy_admission do
    slow_ref = make_ref()
    {:ok, _handle} = @boom.__bendler_submit(frame("slow", [28]), :infinity, slow_ref)
    blocker = Task.async(fn -> apply(@blocker, :sleep_ms, [200]) end)
    wait_until(fn -> apply(@blocker, :started, []) end, "dirty blocker did not start")

    started = System.monotonic_time(:millisecond)
    {:error, :busy} = @boom.__bendler_submit(frame("fib", [10, 0, 1]), :infinity, make_ref())
    elapsed = System.monotonic_time(:millisecond) - started
    true = elapsed < 100
    true = apply(@blocker, :started, [])

    :ok = Task.await(blocker, 2_000)

    receive do
      {:bendler_reply, ^slow_ref, reply} -> 268_435_456 = Bendler.Codec.reply(reply, :slow)
    after
      15_000 -> raise "slow request did not complete after dirty scheduler recovered"
    end

    IO.puts("NIF scheduler: normal busy admission passed")
  end

  defp verify_reserved_cleanup do
    blocker = Task.async(fn -> apply(@blocker, :sleep_ms, [500]) end)
    wait_until(fn -> apply(@blocker, :started, []) end, "dirty blocker did not start")
    parent = self()
    ref = make_ref()

    victim =
      spawn(fn ->
        send(parent, {:victim_entered, self()})
        result = @boom.__bendler_submit(frame("fib", [10, 0, 1]), :infinity, ref)
        send(parent, {:victim_returned, result})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {:victim_entered, ^victim} -> :ok
    after
      1_000 -> raise "victim did not enter its submit call"
    end

    wait_until(
      fn ->
        Process.info(victim, :current_function) ==
          {:current_function, {@boom, :__bendler_submit, 3}}
      end,
      "victim did not reach the queued dirty continuation"
    )

    # OTP reports the original submit MFA while its dirty continuation is
    # queued. Saturation proves that the victim actually reserved admission;
    # the blocker still running proves its validation could not have run.
    {:error, :busy} = @boom.__bendler_submit(frame("fib", [10, 0, 1]), :infinity, make_ref())
    true = apply(@blocker, :started, [])
    monitor = Process.monitor(victim)
    Process.exit(victim, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^victim, :killed} -> :ok
    after
      1_000 -> raise "victim did not exit"
    end

    :ok = Task.await(blocker, 2_000)
    :erlang.garbage_collect()

    55 = eventually_fib()
    IO.puts("NIF scheduler: reserved cleanup passed")
  end

  defp eventually_fib(tries \\ 100)
  defp eventually_fib(0), do: raise("reserved admission leaked after caller death")

  defp eventually_fib(tries) do
    @boom.fib(10, 0, 1)
  rescue
    error in Bendler.Error ->
      if error.reason in [:busy, :timeout] do
        Process.sleep(20)
        :erlang.garbage_collect()
        eventually_fib(tries - 1)
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp wait_until(check, message, tries \\ 100)
  defp wait_until(_check, message, 0), do: raise(message)

  defp wait_until(check, message, tries) do
    if check.() do
      :ok
    else
      Process.sleep(5)
      wait_until(check, message, tries - 1)
    end
  end

  defp frame(name, args) do
    {sigs, _, _} = Bendler.Sig.parse(File.read!("bend/fib.bend"))
    sigs = Enum.filter(sigs, &(&1.name in ["square", "fib", "slow"]))
    index = Enum.find_index(sigs, &(&1.name == name))
    sig = Enum.at(sigs, index)
    Bendler.Codec.request(index, Enum.zip(args, Enum.map(sig.params, & &1.type)))
  end
end

Bendler.NifSchedulerCheck.run()
