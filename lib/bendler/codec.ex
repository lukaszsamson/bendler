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

  A Result's Fail is returned as `{:error, value}`; only tag 0 raises a
  transport error. Composite values may nest up to 32 levels.
  """

  @nat_max Integer.pow(2, 48) - 1

  @type type :: Bendler.Sig.type()

  @doc "A request frame: the function index, then each argument beside its type."
  @spec request(non_neg_integer, [{term, type}]) :: binary
  def request(index, args) when is_integer(index) do
    <<index::32>> <> Enum.map_join(args, fn {v, t} -> encode(v, t) end)
  end

  @doc "Encodes one value of a marshalled type; raises ArgumentError on a mismatch."
  @spec encode(term, type) :: binary
  def encode(v, :u32) when is_integer(v) and v >= 0 and v < 4_294_967_296, do: <<1, v::32>>
  def encode(v, :nat) when is_integer(v) and v >= 0 and v <= @nat_max, do: <<2, v::64>>
  def encode(v, :string) when is_binary(v), do: <<3, byte_size(v)::32, v::binary>>
  def encode(true, :bool), do: <<4, 1>>
  def encode(false, :bool), do: <<4, 0>>
  def encode(:unit, :unit), do: <<5>>
  def encode(v, :bytes) when is_binary(v), do: <<7, byte_size(v)::32, v::binary>>

  def encode(v, {:list, t}) when is_list(v),
    do: <<6, length(v)::32>> <> Enum.map_join(v, &encode(&1, t))

  def encode(v, {:tuple, ts})
      when is_tuple(v) and tuple_size(v) == length(ts) and length(ts) in 2..16,
      do:
        <<8, length(ts)>> <>
          (Enum.zip(Tuple.to_list(v), ts) |> Enum.map_join(fn {x, t} -> encode(x, t) end))

  def encode(:none, {:maybe, _}), do: <<9>>
  def encode({:some, v}, {:maybe, t}), do: <<10>> <> encode(v, t)
  def encode({:ok, v}, {:result, _, t}), do: <<11>> <> encode(v, t)
  def encode({:error, v}, {:result, e, _}), do: <<12>> <> encode(v, e)

  def encode(v, t) do
    raise ArgumentError, "cannot encode #{inspect(v)} as Bend #{describe(t)}"
  end

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
        raise Bendler.Error, message: "#{fun}: trailing bytes in a reply: #{inspect(rest)}"
    end
  end

  @doc "Asserts a decoded reply has the export's declared type; the wire tag alone is not trusted."
  @spec check(term, type, atom) :: term
  def check(v, t, fun) do
    if typed?(v, t),
      do: v,
      else: raise(Bendler.Error, message: "#{fun}: reply #{inspect(v)} is not a #{describe(t)}")
  end

  defp typed?(v, :u32), do: is_integer(v) and v >= 0 and v < 4_294_967_296
  defp typed?(v, :nat), do: is_integer(v) and v >= 0 and v <= @nat_max
  defp typed?(v, :string), do: is_binary(v)
  defp typed?(v, :bool), do: is_boolean(v)
  defp typed?(v, :unit), do: v == :unit
  defp typed?(v, :bytes), do: is_binary(v)
  defp typed?(v, {:list, t}), do: is_list(v) and Enum.all?(v, &typed?(&1, t))

  defp typed?(v, {:tuple, ts}) when is_tuple(v) and tuple_size(v) == length(ts),
    do: Enum.zip(Tuple.to_list(v), ts) |> Enum.all?(fn {x, t} -> typed?(x, t) end)

  defp typed?(:none, {:maybe, _}), do: true
  defp typed?({:some, v}, {:maybe, t}), do: typed?(v, t)
  defp typed?({:ok, v}, {:result, _, t}), do: typed?(v, t)
  defp typed?({:error, v}, {:result, e, _}), do: typed?(v, e)
  defp typed?(_, _), do: false

  @doc "Decodes one value, returning it beside the rest of the binary."
  @spec decode(binary) :: {term, binary}
  def decode(bin), do: decode_value(bin, 0)
  defp decode_value(_, depth) when depth > 32, do: raise(Bendler.Error, "reply nested too deep")
  defp decode_value(<<0, n::32, msg::binary-size(n), r::binary>>, 0), do: {{:error, msg}, r}
  defp decode_value(<<1, v::32, r::binary>>, _), do: {v, r}
  defp decode_value(<<2, v::64, r::binary>>, _) when v <= @nat_max, do: {v, r}
  defp decode_value(<<3, n::32, s::binary-size(n), r::binary>>, _), do: {s, r}
  defp decode_value(<<4, b, r::binary>>, _) when b in [0, 1], do: {b == 1, r}
  defp decode_value(<<5, r::binary>>, _), do: {:unit, r}
  defp decode_value(<<7, n::32, s::binary-size(n), r::binary>>, _), do: {s, r}

  defp decode_value(<<8, n, r::binary>>, d) when n in 2..16 and n <= byte_size(r) do
    {xs, rest} = decode_items(n, r, d)
    {List.to_tuple(xs), rest}
  end

  defp decode_value(<<9, r::binary>>, _), do: {:none, r}

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

  defp decode_items(n, r, d),
    do: Enum.map_reduce(List.duplicate(nil, n), r, fn _, r -> decode_value(r, d + 1) end)

  defp describe(:u32), do: "U32 (an integer in 0..2^32-1)"
  defp describe(:nat), do: "Nat (an integer in 0..2^48-1)"
  defp describe(:string), do: "String (a binary)"
  defp describe(:bool), do: "Bool"
  defp describe(:unit), do: "Unit (the atom :unit)"
  defp describe(:bytes), do: "Bytes (a binary)"
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
