defmodule Bendler.Codec do
  @moduledoc """
  The binary codec between Elixir and a Bend program. Every value is a tag
  byte and a big-endian payload; a request is a function index and its
  arguments; a reply is one value, or the error tag.

      0 error (len32 + message)  1 U32 (4 bytes)  2 Nat (8 bytes, < 2^48)
      3 String (len32)           4 Bool (1 byte)  5 Unit
      6 List (count32, then the items)  7 Bytes (len32, raw bytes)
      8 Tuple (arity8, then fields)    9 None    10 Some (value)
      11 Done (value)                  12 Fail (error)
      13 F32 (4 bytes, IEEE bits)      14 Char (4 bytes, a code point)
      15 Data (constructor8, count8, then fields)

  A Result's Fail is returned as `{:error, value}`; only tag 0 raises a
  transport error. Type expressions may nest up to 32 levels; values up to 2048.

  An `F32` takes an Elixir float, rounded to the nearest single; a float
  past the single range raises `ArgumentError`. The atoms `:nan`,
  `:infinity` and `:neg_infinity` cross both ways, since the BEAM has no
  such floats. A `Char` is a code point, 0..0x10FFFF without surrogates.
  A `Map<V>` is an Elixir map with valid UTF-8 binary keys; on the wire it is a list of
  `String & V` pairs. A user datatype is a tagged tuple, `{:circle, r}`, or
  the bare atom of a constructor without fields; the wire form names the
  constructor by index, so encoding and checking take the `types` table
  (`Bendler.Sig.codec_types/1`). Values nest up to #{2048} levels.
  """

  @typedoc "Per user datatype, each constructor's atom and field types, in order."
  @type types :: %{String.t() => [{atom, [type]}]}
  @max_depth 2048
  @max_decoded 64 * 1024 * 1024

  @nat_max Integer.pow(2, 48) - 1
  # doubles below this round to a finite single; the midpoint to the next one
  @f32_edge 3.402_823_567_797_336_6e38
  @f32_nan <<0x7FC00000::32>>
  @f32_inf <<0x7F800000::32>>
  @f32_neg_inf <<0xFF800000::32>>

  @type type :: Bendler.Sig.type()

  @doc "A request frame: the function index, then each argument beside its type."
  @spec request(non_neg_integer, [{term, type}], types) :: binary
  def request(index, args, types \\ %{}) when is_integer(index) do
    ensure_request_budget!(args, types)
    <<index::32>> <> Enum.map_join(args, fn {v, t} -> encode(v, t, types) end)
  end

  @doc "Encodes one value of a marshalled type; raises ArgumentError on a mismatch."
  @spec encode(term, type, types) :: binary
  def encode(v, t, types \\ %{})
  def encode(v, :u32, _) when is_integer(v) and v >= 0 and v < 4_294_967_296, do: <<1, v::32>>
  def encode(v, :nat, _) when is_integer(v) and v >= 0 and v <= @nat_max, do: <<2, v::64>>
  def encode(v, :string, _) when is_binary(v), do: <<3, byte_size(v)::32, v::binary>>
  def encode(true, :bool, _), do: <<4, 1>>
  def encode(false, :bool, _), do: <<4, 0>>
  def encode(:unit, :unit, _), do: <<5>>
  def encode(v, :bytes, _) when is_binary(v), do: <<7, byte_size(v)::32, v::binary>>
  def encode(v, :f32, _) when is_float(v) and abs(v) < @f32_edge, do: <<13, v::float-32>>
  def encode(:nan, :f32, _), do: <<13>> <> @f32_nan
  def encode(:infinity, :f32, _), do: <<13>> <> @f32_inf
  def encode(:neg_infinity, :f32, _), do: <<13>> <> @f32_neg_inf

  def encode(v, :char, _) when is_integer(v) and v in 0..0x10FFFF and v not in 0xD800..0xDFFF,
    do: <<14, v::32>>

  def encode(v, {:map, t}, types) when is_map(v) do
    unless Enum.all?(Map.keys(v), &(is_binary(&1) and String.valid?(&1))),
      do: raise(ArgumentError, "Map keys must be valid UTF-8 strings")

    encode(Map.to_list(v), {:list, {:tuple, [:string, t]}}, types)
  end

  def encode(v, {:list, t}, types) when is_list(v),
    do: <<6, length(v)::32>> <> Enum.map_join(v, &encode(&1, t, types))

  def encode(v, {:tuple, ts}, types)
      when is_tuple(v) and tuple_size(v) == length(ts) and length(ts) in 2..16,
      do: <<8, length(ts)>> <> encode_all(Tuple.to_list(v), ts, types)

  def encode(:none, {:maybe, _}, _), do: <<9>>
  def encode({:some, v}, {:maybe, t}, types), do: <<10>> <> encode(v, t, types)
  def encode({:ok, v}, {:result, _, t}, types), do: <<11>> <> encode(v, t, types)
  def encode({:error, v}, {:result, e, _}, types), do: <<12>> <> encode(v, e, types)

  def encode(v, {:data, name} = t, types)
      when is_atom(v) or (is_tuple(v) and tuple_size(v) > 1) do
    {tag, fields} = if is_atom(v), do: {v, []}, else: List.pop_at(Tuple.to_list(v), 0)
    ctors = Map.get(types, name, [])

    unless length(ctors) in 1..255 and Enum.all?(ctors, fn {_, fs} -> length(fs) <= 255 end),
      do:
        raise(
          ArgumentError,
          "datatype #{name} requires 1..255 constructors with at most 255 fields each"
        )

    case Enum.find(ctors, fn {a, _} -> a == tag end) do
      {_, fts} when length(fts) == length(fields) ->
        i = Enum.find_index(ctors, fn {a, _} -> a == tag end)
        <<15, i, length(fts)>> <> encode_all(fields, fts, types)

      {_, fts} ->
        raise ArgumentError,
              "cannot encode #{inspect(v)} as Bend #{name}: #{inspect(tag)} takes #{length(fts)} fields"

      nil ->
        raise ArgumentError, "cannot encode #{inspect(v)} as Bend #{describe(t)}"
    end
  end

  def encode(v, t, _) do
    raise ArgumentError, "cannot encode #{inspect(v)} as Bend #{describe(t)}"
  end

  defp encode_all(vs, ts, types),
    do: Enum.zip(vs, ts) |> Enum.map_join(fn {x, t} -> encode(x, t, types) end)

  # Mirror the runtime decoder's concrete allocations before constructing the
  # wire frame. A type containing a user datatype is decoded through Dyn as a
  # whole, so its enclosing tuples/lists carry Dyn overhead too.
  defp ensure_request_budget!(args, types) do
    _ =
      Enum.reduce(args, 0, fn {value, type}, used ->
        request_size(value, type, types, has_data?(type), used, 0)
      end)

    :ok
  end

  defp request_size(_, _, _, _, _, depth) when depth > @max_depth,
    do: raise(ArgumentError, "request nested too deep")

  defp request_size(v, :nat, _, true, used, _) when is_integer(v), do: request_charge!(used, 8)

  defp request_size(v, :string, _, dyn, used, _) when is_binary(v),
    do: request_charge!(used, byte_size(v) * 16 + if(dyn, do: 8, else: 0))

  defp request_size(v, :bytes, _, _, used, _) when is_binary(v) do
    slots = next_power_of_two(max(byte_size(v), 1))
    request_charge!(used, 16 + max(slots * 4, 8))
  end

  defp request_size(v, {:list, type}, types, dyn, used, depth) when is_list(v) do
    used = request_charge!(used, length(v) * 24 + if(dyn, do: 8, else: 0))
    Enum.reduce(v, used, &request_size(&1, type, types, dyn, &2, depth + 1))
  end

  defp request_size(v, {:map, type}, types, _, used, depth) when is_map(v) do
    used = request_charge!(used, map_size(v) * 40)

    Enum.reduce(v, used, fn {key, value}, acc ->
      acc =
        if is_binary(key),
          do: request_charge!(acc, byte_size(key) * 16),
          else: acc

      request_size(value, type, types, false, acc, depth + 2)
    end)
  end

  defp request_size(v, {:tuple, field_types}, types, dyn, used, depth)
       when is_tuple(v) and tuple_size(v) == length(field_types) do
    n = length(field_types)
    used = request_charge!(used, if(dyn, do: 8 + n * 16, else: (n - 1) * 16))

    Enum.zip(Tuple.to_list(v), field_types)
    |> Enum.reduce(used, fn {value, type}, acc ->
      request_size(value, type, types, dyn, acc, depth + 1)
    end)
  end

  defp request_size(:none, {:maybe, _}, _, dyn, used, _),
    do: request_charge!(used, if(dyn, do: 8, else: 0))

  defp request_size({:some, value}, {:maybe, type}, types, dyn, used, depth) do
    used = request_charge!(used, if(dyn, do: 24, else: 8))
    request_size(value, type, types, dyn, used, depth + 1)
  end

  defp request_size({tag, value}, {:result, error, ok}, types, dyn, used, depth)
       when tag in [:ok, :error] do
    used = request_charge!(used, if(dyn, do: 32, else: 8))
    request_size(value, if(tag == :ok, do: ok, else: error), types, dyn, used, depth + 1)
  end

  defp request_size(value, {:data, name}, types, _, used, depth)
       when is_atom(value) or (is_tuple(value) and tuple_size(value) > 1) do
    {tag, fields} = if is_atom(value), do: {value, []}, else: List.pop_at(Tuple.to_list(value), 0)

    case Enum.find(Map.get(types, name, []), fn {atom, _} -> atom == tag end) do
      {_, field_types} when length(field_types) == length(fields) ->
        used = request_charge!(used, 16 + length(fields) * 24)

        Enum.zip(fields, field_types)
        |> Enum.reduce(used, fn {field, type}, acc ->
          request_size(field, type, types, true, acc, depth + 1)
        end)

      _ ->
        used
    end
  end

  defp request_size(_, _, _, _, used, _), do: used

  defp request_charge!(used, amount) when amount <= @max_decoded - used, do: used + amount
  defp request_charge!(_, _), do: raise(ArgumentError, "request decoded memory budget exceeded")

  defp next_power_of_two(n), do: next_power_of_two(n, 1)
  defp next_power_of_two(n, power) when power >= n, do: power
  defp next_power_of_two(n, power), do: next_power_of_two(n, power * 2)

  defp has_data?({:data, _}), do: true
  defp has_data?({:list, type}), do: has_data?(type)
  defp has_data?({:map, type}), do: has_data?(type)
  defp has_data?({:tuple, types}), do: Enum.any?(types, &has_data?/1)
  defp has_data?({:maybe, type}), do: has_data?(type)
  defp has_data?({:result, error, ok}), do: has_data?(error) or has_data?(ok)
  defp has_data?(_), do: false

  @doc "The value a reply frame holds; raises Bendler.Error on the error tag."
  @spec reply(binary, atom) :: term
  def reply(bin, fun \\ :call)

  def reply(<<0, _::binary>> = bin, fun) do
    {{:error, msg}, rest} = decode(bin)
    if rest != <<>>, do: raise(Bendler.Error, "malformed transport error")

    raise Bendler.Error,
      message: "#{fun}: the Bend program refused the request: #{msg}",
      reason: :refused
  end

  def reply(bin, fun) do
    case decode(bin) do
      {v, <<>>} ->
        v

      {_, rest} ->
        raise Bendler.Error, message: "#{fun}: #{byte_size(rest)} trailing bytes in a reply"
    end
  end

  @doc """
  Asserts a decoded reply has the export's declared type; the wire tag alone
  is not trusted. A Map arrives as its pair list and becomes a map here, a
  user datatype as `{:data, index, fields}` and becomes its tagged tuple.
  """
  @spec check(term, type, atom, types) :: term
  def check(v, t, fun, types \\ %{}) do
    case fit(v, t, types) do
      {:ok, v} ->
        v

      :error ->
        raise Bendler.Error, message: "#{fun}: reply #{inspect(v)} is not a #{describe(t)}"
    end
  end

  # the value as the type says, converted where the wire form differs
  defp fit(v, :u32, _) when is_integer(v) and v >= 0 and v < 4_294_967_296, do: {:ok, v}
  defp fit(v, :nat, _) when is_integer(v) and v >= 0 and v <= @nat_max, do: {:ok, v}
  defp fit(v, :string, _) when is_binary(v), do: {:ok, v}
  defp fit(v, :bool, _) when is_boolean(v), do: {:ok, v}
  defp fit(:unit, :unit, _), do: {:ok, :unit}
  defp fit(v, :bytes, _) when is_binary(v), do: {:ok, v}
  defp fit(v, :f32, _) when is_float(v) or v in [:nan, :infinity, :neg_infinity], do: {:ok, v}

  defp fit(v, :char, _) when is_integer(v) and v in 0..0x10FFFF and v not in 0xD800..0xDFFF,
    do: {:ok, v}

  defp fit(v, {:map, t}, types) do
    with {:ok, pairs} <- fit(v, {:list, {:tuple, [:string, t]}}, types), do: {:ok, Map.new(pairs)}
  end

  defp fit(v, {:list, t}, types) when is_list(v),
    do: fit_all(v, List.duplicate(t, length(v)), types)

  defp fit(v, {:tuple, ts}, types) when is_tuple(v) and tuple_size(v) == length(ts) do
    with {:ok, xs} <- fit_all(Tuple.to_list(v), ts, types), do: {:ok, List.to_tuple(xs)}
  end

  defp fit(:none, {:maybe, _}, _), do: {:ok, :none}
  defp fit({:some, v}, {:maybe, t}, types), do: fit_tagged(:some, v, t, types)
  defp fit({:ok, v}, {:result, _, t}, types), do: fit_tagged(:ok, v, t, types)
  defp fit({:error, v}, {:result, e, _}, types), do: fit_tagged(:error, v, e, types)

  defp fit({:data, i, fields}, {:data, name}, types) do
    case Enum.at(Map.get(types, name, []), i) do
      {atom, fts} when length(fts) == length(fields) ->
        with {:ok, xs} <- fit_all(fields, fts, types) do
          {:ok, if(xs == [], do: atom, else: List.to_tuple([atom | xs]))}
        end

      _ ->
        :error
    end
  end

  defp fit(_, _, _), do: :error

  defp fit_tagged(tag, v, t, types) do
    with {:ok, v} <- fit(v, t, types), do: {:ok, {tag, v}}
  end

  defp fit_all(vs, ts, types) do
    Enum.zip(vs, ts)
    |> Enum.reduce_while({:ok, []}, fn {v, t}, {:ok, acc} ->
      case fit(v, t, types) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  @doc "Decodes one value, returning it beside the rest of the binary."
  @spec decode(binary) :: {term, binary}
  def decode(bin) do
    _ = scan_value(bin, 0, 0)
    decode_value(bin, 0)
  end

  # Validate and account a reply before decode_items allocates its placeholder
  # and result lists. This scanner intentionally builds no terms from the wire.
  defp scan_value(_, depth, _) when depth > @max_depth,
    do: raise(Bendler.Error, "reply nested too deep")

  defp scan_value(<<0, n::32, _::binary-size(n), r::binary>>, 0, used),
    do: {r, charge!(used, n + 64)}

  defp scan_value(<<tag, _::binary-size(4), r::binary>>, _, used) when tag in [1, 14],
    do: {r, used}

  defp scan_value(<<2, v::64, r::binary>>, _, used) when v <= @nat_max, do: {r, used}

  defp scan_value(<<tag, n::32, _::binary-size(n), r::binary>>, _, used) when tag in [3, 7],
    do: {r, charge!(used, n + 64)}

  defp scan_value(<<4, b, r::binary>>, _, used) when b in [0, 1], do: {r, used}
  defp scan_value(<<5, r::binary>>, _, used), do: {r, used}
  defp scan_value(<<13, _::32, r::binary>>, _, used), do: {r, charge!(used, 16)}
  defp scan_value(<<9, r::binary>>, _, used), do: {r, used}

  # decode_items allocates a 16-byte/element placeholder list and result list;
  # List.to_tuple then allocates n + 1 words while the result list is retained.
  defp scan_value(<<8, n, r::binary>>, d, used) when n in 2..16 and n <= byte_size(r),
    do: scan_items(n, r, d, charge!(used, n * 40 + 8))

  defp scan_value(<<15, _ctor, n, r::binary>>, d, used) when n <= byte_size(r),
    do: scan_items(n, r, d, charge!(used, n * 32 + 32))

  defp scan_value(<<tag, r::binary>>, d, used) when tag in [10, 11, 12] do
    scan_value(r, d + 1, charge!(used, 24))
  end

  defp scan_value(<<6, n::32, r::binary>>, d, used) when n <= byte_size(r),
    do: scan_items(n, r, d, charge!(used, n * 32))

  defp scan_value(_, _, _), do: raise(Bendler.Error, "malformed reply")

  defp scan_items(0, rest, _, used), do: {rest, used}

  defp scan_items(n, bin, depth, used) do
    {rest, used} = scan_value(bin, depth + 1, used)
    scan_items(n - 1, rest, depth, used)
  end

  defp charge!(used, amount) when amount <= @max_decoded - used, do: used + amount
  defp charge!(_, _), do: raise(Bendler.Error, "reply decoded memory budget exceeded")

  defp decode_value(_, depth) when depth > @max_depth,
    do: raise(Bendler.Error, "reply nested too deep")

  defp decode_value(<<0, n::32, msg::binary-size(n), r::binary>>, 0), do: {{:error, msg}, r}
  defp decode_value(<<1, v::32, r::binary>>, _), do: {v, r}
  defp decode_value(<<2, v::64, r::binary>>, _) when v <= @nat_max, do: {v, r}
  defp decode_value(<<3, n::32, s::binary-size(n), r::binary>>, _), do: {s, r}
  defp decode_value(<<4, b, r::binary>>, _) when b in [0, 1], do: {b == 1, r}
  defp decode_value(<<5, r::binary>>, _), do: {:unit, r}
  defp decode_value(<<7, n::32, s::binary-size(n), r::binary>>, _), do: {s, r}
  defp decode_value(<<13, f::float-32, r::binary>>, _), do: {f, r}
  defp decode_value(<<13, bits::32, r::binary>>, _), do: {non_finite(bits), r}
  defp decode_value(<<14, v::32, r::binary>>, _), do: {v, r}

  defp decode_value(<<8, n, r::binary>>, d) when n in 2..16 and n <= byte_size(r) do
    {xs, rest} = decode_items(n, r, d)
    {List.to_tuple(xs), rest}
  end

  defp decode_value(<<9, r::binary>>, _), do: {:none, r}

  defp decode_value(<<15, ctor, n, r::binary>>, d) when n <= byte_size(r) do
    {xs, rest} = decode_items(n, r, d)
    {{:data, ctor, xs}, rest}
  end

  defp decode_value(<<tag, r::binary>>, d) when tag in [10, 11, 12] do
    {v, rest} = decode_value(r, d + 1)
    label = %{10 => :some, 11 => :ok, 12 => :error}[tag]
    {{label, v}, rest}
  end

  # every item takes at least a tag byte: a count past the binary is a lie
  defp decode_value(<<6, n::32, r::binary>>, d) when n <= byte_size(r) do
    decode_items(n, r, d)
  end

  defp decode_value(other, _), do: raise(Bendler.Error, "malformed reply: #{inspect(other)}")

  # a float-32 match only fails on a NaN or an infinity
  defp non_finite(bits) when Bitwise.band(bits, 0x7FFFFF) != 0, do: :nan
  defp non_finite(bits) when Bitwise.band(bits, 0x80000000) == 0, do: :infinity
  defp non_finite(_), do: :neg_infinity

  defp decode_items(n, r, d),
    do: Enum.map_reduce(List.duplicate(nil, n), r, fn _, r -> decode_value(r, d + 1) end)

  defp describe(:u32), do: "U32 (an integer in 0..2^32-1)"
  defp describe(:nat), do: "Nat (an integer in 0..2^48-1)"
  defp describe(:string), do: "String (a binary)"
  defp describe(:bool), do: "Bool"
  defp describe(:unit), do: "Unit (the atom :unit)"
  defp describe(:bytes), do: "Bytes (a binary)"

  defp describe(:f32),
    do: "F32 (a float within the single range, :nan, :infinity or :neg_infinity)"

  defp describe(:char), do: "Char (a code point, 0..0x10FFFF without surrogates)"
  defp describe({:map, t}), do: "Map of String to #{describe(t)} (a map with binary keys)"
  defp describe({:data, n}), do: "#{n} (a constructor atom or tagged tuple)"
  defp describe({:list, t}), do: "List of #{describe(t)}"
  defp describe({:tuple, ts}), do: "tuple of (#{Enum.map_join(ts, ", ", &describe/1)})"
  defp describe({:maybe, t}), do: "Maybe<#{describe(t)}>"
  defp describe({:result, e, t}), do: "Result<#{describe(e)}, #{describe(t)}>"
end

defmodule Bendler.Error do
  @moduledoc "Raised by a generated function: `reason` is `:busy`, `:timeout`, `:dead`, `:exited`, `:refused`, `:nomem` or `:build`."
  defexception [:message, reason: :build]

  @impl true
  def exception(msg) when is_binary(msg), do: %__MODULE__{message: msg}
  def exception(opts), do: struct!(__MODULE__, opts)
end
