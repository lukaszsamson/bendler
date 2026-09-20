defmodule BendlerTest do
  use ExUnit.Case, async: false

  alias Bendler.{Codec, Sig}
  alias Bendler.Examples.{FibNif, FibPort}
  alias Bendler.Test.{BoomNif, QueueNif, SlowPort}

  @fibs [1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987]

  defp eventually(check, tries \\ 100) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(check, tries - 1)
    end
  end

  defp reason(fun) do
    fun.()
  rescue
    e in Bendler.Error -> e.reason
  end

  describe "Sig.parse/1" do
    test "reads the exportable defs and skips the rest" do
      {sigs, skipped, _} = Sig.parse(File.read!("bend/fib.bend"))

      assert Enum.map(sigs, & &1.name) ==
               ~w(fib sum shout range is_big square pow2 words nest slow byte_sum.go byte_sum rev_bytes second_byte.fin second_byte)

      assert Enum.find(sigs, &(&1.name == "rev_bytes")).ret == {:bytes, "B.Bytes"}
      assert skipped == []

      assert [%{type: {:tuple, [:bytes, :u32]}}] =
               Enum.find(sigs, &(&1.name == "second_byte.fin")).params

      {sigs, skipped, _} =
        Sig.parse("""
        def id(-A: Type, x: A) -> A:
          x
        def main() -> IO(Unit):
          IO.print("hi")
        def ok(x: U32) -> IO(U32):
          IO.pure(U32, x)
        def lists(xs: List<&2, List<String>>) -> +List<U32>:   # a comment
          []
        def multi(
          x: U32) -> U32:
          x
        """)

      assert [
               %Sig{
                 name: "lists",
                 params: [%{type: {:list, {:list, :string}}}],
                 ret: {{:list, :u32}, "+List<U32>"}
               }
             ] = sigs

      assert [
               {"id", "erased parameter A"},
               {"main", _},
               {"ok", "unsupported type IO(U32)"},
               {"multi", _}
             ] = skipped

      assert_raise Bendler.Error, ~r/would all become a_b/, fn ->
        Sig.parse("def a.b(x: U32) -> U32:\n  x\ndef a_b(x: U32) -> U32:\n  x\n")
      end
    end
  end

  describe "Codec" do
    test "round-trips every type" do
      for {v, t} <- [
            {7, :u32},
            {2 ** 40, :nat},
            {"zażółć", :string},
            {true, :bool},
            {:unit, :unit},
            {[[1], [], [2, 3]], {:list, {:list, :u32}}}
          ] do
        assert {^v, ""} = Codec.decode(Codec.encode(v, t))
      end
    end

    test "rejects values outside a type" do
      assert_raise ArgumentError, ~r/U32/, fn -> Codec.encode(-1, :u32) end
      assert_raise ArgumentError, ~r/U32/, fn -> Codec.encode(2 ** 32, :u32) end
      assert_raise ArgumentError, ~r/Nat/, fn -> Codec.encode(2 ** 48, :nat) end
      not_a_bool = Enum.random(["x", "y"])
      assert_raise ArgumentError, fn -> Codec.encode(not_a_bool, :bool) end
      assert_raise ArgumentError, fn -> Codec.encode([1, "a"], {:list, :u32}) end
    end

    test "rejects a list count past the binary and error frames carry a message" do
      assert_raise Bendler.Error, ~r/malformed/, fn ->
        Codec.decode(<<6, 1000::32, 1, 0, 0, 0, 1>>)
      end

      assert_raise Bendler.Error, ~r/refused.*nope/, fn -> Codec.reply(<<0, 4::32, "nope">>) end
    end
  end

  describe "NIF backend" do
    test "generates one function per export with docs" do
      Code.ensure_loaded!(FibNif)
      assert function_exported?(FibNif, :fib, 3)
      assert function_exported?(FibNif, :words, 1)
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(FibNif)

      assert Enum.any?(docs, fn
               {{:function, :fib, 3}, _, _, %{"en" => d}, _} ->
                 d =~ "def fib(n: Nat, a: U32, +b: U32) -> U32"

               _ ->
                 false
             end)
    end

    test "calls through every marshalled type" do
      assert FibNif.fib(30, 0, 1) == 832_040
      assert FibNif.sum([1, 2, 3, 4], 100) == 110
      assert FibNif.shout("hello zażółć") == "hello zażółć!"
      assert FibNif.range(10, []) == Enum.to_list(0..9)
      assert FibNif.is_big(5000) == true
      assert FibNif.is_big(5) == false
      assert FibNif.square(2 ** 20) == 2 ** 40
      assert FibNif.words("a bb  ccc") == ["a", "bb", "", "ccc"]
    end

    test "Bytes cross as binaries backed by a buffer block" do
      assert FibNif.byte_sum(<<1, 2, 3, 250>>) == 256
      assert FibNif.rev_bytes("hello") == "olleh"
      assert FibNif.rev_bytes("") == ""
      assert FibNif.second_byte(<<9, 42, 7>>) == 42
      big = :crypto.strong_rand_bytes(100_000)
      assert FibNif.rev_bytes(big) == :binary.list_to_bin(Enum.reverse(:binary.bin_to_list(big)))
      assert FibNif.byte_sum(big) == Enum.sum(:binary.bin_to_list(big))
      assert_raise ArgumentError, fn -> FibNif.byte_sum([1, 2]) end
    end

    test "round-trips empty and nested lists through the native codec" do
      assert FibNif.nest([]) == []
      assert FibNif.nest([[], [1], [], [2, 3]]) == [[], [1], [], [2, 3]]
      assert FibNif.words("") == [""]
    end

    test "runs a parallel call on every core" do
      assert FibNif.pow2(20) == 1_048_576
    end

    test "checks arguments on the Elixir side" do
      assert_raise ArgumentError, fn -> FibNif.fib(-1, 0, 1) end
      assert_raise ArgumentError, fn -> FibNif.shout(:atom) end
    end

    test "serialises concurrent callers within max_waiting, then says busy" do
      results =
        1..16
        |> Task.async_stream(fn i -> {i, FibNif.fib(i, 0, 1)} end, max_concurrency: 4)
        |> Enum.map(fn {:ok, r} -> r end)

      assert results == Enum.map(1..16, &{&1, Enum.at(@fibs, &1 - 1)})

      # past the limit (default 4 waiting plus one in flight) callers are
      # refused at once instead of piling onto dirty scheduler threads
      outcomes =
        1..32
        |> Task.async_stream(fn _ -> reason(fn -> FibNif.slow(24) end) end,
          max_concurrency: 32,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert 16_777_216 in outcomes
      assert :busy in outcomes
    end

    test "a request withdrawn before pick-up leaves no stale wake-up behind" do
      # t1 is in flight; t2 posts to the mailbox, is never taken in time, and withdraws
      t1 = Task.async(fn -> reason(fn -> QueueNif.slow(28) end) end)
      Process.sleep(20)
      t2 = Task.async(fn -> reason(fn -> QueueNif.slow(28) end) end)
      assert Task.await(t1, 5_000) == :timeout
      assert Task.await(t2, 5_000) == :timeout
      # once the abandoned work finishes, the loop parks cleanly and serves again
      assert eventually(fn -> reason(fn -> QueueNif.fib(10, 0, 1) end) == 55 end)
      assert QueueNif.fib(20, 0, 1) == 6765
    end

    test "a deadline abandons the request; a runtime error freezes that runtime, not the VM" do
      assert reason(fn -> BoomNif.slow(28) end) == :timeout
      # the abandoned request still occupies the runtime until it finishes
      assert eventually(fn -> reason(fn -> BoomNif.fib(10, 0, 1) end) == 55 end)

      # 2^47 squared overflows a Nat: the runtime reports and exits, which bendler turns into a frozen runtime
      assert reason(fn -> BoomNif.square(2 ** 47) end) == :dead
      assert reason(fn -> BoomNif.fib(10, 0, 1) end) == :dead
      # the other runtime is untouched
      assert FibNif.fib(10, 0, 1) == 55
    end
  end

  describe "port backend" do
    setup do
      %{pid: start_supervised!({FibPort, []})}
    end

    test "calls through the port" do
      assert FibPort.rev_bytes(<<1, 2, 3>>) == <<3, 2, 1>>
      assert FibPort.fib(30, 0, 1) == 832_040
      assert FibPort.words("x y") == ["x", "y"]
      assert FibPort.range(5, [9]) == [0, 1, 2, 3, 4, 9]
      assert FibPort.pow2(16) == 65_536
      assert FibPort.nest([[], [7]]) == [[], [7]]
    end

    test "serialises concurrent callers" do
      results =
        1..8 |> Task.async_stream(&FibPort.fib(&1, 0, 1)) |> Enum.map(fn {:ok, r} -> r end)

      assert results == Enum.take(@fibs, 8)
    end
  end

  describe "port admission and deadline" do
    test "a full queue says busy; a missed deadline stops the owner and a supervisor replaces it" do
      pid = start_supervised!({SlowPort, []})
      ref = Process.monitor(pid)
      # one in flight, one queued (max_queue: 1), the third is refused
      t1 = Task.async(fn -> reason(fn -> SlowPort.slow(30) end) end)
      Process.sleep(20)
      t2 = Task.async(fn -> reason(fn -> SlowPort.slow(30) end) end)
      Process.sleep(20)
      assert reason(fn -> SlowPort.slow(30) end) == :busy
      assert Task.await(t1, 5_000) == :timeout
      assert Task.await(t2, 5_000) == :exited
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :timeout}}, 1_000
      # the supervisor restarted it under the same name
      Process.sleep(50)
      assert SlowPort.fib(10, 0, 1) == 55
    end

    test "an invalid request is refused before the def runs, and the worker lives on" do
      start_supervised!({SlowPort, []})
      # function 0 (slow) with a U32 where a Nat is declared
      assert {{:error, "expected a Nat"}, ""} =
               Bendler.Codec.decode(Bendler.Port.call(SlowPort, <<0::32, 1, 0, 0, 0, 1>>))

      assert {{:error, "trailing bytes in the request"}, ""} =
               Bendler.Codec.decode(
                 Bendler.Port.call(SlowPort, <<1::32, 2, 10::64, 1, 0::32, 1, 1::32, 0>>)
               )

      assert {{:error, "unknown function index"}, ""} =
               Bendler.Codec.decode(Bendler.Port.call(SlowPort, <<99::32>>))

      assert SlowPort.fib(10, 0, 1) == 55
    end

    test "the NIF refuses an invalid request on the calling thread" do
      assert {:error, {:invalid, ~c"expected a Nat"}} =
               FibNif.__bendler_call(<<0::32, 1, 0, 0, 0, 1>>, -1)

      assert {:error, {:invalid, ~c"list count past the request"}} =
               FibNif.__bendler_call(<<1::32, 6, 1000::32, 1, 0::32>>, -1)

      assert_raise Bendler.Error, ~r/refused/, fn ->
        # Enum.at hides the shape from the type checker, which sees only the binary clause
        Bendler.result(Enum.at([{:error, {:invalid, ~c"x"}}], 0), :f)
      end
    end

    test "queued callers are released when the port dies" do
      pid = start_supervised!({SlowPort, []})
      ref = Process.monitor(pid)
      t1 = Task.async(fn -> reason(fn -> SlowPort.slow(30) end) end)
      Process.sleep(20)
      t2 = Task.async(fn -> reason(fn -> SlowPort.slow(30) end) end)
      Process.sleep(20)
      Port.close(:sys.get_state(pid).port)
      assert Task.await(t1, 5_000) == :exited
      assert Task.await(t2, 5_000) == :exited
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end
  end
end
