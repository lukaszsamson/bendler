defmodule Bendler.Demos.CsvStreamTest do
  use ExUnit.Case, async: false

  alias Bendler.Demos.{CsvStream, CsvStreamPort}
  alias Bendler.Demos.CsvStream.Error
  alias NimbleCSV.RFC4180, as: CSV

  setup %{backend: backend} do
    Process.put(:csv_stream_test_backend, backend)
    if backend == :port, do: start_supervised!(CsvStreamPort)
    :ok
  end

  defp stream(chunks, opts \\ []) do
    CsvStream.parse_stream(
      chunks,
      Keyword.put_new(opts, :backend, Process.get(:csv_stream_test_backend))
    )
  end

  defp parse(chunks, opts \\ []) do
    chunks |> stream([skip_headers: false] ++ opts) |> Enum.to_list()
  end

  for backend <- [:port, :nif] do
    describe "#{backend} streaming" do
      @describetag backend: backend

      test "every two-chunk split agrees with NimbleCSV, including partial CRLF and quotes" do
        for input <- [
              "",
              "a,b\r\nc,d",
              "\"first\nline\",\"a\"\"b\"\r\n,\r\n\nlast,",
              "żółć,😺\n日本語,\"x,y\"",
              <<255, 0, 44, 254, 10>>
            ] do
          expected = CSV.parse_string(input, skip_headers: false)

          for cut <- 0..byte_size(input) do
            <<a::binary-size(^cut), b::binary>> = input
            assert parse([a, <<>>, b]) == expected
          end

          assert parse([input], chunk_bytes: 1) == expected
        end
      end

      test "header handling and repeated enumeration are independent" do
        stream = stream(["na", "me,age\nAlice,30\nBob,40"])
        assert Enum.to_list(stream) == [["Alice", "30"], ["Bob", "40"]]
        assert Enum.to_list(stream) == [["Alice", "30"], ["Bob", "40"]]
        assert Enum.to_list(stream(["header only"])) == []
      end

      test "generated tables survive varying chunk sizes" do
        values = ["", "a,b", "\"quoted\"", "multi\nline", "żółć", "\r", <<255, 0>>]

        for n <- 1..20 do
          rows = for i <- 1..n, do: for(j <- 0..3, do: Enum.at(values, rem(i + j + n, 7)))
          csv = rows |> CSV.dump_to_iodata() |> IO.iodata_to_binary()
          assert parse([csv], chunk_bytes: rem(n * 7, 31) + 1) == rows
        end
      end

      test "concurrent enumerations keep separate cursors", %{backend: backend} do
        results =
          1..2
          |> Task.async_stream(
            fn i ->
              ["\"prefix#{i}", "\n", "tail#{i}\",x\n"]
              |> CsvStream.parse_stream(backend: backend, skip_headers: false, chunk_bytes: 3)
              |> Enum.to_list()
            end,
            max_concurrency: 2
          )
          |> Enum.map(fn {:ok, rows} -> rows end)

        assert results == [[["prefix1\ntail1", "x"]], [["prefix2\ntail2", "x"]]]
      end

      test "large partial records are bounded across multiple native calls" do
        field = :binary.copy("x", 65_536)
        assert parse([field], chunk_bytes: 16_384) == [[field]]
        error = assert_raise Error, fn -> parse([field, "x"], chunk_bytes: 16_384) end
        assert {error.code, error.byte_offset} == {5, 65_536}
      end

      test "custom separator and consumer exceptions preserve worker usability" do
        assert parse(["a\t\"b", "\tc\""], separator: "\t") == [["a", "b\tc"]]
        owner = self()

        source =
          Stream.resource(fn -> 0 end, fn n -> {["a,b\n"], n + 1} end, fn _ ->
            send(owner, :consumer_closed)
          end)

        assert_raise RuntimeError, "consumer failed", fn ->
          source |> stream(skip_headers: false) |> Enum.each(fn _ -> raise "consumer failed" end)
        end

        assert_received :consumer_closed
        assert parse(["next"]) == [["next"]]
      end

      test "does not pull input until demanded and closes the source on early halt" do
        owner = self()

        source =
          Stream.resource(
            fn ->
              send(owner, :opened)
              0
            end,
            fn n ->
              send(owner, {:pulled, n})
              {["#{n},x\n"], n + 1}
            end,
            fn _ -> send(owner, :closed) end
          )

        stream = stream(source, skip_headers: false)
        refute_received :opened
        assert Enum.take(stream, 1) == [["0", "x"]]
        assert_received :opened
        assert_received {:pulled, 0}
        refute_received {:pulled, 1}
        assert_received :closed
        assert parse(["still,usable"]) == [["still", "usable"]]
      end

      test "a large source binary is rechunked lazily instead of parsing its tail eagerly" do
        # The tail is invalid: taking the first complete row must not parse it.
        assert ["a\n\"unterminated"]
               |> stream(skip_headers: false, chunk_bytes: 2)
               |> Enum.take(1) == [["a"]]
      end

      test "reports absolute offsets at EOF and after a chunk boundary" do
        for chunks <- [["ok\n\"abc"], ["ok\n", "\"", "abc"]] do
          error = assert_raise Error, fn -> parse(chunks) end
          assert {error.code, error.byte_offset} == {3, 7}
        end

        error = assert_raise Error, fn -> parse(["a,", "b\"bad"]) end
        assert {error.code, error.byte_offset} == {1, 3}
        assert parse(["next,row"]) == [["next", "row"]]
      end

      test "record cap applies across chunks and resets after a completed record" do
        assert parse(["abc\n", "abc\n"], max_record_bytes: 4) == [["abc"], ["abc"]]
        assert parse(["abcd"], max_record_bytes: 4) == [["abcd"]]

        for chunks <- [["abcde"], ["a", "b", "c", "d", "e"]] do
          error = assert_raise Error, fn -> parse(chunks, max_record_bytes: 4) end
          assert {error.code, error.byte_offset} == {5, 4}
        end

        assert_raise Error, fn -> parse(["\"a\nb\""], max_record_bytes: 4) end
      end

      test "slow consumption does not pull or enqueue future batches" do
        owner = self()

        source =
          Stream.map(1..5, fn n ->
            send(owner, {:read, n})
            "#{n}\n"
          end)

        assert source
               |> stream(skip_headers: false)
               |> Enum.reduce(0, fn [n], count ->
                 number = String.to_integer(n)
                 assert_received {:read, ^number}
                 Process.sleep(5)
                 refute_received {:read, _}
                 count + 1
               end) == 5
      end

      test "source failures clean up without poisoning the worker" do
        owner = self()

        source =
          Stream.resource(fn -> :ok end, fn _ -> raise "source failed" end, fn _ ->
            send(owner, :closed)
          end)

        assert_raise RuntimeError, "source failed", fn -> parse(source) end
        assert_received :closed
        assert_raise ArgumentError, fn -> parse([123]) end
        assert parse(["ok"]) == [["ok"]]
      end

      test "validates options before consuming the source" do
        for opts <- [
              [chunk_bytes: 0],
              [chunk_bytes: 65_537],
              [max_record_bytes: 0],
              [separator: "\n"],
              [separator: "ab"],
              [skip_headers: :yes],
              [backend: :unknown],
              [unknown: 1]
            ] do
          assert_raise ArgumentError, fn -> stream([], opts) end
        end
      end
    end
  end
end
