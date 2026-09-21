defmodule Bendler.LauncherTest do
  use ExUnit.Case, async: false

  setup_all do
    dir = Path.join(System.tmp_dir!(), "bendler-launcher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for {src, name, flags} <- [
          {"priv/c/bendler_launcher.c", "bendler_launcher", []},
          {"test/fixtures/closing_worker.c", "closing_worker", []},
          {"test/fixtures/delayed_launcher.c", "delayed_launcher", []},
          {"test/fixtures/stubborn_worker.c", "worker", []},
          {"test/fixtures/stubborn_worker.c", "descendant_worker", ["-DDESCENDANT"]}
        ] do
      {log, status} =
        System.cmd(
          "clang",
          ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", src, "-o", Path.join(dir, name)] ++
            flags,
          stderr_to_stdout: true
        )

      assert status == 0, log
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, exe: Path.join(dir, "worker")}
  end

  test "deadline kills and reaps a worker that ignores TERM and never checks IO", %{exe: exe} do
    owner =
      start_supervised!(
        {Bendler.Port, name: :launcher_timeout, exe: exe, threads: 1, timeout: 100}
      )

    <<worker::32>> = Bendler.Port.call(:launcher_timeout, <<>>)
    ref = Process.monitor(owner)
    assert Bendler.Port.call(:launcher_timeout, <<>>) == {:error, :timeout}
    assert_receive {:DOWN, ^ref, :process, ^owner, {:shutdown, :timeout}}, 1000
    assert_gone(worker)
  end

  test "untrappable owner death still kills and reaps the worker", %{exe: exe} do
    {:ok, owner} = Bendler.Port.start_link(name: :launcher_killed, exe: exe, threads: 1)
    Process.unlink(owner)
    <<worker::32>> = Bendler.Port.call(:launcher_killed, <<>>)
    caller = Task.async(fn -> Bendler.Port.call(:launcher_killed, <<>>) end)
    # Ordering through the owner confirms the call has been admitted.
    wait_inflight(owner)
    Process.exit(owner, :kill)
    assert Task.await(caller, 1000) == {:error, :exited}
    assert_gone(worker)
  end

  defp wait_inflight(owner, tries \\ 100) do
    case :sys.get_state(owner).inflight do
      nil when tries > 0 ->
        Process.sleep(5)
        wait_inflight(owner, tries - 1)

      nil ->
        flunk("request never entered flight")

      _ ->
        :ok
    end
  end

  test "exited group leader cannot leave a descendant holding stdout open", %{exe: exe} do
    dir = Path.dirname(exe)

    port =
      Port.open({:spawn_executable, Path.join(dir, "bendler_launcher")}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: [Path.join(dir, "descendant_worker")]
      ])

    try do
      assert Port.command(port, <<>>)
      assert_receive {^port, {:data, <<descendant::32>>}}, 1000
      assert_receive {^port, {:exit_status, 0}}, 3000
      assert_gone(descendant)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp assert_gone(pid, tries \\ 100) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, status} when status != 0 ->
        :ok

      _ when tries > 0 ->
        Process.sleep(20)
        assert_gone(pid, tries - 1)

      _ ->
        flunk("worker #{pid} survived or was not reaped")
    end
  end

  test "preserves worker exit status when input closes with relay bytes pending", %{exe: exe} do
    dir = Path.dirname(exe)

    port =
      Port.open({:spawn_executable, Path.join(dir, "delayed_launcher")}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: [Path.join(dir, "closing_worker")]
      ])

    try do
      assert_receive {^port, {:data, <<1>>}}, 1000
      assert Port.command(port, :binary.copy(<<0>>, 1024))
      assert_receive {^port, {:data, <<2>>}}, 3000
      assert_receive {^port, {:exit_status, 65}}, 3000
    after
      if Port.info(port), do: Port.close(port)
    end
  end
end
