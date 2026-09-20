defmodule Bendler.Demos.CsvTest do
  use ExUnit.Case, async: false
  alias Bendler.Demos.CsvPort
  alias NimbleCSV.RFC4180, as: CSV
  NimbleCSV.define(TSV, separator: "\t", escape: "\"")

  setup do
    start_supervised!({CsvPort, []})
    :ok
  end

  test "NimbleCSV eager parsing fixtures, exact bytes and both header policies" do
    for input <- [
          "",
          "\n",
          "\n\n",
          ",",
          ",\n",
          "a,b,",
          "a,b\r\n1,2\r\n",
          "a\rb,c",
          "name,last,year\njohn,doe,1986\n",
          " a , b \n",
          "\"\"",
          "\"a,b\",\"x\"\"y\"\n",
          "\"a\nb\",c",
          "\"a\r\nb\",c",
          "\"a\r\"\n",
          "zażółć,你好\n",
          <<255, 0, 44, 128, 10>>
        ],
        skip <- [true, false] do
      assert CsvPort.parse_string(input, skip_headers: skip) ==
               {:ok, CSV.parse_string(input, skip_headers: skip)}
    end

    assert CsvPort.parse_csv("a,b\nc,d", :none) == {:ok, {[["a", "b"], ["c", "d"]], 2}}
    input = "a\tb\r\n\"x\ty\"\tz"

    assert CsvPort.parse_string(input, separator: "\t", skip_headers: false) ==
             {:ok, TSV.parse_string(input, skip_headers: false)}
  end

  test "malformed quotes return structured Result failures and do not kill the port" do
    for {input, code, offset} <- [
          {"a\"b", 1, 1},
          {"\"a\"x", 2, 3},
          {"\"abc", 3, 4},
          {"\"a\"\rx", 2, 4}
        ] do
      assert_raise NimbleCSV.ParseError, fn -> CSV.parse_string(input, skip_headers: false) end
      assert {:error, {^code, ^offset, msg}} = CsvPort.parse_string(input, skip_headers: false)
      assert is_binary(msg)
      assert CsvPort.parse_string("ok", skip_headers: false) == {:ok, [["ok"]]}
    end

    for sep <- [10, 13, 34, 256],
        do: assert({:error, {4, 0, _}} = CsvPort.parse_csv("x", {:some, sep}))
  end

  test "differential generated CSV using NimbleCSV's dumper" do
    :rand.seed(:exsss, {73, 44, 12})
    fields = ["", "plain", "a,b", "\"quoted\"", "line\nline", "line\r\nline", " λ ", <<0, 255>>]

    for _ <- 1..40 do
      rows =
        for _ <- 1..:rand.uniform(8),
            do:
              for(
                _ <- 1..:rand.uniform(5),
                do: Enum.at(fields, :rand.uniform(length(fields)) - 1)
              )

      csv = rows |> CSV.dump_to_iodata() |> IO.iodata_to_binary()
      assert CsvPort.parse_string(csv, skip_headers: false) == {:ok, rows}
      assert CSV.parse_string(csv, skip_headers: false) == rows
    end
  end

  test "wrapper validates options and input budget" do
    assert_raise ArgumentError, fn -> CsvPort.parse_string(:bad) end
    assert_raise ArgumentError, fn -> CsvPort.parse_string(:binary.copy("x", 1_048_577)) end
    assert_raise ArgumentError, fn -> CsvPort.parse_string("x", separator: "||") end
    assert_raise ArgumentError, fn -> CsvPort.parse_string("x", skip_headers: :yes) end
  end

  test "all short combinations of quote, delimiter, CR, LF and a field byte" do
    inputs =
      Enum.reduce(1..4, [""], fn _, previous ->
        ["" | for(prefix <- previous, byte <- [34, 44, 13, 10, 97], do: prefix <> <<byte>>)]
      end)
      |> Enum.uniq()

    for input <- inputs do
      reference =
        try do
          {:ok, CSV.parse_string(input, skip_headers: false)}
        rescue
          NimbleCSV.ParseError -> :invalid
        end

      actual = CsvPort.parse_string(input, skip_headers: false)

      case reference do
        :invalid -> assert match?({:error, _}, actual), inspect(input)
        valid -> assert actual == valid, inspect(input)
      end
    end
  end
end
