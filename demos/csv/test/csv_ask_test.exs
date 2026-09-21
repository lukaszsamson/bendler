defmodule Bendler.Demos.CsvAskTest do
  use ExUnit.Case, async: false
  alias Bendler.Demos.CsvAskPort

  setup do
    start_supervised!(CsvAskPort)
    :ok
  end

  test "native aggregation agrees with NimbleCSV for chunk boundaries" do
    data = "name,value\r\n\"żółć\",\"a\n\"\"b\"\r\nx,\r\n"
    rows = NimbleCSV.RFC4180.parse_string(data, skip_headers: false)

    expected =
      {length(rows), rows |> List.flatten() |> length(),
       rows |> List.flatten() |> Enum.map(&byte_size/1) |> Enum.sum()}

    for chunk <- [1, 2, 7, 16_384] do
      parent = self()

      assert CsvAskPort.aggregate(chunk, 65_536, 1000, fn {offset, count} ->
               send(parent, {:asked, offset, count})
               read(data, offset, count)
             end) == {:ok, expected}

      assert_receive {:asked, 0, ^chunk}
    end
  end

  test "read errors are typed results and leave the worker reusable" do
    assert CsvAskPort.aggregate(16, 65_536, 10, fn _ -> {:error, "source closed"} end) ==
             {:error, {6, 0, "source closed"}}

    assert CsvAskPort.aggregate(16, 65_536, 10, fn _ -> {:ok, :none} end) == {:ok, {0, 0, 0}}
  end

  test "record limits, syntax errors and callback loops are bounded" do
    assert {:error, {5, 4, _}} =
             CsvAskPort.aggregate(2, 4, 10, fn {o, n} -> read("abcdef", o, n) end)

    assert {:error, {_, _, _}} =
             CsvAskPort.aggregate(2, 100, 10, fn {o, n} -> read("\"open", o, n) end)

    assert {:error, {8, 0, _}} = CsvAskPort.aggregate(2, 100, 3, fn _ -> {:ok, {:some, ""}} end)
  end

  test "file helper closes its device and includes headers" do
    path = Path.join(System.tmp_dir!(), "bendler_ask_#{System.unique_integer([:positive])}.csv")
    File.write!(path, "a,b\n1,22\n")
    on_exit(fn -> File.rm(path) end)
    assert CsvAskPort.aggregate_file(path, chunk_bytes: 1) == {:ok, {2, 4, 5}}
  end

  defp read(data, offset, count) do
    if offset >= byte_size(data),
      do: {:ok, :none},
      else: {:ok, {:some, binary_part(data, offset, min(count, byte_size(data) - offset))}}
  end
end
