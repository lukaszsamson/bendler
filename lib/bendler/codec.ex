defmodule Bendler.Codec do
  @moduledoc """
  The binary codec between Elixir and a Bend program. Every value is a tag
  byte and a big-endian payload; a request is a function index and its
  arguments; a reply is one value, or the error tag.

      0 error (len32 + message)  1 U32 (4 bytes)  2 Nat (8 bytes, < 2^48)
      3 String (len32)           4 Bool (1 byte)  5 Unit
      6 List (count32, then the items)
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

  def encode(v, {:list, t}) when is_list(v),
    do: <<6, length(v)::32>> <> Enum.map_join(v, &encode(&1, t))

  def encode(v, t) do
    raise ArgumentError, "cannot encode #{inspect(v)} as Bend #{describe(t)}"
  end

  @doc "The value a reply frame holds; raises Bendler.Error on the error tag."
  @spec reply(binary, atom) :: term
  def reply(bin, fun \\ :call) do
    case decode(bin) do
      {{:error, msg}, _} ->
        raise Bendler.Error,
          message: "#{fun}: the Bend program refused the request: #{msg}",
          reason: :refused

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
  defp typed?(v, {:list, t}), do: is_list(v) and Enum.all?(v, &typed?(&1, t))

  @doc "Decodes one value, returning it beside the rest of the binary."
  @spec decode(binary) :: {term, binary}
  def decode(<<0, n::32, msg::binary-size(n), r::binary>>), do: {{:error, msg}, r}
  def decode(<<1, v::32, r::binary>>), do: {v, r}
  def decode(<<2, v::64, r::binary>>) when v <= @nat_max, do: {v, r}
  def decode(<<3, n::32, s::binary-size(n), r::binary>>), do: {s, r}
  def decode(<<4, b, r::binary>>) when b in [0, 1], do: {b == 1, r}
  def decode(<<5, r::binary>>), do: {:unit, r}

  # every item takes at least a tag byte: a count past the binary is a lie
  def decode(<<6, n::32, r::binary>>) when n <= byte_size(r) do
    Enum.map_reduce(List.duplicate(nil, n), r, fn _, r -> decode(r) end)
  end

  def decode(other), do: raise(Bendler.Error, "malformed reply: #{inspect(other)}")

  defp describe(:u32), do: "U32 (an integer in 0..2^32-1)"
  defp describe(:nat), do: "Nat (an integer in 0..2^48-1)"
  defp describe(:string), do: "String (a binary)"
  defp describe(:bool), do: "Bool"
  defp describe(:unit), do: "Unit (the atom :unit)"
  defp describe({:list, t}), do: "List of #{describe(t)}"
end

defmodule Bendler.Error do
  @moduledoc "Raised by a generated function: `reason` is `:busy`, `:timeout`, `:dead`, `:exited`, `:refused`, `:nomem` or `:build`."
  defexception [:message, reason: :build]

  @impl true
  def exception(msg) when is_binary(msg), do: %__MODULE__{message: msg}
  def exception(opts), do: struct!(__MODULE__, opts)
end
