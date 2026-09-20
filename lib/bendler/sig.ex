defmodule Bendler.Sig do
  @moduledoc """
  Parses the signatures of the top-level defs of a Bend file and decides which
  of them can be exported to Elixir.

  A def is exportable when every parameter and its result are of a marshalled
  type: `U32`, `Nat`, `String`, `Bool`, `Unit`, `Bytes` (the prelude's
  `B.Bytes`, an Elixir binary), and recursively `List<T>`, products `A & B`,
  `Maybe<T>` and `Result<E, T>`. Products have 2–16 fields; nesting is capped
  at 32. Kind-qualified generics and reusable (`+`) types are accepted.
  Erased (`-`) and template (`~`) parameters,
  `IO` results and every other type keep a def out.
  """

  defstruct [:name, :params, :ret, :line]

  @type type ::
          :u32
          | :nat
          | :string
          | :bool
          | :unit
          | :bytes
          | {:list, type}
          | {:tuple, [type]}
          | {:maybe, type}
          | {:result, type, type}
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

  @doc "The marshalled type a Bend type spells, if any."
  @spec parse_type(String.t()) :: {:ok, type} | {:error, String.t()}
  def parse_type(text) do
    tokens = Regex.scan(~r/[A-Za-z_][\w.]*|&[012]|[^\s]/, text) |> List.flatten()

    with {:ok, type, []} <- product(tokens, 0), true <- type_depth(type) <= 32 do
      {:ok, type}
    else
      _ -> {:error, "unsupported type #{text}"}
    end
  end

  defp type_depth({:tuple, ts}), do: 1 + Enum.max(Enum.map(ts, &type_depth/1))
  defp type_depth({:result, e, t}), do: 1 + max(type_depth(e), type_depth(t))
  defp type_depth({_, t}), do: 1 + type_depth(t)
  defp type_depth(_), do: 0

  # the prelude's Bytes, under whatever alias the file imported it
  defp bytes_type(text), do: if(Regex.match?(~r/^(?:\w+\.)?Bytes$/, text), do: :bytes)

  # Bounded recursive descent. Product binds outside generic arguments;
  # parentheses preserve nested tuples instead of flattening them.
  defp product(tokens, depth) do
    with {:ok, first, rest} <- atom_type(tokens, depth) do
      product_tail([first], rest, depth)
    end
  end

  defp product_tail(types, ["&" | rest], depth) when length(types) < 16 do
    with {:ok, next, tail} <- atom_type(rest, depth + 1) do
      product_tail(types ++ [next], tail, depth)
    end
  end

  defp product_tail([type], rest, _), do: {:ok, type, rest}
  defp product_tail(types, rest, _), do: {:ok, {:tuple, types}, rest}

  defp atom_type(_, depth) when depth > 32, do: :error
  defp atom_type(["+" | rest], depth), do: atom_type(rest, depth + 1)

  defp atom_type(["(" | rest], depth) do
    case product(rest, depth + 1) do
      {:ok, type, [")" | tail]} -> {:ok, type, tail}
      _ -> :error
    end
  end

  defp atom_type([name, "<" | rest], depth) when name in ["List", "Maybe", "Result"] do
    rest = drop_kinds(rest, if(name == "Result", do: 2, else: 1))

    with {:ok, first, tail} <- product(rest, depth + 1) do
      generic(name, first, tail, depth)
    end
  end

  defp atom_type([word | rest], _) do
    case Map.get(@word_types, word) || bytes_type(word) do
      nil -> :error
      type -> {:ok, type, rest}
    end
  end

  defp atom_type([], _), do: :error

  defp drop_kinds([a, ",", b, "," | rest], 2)
       when a in ["&0", "&1", "&2"] and b in ["&0", "&1", "&2"], do: rest

  defp drop_kinds([kind, "," | rest], 1) when kind in ["&0", "&1", "&2"], do: rest

  defp drop_kinds(tokens, _), do: tokens
  defp generic("List", type, [">" | rest], _), do: {:ok, {:list, type}, rest}
  defp generic("Maybe", type, [">" | rest], _), do: {:ok, {:maybe, type}, rest}

  defp generic("Result", error, ["," | rest], depth) do
    case product(rest, depth + 1) do
      {:ok, value, [">" | tail]} -> {:ok, {:result, error, value}, tail}
      _ -> :error
    end
  end

  defp generic(_, _, _, _), do: :error

  @doc "The C codec's prefix type grammar: primitives, L/M child, R error/value, T arity:fields."
  @spec spec(type) :: String.t()
  def spec(:u32), do: "u"
  def spec(:nat), do: "n"
  def spec(:string), do: "s"
  def spec(:bool), do: "b"
  def spec(:unit), do: "t"
  def spec(:bytes), do: "y"
  def spec({:list, t}), do: "L" <> spec(t)
  def spec({:tuple, ts}), do: "T#{length(ts)}:" <> Enum.map_join(ts, &spec/1)
  def spec({:maybe, t}), do: "M" <> spec(t)
  def spec({:result, e, t}), do: "R" <> spec(e) <> spec(t)

  @doc "The Elixir typespec of a marshalled type."
  @spec typespec(type) :: Macro.t()
  def typespec(:u32), do: quote(do: non_neg_integer())
  def typespec(:nat), do: quote(do: non_neg_integer())
  def typespec(:string), do: quote(do: String.t())
  def typespec(:bool), do: quote(do: boolean())
  def typespec(:unit), do: quote(do: :unit)
  def typespec(:bytes), do: quote(do: binary())
  def typespec({:list, t}), do: quote(do: [unquote(typespec(t))])
  def typespec({:tuple, ts}), do: {:{}, [], Enum.map(ts, &typespec/1)}
  def typespec({:maybe, t}), do: quote(do: :none | {:some, unquote(typespec(t))})

  def typespec({:result, e, t}),
    do: quote(do: {:ok, unquote(typespec(t))} | {:error, unquote(typespec(e))})
end
