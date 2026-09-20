defmodule Bendler.Sig do
  @moduledoc """
  Parses the signatures of the top-level defs of a Bend file and decides which
  of them can be exported to Elixir.

  A def is exportable when every parameter and its result are of a marshalled
  type: `U32`, `Nat`, `String`, `Bool`, `Unit` and `List<T>` of those (also
  written `+List<T>` or `List<&2, T>`). Erased (`-`) and template (`~`)
  parameters, `IO` results and every other type keep a def out.
  """

  defstruct [:name, :params, :ret, :line]

  @type type :: :u32 | :nat | :string | :bool | :unit | {:list, type}
  @type param :: %{name: String.t(), type: type, text: String.t(), reusable: boolean}
  @type t :: %__MODULE__{
          name: String.t(),
          params: [param],
          ret: {type, String.t()},
          line: pos_integer
        }

  @def_re ~r/^(?:@unsafe\s+)?def\s+([A-Za-z_][\w.]*)\((.*)\)\s*->\s*(.+?)\s*:\s*$/

  @doc "Every exportable def of the source, in order, beside the defs skipped and why."
  @spec parse(String.t()) :: {[t], [{String.t(), String.t()}]}
  def parse(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {raw, no}, {ok, bad} ->
      case classify(raw |> strip_comment() |> String.trim_trailing(), no) do
        :other -> {ok, bad}
        {:ok, sig} -> {[sig | ok], bad}
        {:skip, name, why} -> {ok, [{name, why} | bad]}
      end
    end)
    |> then(fn {ok, bad} -> {Enum.reverse(ok), Enum.reverse(bad)} end)
    |> check_collisions()
  end

  @def_head_re ~r/^(?:@unsafe\s+)?def\s+([A-Za-z_][\w.]*)\(/

  # One line: a readable def signature, an unreadable def head, or neither.
  defp classify(line, no) do
    case {Regex.run(@def_re, line), Regex.run(@def_head_re, line)} do
      {[_, name, params, ret], _} -> build(name, params, ret, no)
      {nil, [_, name]} -> {:skip, name, "a signature bendler cannot read (multi-line?)"}
      {nil, nil} -> :other
    end
  end

  # `a.b` and `a_b` would both become a_b/1 in Elixir
  defp check_collisions({sigs, bad}) do
    sigs
    |> Enum.group_by(&{String.replace(&1.name, ".", "_"), length(&1.params)})
    |> Enum.each(fn
      {_, [_]} ->
        :ok

      {{f, n}, dups} ->
        raise Bendler.Error,
              "defs #{Enum.map_join(dups, ", ", & &1.name)} would all become #{f}/#{n}"
    end)

    {sigs, bad}
  end

  # a `#` outside a string starts a comment; strings in a signature are not expected
  defp strip_comment(line), do: line |> String.split("#", parts: 2) |> hd()

  defp build("main", _, _, _), do: {:skip, "main", "main is the program, not an export"}

  defp build(name, params, ret, no) do
    with {:ok, params} <- parse_params(params),
         {:ok, ret_t} <- parse_type(ret) do
      {:ok, %__MODULE__{name: name, params: params, ret: {ret_t, String.trim(ret)}, line: no}}
    else
      {:error, why} -> {:skip, name, why}
    end
  end

  defp parse_params(""), do: {:ok, []}

  defp parse_params(text) do
    text
    |> split_top()
    |> Enum.reduce_while({:ok, []}, fn p, {:ok, acc} ->
      case parse_param(String.trim(p)) do
        {:ok, param} -> {:cont, {:ok, [param | acc]}}
        {:error, why} -> {:halt, {:error, why}}
      end
    end)
    |> case do
      {:ok, ps} -> {:ok, Enum.reverse(ps)}
      err -> err
    end
  end

  @param_re ~r/^([+\-~]?)(\w+)\s*:\s*(.+)$/

  defp parse_param(text) do
    case Regex.run(@param_re, text) do
      [_, "-", n, _] -> {:error, "erased parameter #{n}"}
      [_, "~", n, _] -> {:error, "template parameter #{n}"}
      [_, q, n, t] -> typed_param(n, q == "+", String.trim(t))
      nil -> {:error, "unreadable parameter #{inspect(text)}"}
    end
  end

  defp typed_param(name, reusable, text) do
    case parse_type(text) do
      {:ok, type} -> {:ok, %{name: name, type: type, text: text, reusable: reusable}}
      {:error, why} -> {:error, "parameter #{name}: #{why}"}
    end
  end

  # Splits on the commas outside <> and ().
  defp split_top(text) do
    {parts, cur, _} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        ",", {parts, cur, 0} -> {[cur | parts], "", 0}
        c, {parts, cur, d} when c in ["<", "("] -> {parts, cur <> c, d + 1}
        c, {parts, cur, d} when c in [">", ")"] -> {parts, cur <> c, d - 1}
        c, {parts, cur, d} -> {parts, cur <> c, d}
      end)

    Enum.reverse([cur | parts])
  end

  @word_types %{
    "U32" => :u32,
    "Nat" => :nat,
    "String" => :string,
    "Bool" => :bool,
    "Unit" => :unit
  }
  @list_re ~r/^List<(?:&[012]\s*,\s*)?(.+)>$/

  @doc "The marshalled type a Bend type spells, if any."
  @spec parse_type(String.t()) :: {:ok, type} | {:error, String.t()}
  def parse_type(text) do
    case String.trim(text) do
      "+" <> rest -> parse_type(rest)
      other -> word_or_list(Map.get(@word_types, other), other)
    end
  end

  defp word_or_list(nil, text), do: list_type(text)
  defp word_or_list(type, _text), do: {:ok, type}

  defp list_type(text) do
    case Regex.run(@list_re, text) do
      [_, inner] -> with {:ok, t} <- parse_type(inner), do: {:ok, {:list, t}}
      nil -> {:error, "unsupported type #{text}"}
    end
  end

  @doc "The one-letter spec the C codec reads: u n s b t, and L before an element."
  @spec spec(type) :: String.t()
  def spec(:u32), do: "u"
  def spec(:nat), do: "n"
  def spec(:string), do: "s"
  def spec(:bool), do: "b"
  def spec(:unit), do: "t"
  def spec({:list, t}), do: "L" <> spec(t)

  @doc "The Elixir typespec of a marshalled type."
  def typespec(:u32), do: quote(do: non_neg_integer())
  def typespec(:nat), do: quote(do: non_neg_integer())
  def typespec(:string), do: quote(do: String.t())
  def typespec(:bool), do: quote(do: boolean())
  def typespec(:unit), do: quote(do: :unit)
  def typespec({:list, t}), do: quote(do: [unquote(typespec(t))])
end
