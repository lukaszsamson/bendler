defmodule Bendler.NifAskTest do
  use ExUnit.Case, async: false
  alias Bendler.Demos.CsvAskNif
  alias Bendler.Test.AskNif

  defp isolated(name, timeout \\ 10_000) do
    module = Module.concat(__MODULE__, name)

    Bendler.Build.build!(%{
      module: module,
      app: :bendler,
      source: Path.expand("bend/ask.bend"),
      backend: :nif,
      exports: ["once"],
      name: module |> Module.split() |> Enum.map_join("_", &Macro.underscore/1)
    })

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Bendler,
            otp_app: :bendler,
            source: "bend/ask.bend",
            backend: :nif,
            exports: ["once"],
            timeout: unquote(timeout)
        end
      end
    )

    module
  end

  defp assert_dead(module, attempts \\ 100)
  defp assert_dead(_, 0), do: flunk("abandoned ask did not freeze")

  defp assert_dead(module, attempts) do
    case module.__bendler_submit(<<0::32, 1, 0::32>>, :infinity, make_ref()) do
      {:error, :dead} ->
        :ok

      {:ok, handle} ->
        module.__bendler_cancel(handle)
        Process.sleep(10)
        assert_dead(module, attempts - 1)

      _ ->
        Process.sleep(10)
        assert_dead(module, attempts - 1)
    end
  end

  test "typed callbacks can run repeatedly and return Maybe" do
    assert AskNif.once(41, fn x -> {:some, x + 1} end) == {:some, 42}
    assert AskNif.once(0, fn _ -> :none end) == :none
    assert AskNif.pull(10, fn n -> if n < 5, do: {:some, 1}, else: :none end) == 5
    refute_receive {:bendler_event, _, _, _}
    refute_receive {:bendler_reply, _, _}
  end

  test "same-module reentry is rejected without abandoning a handled ask" do
    assert AskNif.once(7, fn _ ->
             assert_raise Bendler.Error, ~r/own NIF module/, fn ->
               AskNif.once(0, fn _ -> :none end)
             end

             {:some, 7}
           end) == {:some, 7}
  end

  test "CSV callbacks carry tuples, Result, Maybe and arbitrary bytes" do
    csv = "a,b\r\n1,\"two\"\r\n"

    assert CsvAskNif.aggregate(3, 1024, 100, fn {offset, count} ->
             if offset >= byte_size(csv),
               do: {:ok, :none},
               else: {:ok, {:some, binary_part(csv, offset, min(count, byte_size(csv) - offset))}}
           end) == {:ok, {2, 4, 6}}

    assert {:error, _} =
             CsvAskNif.aggregate(3, 1024, 100, fn _ -> {:error, "unavailable"} end)

    assert {:ok, {0, 0, 0}} =
             CsvAskNif.aggregate(3, 1024, 100, fn _ -> {:ok, :none} end)
  end

  test "native replies reject stale sequence, foreign owner and malformed data" do
    frame = Bendler.Codec.request(1, [{42, :u32}], %{})
    ref = make_ref()
    {:ok, handle} = AskNif.__bendler_subscribe(frame, Bendler.Nif.deadline(5000), ref)
    assert_receive {:bendler_event, ^ref, seq, _}, 1000
    assert {:error, :refused} = AskNif.__bendler_answer(handle, seq + 1, <<>>)
    assert {:error, {:invalid, _}} = AskNif.__bendler_answer(handle, seq, <<255>>)

    task =
      Task.async(fn ->
        assert_raise ArgumentError, fn -> AskNif.__bendler_answer(handle, seq, <<>>) end
      end)

    Task.await(task)
    <<_::32, answer::binary>> = Bendler.Codec.request(0, [{:none, {:maybe, :u32}}], %{})
    assert :ok = AskNif.__bendler_answer(handle, seq, answer)
    assert_receive {:bendler_reply, ^ref, reply}, 1000
    assert Bendler.result(reply, :once) == :none
    assert :ok = AskNif.__bendler_cancel(handle)
  end

  test "handler exceptions and invalid return values freeze only their module" do
    for {name, handler} <- [
          {BadHandler, fn _ -> raise "boom" end},
          {BadValue, fn _ -> :wrong end}
        ] do
      module = isolated(name)
      error = assert_raise Bendler.Error, fn -> module.once(0, handler) end
      assert error.reason == :callback
      assert_dead(module)
      assert AskNif.once(1, fn x -> {:some, x} end) == {:some, 1}
    end
  end

  test "total deadline kills the handler and freezes its pending ask" do
    module = isolated(Deadline, 200)
    parent = self()

    error =
      assert_raise Bendler.Error, fn ->
        module.once(0, fn _ ->
          send(parent, {:handler, self()})
          Process.sleep(:infinity)
        end)
      end

    assert error.reason == :timeout
    assert_receive {:handler, handler}
    refute Process.alive?(handler)
    assert_dead(module)
  end

  @tag timeout: 15_000
  test "independent handler deadline applies even with an infinite call deadline" do
    module = isolated(HandlerDeadline, :infinity)

    error =
      assert_raise Bendler.Error, fn -> module.once(0, fn _ -> Process.sleep(:infinity) end) end

    assert error.reason == :callback
    assert_dead(module)
  end

  test "caller death kills its handler and freezes its pending ask" do
    module = isolated(CallerDeath)
    parent = self()

    caller =
      spawn(fn ->
        module.once(0, fn _ ->
          send(parent, {:handler, self()})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:handler, handler}, 1000
    mon = Process.monitor(handler)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^mon, :process, ^handler, _}, 1000
    assert_dead(module)
  end
end
