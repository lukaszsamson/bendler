defmodule Bendler.Demos.MandelbrotTest do
  use ExUnit.Case, async: false
  alias Bendler.Demos.{MandelbrotPort, MandelbrotReference}

  for threads <- [1, 4] do
    @threads threads
    test "upstream known answer and differential checks with #{threads} threads" do
      start_supervised!({MandelbrotPort, threads: @threads})
      assert MandelbrotPort.checksum(2, 7) == 887_240_761
      assert MandelbrotReference.checksum(2, 7) == 887_240_761

      for {depth, iterations} <- [{0, 1}, {0, 17}, {3, 7}, {6, 31}] do
        assert MandelbrotPort.checksum(depth, iterations) ==
                 MandelbrotReference.checksum(depth, iterations)
      end
    end
  end

  test "pixels cover exterior, interior and boundary points throughout the viewport" do
    start_supervised!({MandelbrotPort, threads: 2})
    :rand.seed(:exsss, {91, 22, 83})
    ids = [0, 4095, 2048 * 4096 + 2730, 4096 * 4096 - 1]
    ids = ids ++ Enum.map(1..48, fn _ -> :rand.uniform(4096 * 4096) - 1 end)

    for id <- ids, iterations <- [0, 1, 7, 51] do
      assert MandelbrotPort.pix(id, iterations) == MandelbrotReference.pixel(id, iterations)
    end
  end

  test "public wrapper rejects invalid and unbounded workloads before sending" do
    for args <- [{-1, 7}, {19, 7}, {2, 0}, {2, 4097}, {2.0, 7}] do
      assert_raise ArgumentError, fn -> apply(MandelbrotPort, :checksum, Tuple.to_list(args)) end
    end
  end

  @tag timeout: 60_000
  test "full upstream 4096x4096 viewport known answer" do
    start_supervised!({MandelbrotPort, threads: 4})
    assert MandelbrotPort.checksum(18, 51) == 3_101_455_856
  end
end
