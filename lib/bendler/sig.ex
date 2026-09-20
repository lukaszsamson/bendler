defmodule Bendler.Sig do
  @moduledoc """
  Parses the signatures of the top-level defs of a Bend file, and its
  `type` declarations, and decides which defs can be exported to Elixir.

  A def is exportable when every parameter and its result are of a marshalled
  type: `U32`, `Nat`, `F32`, `Char`, `String`, `Bool`, `Unit`, `Bytes` (the
  prelude's `B.Bytes`, an Elixir binary), a user datatype declared in the
  same file, and recursively `List<T>`, products `A & B`, `Maybe<T>` and
  `Result<E, T>`. A whole parameter or result may also be `Map<V>` (string
  keys), which crosses as a list of pairs and is converted by Base's
  `Map.from_list` and `Map.to_list` on the Bend side; a Map nested inside
  another type is not supported. Products have 2–16 fields; nesting is
  capped at 32. Kind-qualified generics and reusable (`+`) types are
  accepted. Erased (`-`) and template (`~`) parameters, `IO` results and
  every other type keep a def out.

  ## User datatypes

  A `type T is Data:` (or `is Type:`) whose constructors have fields of
  marshalled types crosses as tagged tuples: `Circle{r: U32}` is
  `{:circle, r}` and a constructor without fields is its atom. The
  constructor name is underscored (`MNode` is `:m_node`). The rules, each
  reported as the reason a def is skipped when broken:

    * no type parameters, no erased fields, no `Map` field;
    * a type may refer to itself only as a whole field `T`, `List<T>` or
      `Maybe<T>` (spelled `List<&2, T>` and `Maybe<&2, T>` when `T is
      Data`); two types may not refer to each other;
    * some constructor must have a finite value (a type whose every
      constructor holds a `T` has none), for the converter's fallback;
    * a `Map<V>` parameter's `V` holds no user type.

  The conversion happens on the Bend side, in generated defs, over the
  prelude's `Dyn` tree; the C codec never lays out a user constructor.
  """

  defstruct [:name, :params, :ret, :line]

  @type type ::
          :u32
          | :nat
          | :string
          | :bool
          | :unit
          | :bytes
          | :f32
          | :char
          | {:data, String.t()}
          | {:map, type}
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

  @typedoc "A parsed type beside the text that spelled it and its parts, for the generator."
  @type tree :: %{type: type, text: String.t(), parts: [tree]}

  @typedoc "A constructor field."
  @type field :: %{name: String.t(), type: type, text: String.t(), tree: tree}
  @typedoc "A constructor: its Bend name, its Elixir atom, its fields."
  @type ctor :: %{name: String.t(), atom: atom, fields: [field]}
  @typedoc "A user datatype that can cross."
  @type data :: %{name: String.t(), kind: :data | :type, ctors: [ctor], line: pos_integer}
  @typedoc "The user datatypes that can cross, in dependency order."
  @type types :: [data]

  @def_re ~r/^(?:@unsafe\s+)?def\s+([A-Za-z_][\w.]*)\((.*)\)\s*->\s*(.+?)\s*:\s*$/

  @doc """
  Every exportable def of the source, in order, beside the defs skipped
  and why, and the user datatypes that can cross.
  """
  @spec parse(String.t()) :: {[t], [{String.t(), String.t()}], types}
  def parse(source) do
    lines =
      source
      |> String.split("\n")
      |> Enum.map(&(&1 |> strip_comment() |> String.trim_trailing()))
      |> join_signatures()

    {types, bad_types} = types(lines)
    ctx = %{types: Map.new(types, &{&1.name, &1}), bad: bad_types}

    lines
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {line, no}, {ok, bad} ->
      case classify(line, no, ctx) do
        :other -> {ok, bad}
        {:ok, sig} -> {[sig | ok], bad}
        {:skip, name, why} -> {ok, [{name, why} | bad]}
      end
    end)
    |> then(fn {ok, bad} -> {Enum.reverse(ok), Enum.reverse(bad)} end)
    |> check_collisions()
    |> Tuple.insert_at(2, types)
  end

  @def_head_re ~r/^(?:@unsafe\s+)?def\s+([A-Za-z_][\w.]*)\(/

  # A signature may span lines: a def head whose parentheses or brackets are
  # still open, or that has no trailing colon yet, continues on the next
  # lines. They are joined into the first line (the others become blank, so
  # line numbers hold).
  defp join_signatures(lines) do
    lines
    |> Enum.reduce({[], nil}, fn line, {acc, open} -> join_line(line, acc, open) end)
    |> then(fn
      {acc, nil} -> acc
      {acc, open} -> put_head(acc, open)
    end)
    |> Enum.reverse()
  end

  # `acc` holds the lines seen so far, latest first, with a :head marker
  # where a signature being joined started; `open` is that signature so far
  defp join_line(line, acc, nil) do
    if Regex.match?(@def_head_re, line) and signature_open?(line),
      do: {[:head | acc], line},
      else: {[line | acc], nil}
  end

  defp join_line(line, acc, open) do
    joined = open <> " " <> String.trim(line)

    if signature_open?(joined),
      do: {["" | acc], joined},
      else: {put_head(["" | acc], joined), nil}
  end

  # the joined signature takes the place of its head marker
  defp put_head(acc, joined) do
    {blanks, [:head | rest]} = Enum.split_while(acc, &(&1 == ""))
    blanks ++ [joined | rest]
  end

  defp signature_open?(line) do
    depth =
      line
      |> String.replace("->", " ")
      |> String.graphemes()
      |> Enum.reduce(0, fn
        c, d when c in ["(", "<", "["] -> d + 1
        c, d when c in [")", ">", "]"] -> d - 1
        _, d -> d
      end)

    depth > 0 or not String.ends_with?(line, ":")
  end

  # One line: a readable def signature, an unreadable def head, or neither.
  defp classify(line, no, ctx) do
    case {Regex.run(@def_re, line), Regex.run(@def_head_re, line)} do
      {[_, name, params, ret], _} -> build(name, params, ret, no, ctx)
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

  defp build("main", _, _, _, _), do: {:skip, "main", "main is the program, not an export"}

  defp build(name, params, ret, no, ctx) do
    with {:ok, params} <- parse_params(params, ctx),
         {:ok, ret_t} <- parse_type(ret, ctx),
         :ok <- map_holds_no_data(ret_t) do
      {:ok, %__MODULE__{name: name, params: params, ret: {ret_t, String.trim(ret)}, line: no}}
    else
      {:error, why} -> {:skip, name, why}
    end
  end

  defp parse_params("", _), do: {:ok, []}

  defp parse_params(text, ctx) do
    text
    |> split_top()
    |> map_ok(&parse_param(String.trim(&1), ctx))
  end

  @param_re ~r/^([+\-~]?)(\w+)\s*:\s*(.+)$/

  defp parse_param(text, ctx) do
    case Regex.run(@param_re, text) do
      [_, "-", n, _] -> {:error, "erased parameter #{n}"}
      [_, "~", n, _] -> {:error, "template parameter #{n}"}
      [_, q, n, t] -> typed_param(n, q == "+", String.trim(t), ctx)
      nil -> {:error, "unreadable parameter #{inspect(text)}"}
    end
  end

  defp typed_param(name, reusable, text, ctx) do
    with {:ok, type} <- parse_type(text, ctx),
         :ok <- map_holds_no_data(type) do
      {:ok, %{name: name, type: type, text: text, reusable: reusable}}
    else
      {:error, why} -> {:error, "parameter #{name}: #{why}"}
    end
  end

  # a Map's pair list is converted by Base before the user type converters could run
  defp map_holds_no_data({:map, v}) do
    if has_data?(v), do: {:error, "a Map may not hold a user datatype"}, else: :ok
  end

  defp map_holds_no_data(_), do: :ok

  # Splits on the commas outside <>, () and {}.
  defp split_top(text) do
    {parts, cur, _} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        ",", {parts, cur, 0} -> {[cur | parts], "", 0}
        c, {parts, cur, d} when c in ["<", "(", "{"] -> {parts, cur <> c, d + 1}
        c, {parts, cur, d} when c in [">", ")", "}"] -> {parts, cur <> c, d - 1}
        c, {parts, cur, d} -> {parts, cur <> c, d}
      end)

    Enum.reverse([cur | parts])
  end

  defp map_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  # Type declarations
  # =================

  @type_re ~r/^type\s+([A-Za-z_][\w.]*)\s*(<.*>)?\s+is\s+(Data|Type)\s*:\s*$/
  @ctor_re ~r/^\s+([A-Za-z_]\w*)\s*\{(.*)\}\s*$/

  # The declared types that can cross (in dependency order) and the
  # reasons the others cannot.
  defp types(lines) do
    raw = raw_types(lines)
    names = Map.new(raw, &{&1.name, &1})

    {good, bad} =
      Enum.reduce(raw, {[], %{}}, fn t, {good, bad} ->
        case parse_ctors(t, names) do
          {:ok, t} -> {[t | good], bad}
          {:error, why} -> {good, Map.put(bad, t.name, why)}
        end
      end)

    settle(Enum.reverse(good), bad)
  end

  # `type` headers and the constructor lines indented under them
  defp raw_types(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {line, no}, {acc, open} -> raw_line(line, no, acc, open) end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.map(&%{&1 | raw_ctors: Enum.reverse(&1.raw_ctors)})
  end

  # one line of the source: a type header opens a type, an indented line
  # under an open one is a constructor, anything else closes it
  defp raw_line(line, no, acc, open) do
    cond do
      match = Regex.run(@type_re, line) ->
        [_, name, params, kind] = match
        kind = if kind == "Data", do: :data, else: :type
        {[%{name: name, kind: kind, params: params, raw_ctors: [], line: no} | acc], true}

      open and line != "" and String.starts_with?(line, " ") ->
        [t | rest] = acc
        {[%{t | raw_ctors: [line | t.raw_ctors]} | rest], true}

      line == "" ->
        {acc, open}

      true ->
        {acc, false}
    end
  end

  defp parse_ctors(%{params: params}, _) when params not in [nil, ""],
    do: {:error, "a type with parameters"}

  defp parse_ctors(t, names) do
    ctx = %{types: names, bad: %{}}

    with {:ok, ctors} <- map_ok(t.raw_ctors, &parse_ctor(&1, ctx)),
         :ok <- count_limit(ctors, 1, "constructors"),
         :ok <- distinct_atoms(ctors) do
      {:ok, %{name: t.name, kind: t.kind, ctors: ctors, line: t.line}}
    end
  end

  defp parse_ctor(line, ctx) do
    case Regex.run(@ctor_re, line) do
      [_, name, fields] ->
        fields = fields |> split_top() |> Enum.reject(&(String.trim(&1) == ""))

        with :ok <- count_limit(fields, 0, "constructor fields"),
             {:ok, fields} <- map_ok(fields, &parse_field(&1, ctx)) do
          {:ok, %{name: name, atom: ctor_atom(name), fields: fields}}
        end

      nil ->
        {:error, "a constructor bendler cannot read: #{String.trim(line)}"}
    end
  end

  defp parse_field(text, ctx) do
    case Regex.run(@param_re, String.trim(text)) do
      [_, "-", n, _] -> {:error, "erased field #{n}"}
      [_, "~", n, _] -> {:error, "template field #{n}"}
      [_, _, n, t] -> field_of(n, String.trim(t), ctx)
      nil -> {:error, "unreadable field #{inspect(text)}"}
    end
  end

  defp field_of(name, text, ctx) do
    case tree(text, ctx) do
      {:ok, %{type: {:map, _}}} -> {:error, "field #{name}: a Map inside a datatype"}
      {:ok, tree} -> {:ok, %{name: name, type: tree.type, text: text, tree: tree}}
      {:error, why} -> {:error, "field #{name}: #{why}"}
    end
  end

  defp ctor_atom(name), do: name |> Macro.underscore() |> String.to_atom()

  defp count_limit(items, minimum, label) do
    if length(items) in minimum..255,
      do: :ok,
      else: {:error, "expected #{minimum}..255 #{label}"}
  end

  defp distinct_atoms(ctors) do
    case ctors |> Enum.group_by(& &1.atom) |> Enum.find(fn {_, cs} -> length(cs) > 1 end) do
      nil ->
        :ok

      {atom, cs} ->
        {:error,
         "constructors #{Enum.map_join(cs, ", ", & &1.name)} would all be #{inspect(atom)}"}
    end
  end

  # The rules that need every type parsed: self-reference shapes, no
  # mutual reference, a finite value, and no field of a rejected type.
  # Rejections cascade until a pass finds none.
  defp settle(good, bad) do
    names = Map.new(good, &{&1.name, &1})

    {ok, bad2} =
      Enum.reduce(good, {[], bad}, fn t, {ok, b} ->
        case rules(t, names, b) do
          :ok -> {[t | ok], b}
          {:error, why} -> {ok, Map.put(b, t.name, why)}
        end
      end)

    ok = Enum.reverse(ok)
    if map_size(bad2) == map_size(bad), do: {order(ok), bad2}, else: settle(ok, bad2)
  end

  defp rules(t, names, bad) do
    fields = for c <- t.ctors, f <- c.fields, do: f

    with :ok <- each_ok(fields, &field_rules(&1, t, names, bad)) do
      if finite?({:data, t.name}, names, []),
        do: :ok,
        else: {:error, "no constructor has a finite value"}
    end
  end

  defp each_ok(items, fun) do
    Enum.find_value(items, :ok, fn item ->
      case fun.(item) do
        :ok -> nil
        err -> err
      end
    end)
  end

  defp field_rules(f, t, names, bad) do
    refs = data_names(f.type)
    rejected = Enum.find(refs, &Map.has_key?(bad, &1))
    mutual = Enum.find(refs, &(&1 != t.name and refers?(names[&1], t.name, names, [])))

    cond do
      rejected ->
        {:error, "field #{f.name} holds #{rejected}, which cannot cross: #{bad[rejected]}"}

      mutual ->
        {:error, "field #{f.name}: #{t.name} and #{mutual} refer to each other"}

      t.name in refs ->
        self_shape(f, t)

      true ->
        :ok
    end
  end

  # T inside T: T, List<T> or Maybe<T>, with the list or option kinded like T
  defp self_shape(f, t) do
    kind = list_kind(t)

    ok =
      case f.type do
        {:data, _} -> true
        {:list, {:data, _}} -> generic_kind(f.text, "List") == kind
        {:maybe, {:data, _}} -> generic_kind(f.text, "Maybe") == kind
        _ -> false
      end

    if ok,
      do: :ok,
      else:
        {:error,
         "field #{f.name}: #{t.name} may hold itself only as #{t.name}, " <>
           "List<#{kind}, #{t.name}> or Maybe<#{kind}, #{t.name}>"}
  end

  @doc "The kind a list or option of the datatype's values has: `&2` for Data, else `&1`."
  @spec list_kind(data) :: String.t()
  def list_kind(%{kind: :data}), do: "&2"
  def list_kind(_), do: "&1"

  @doc "The kind index written in a `List<...>` or `Maybe<...>` text (`&1` when omitted), or nil."
  @spec generic_kind(String.t(), String.t()) :: String.t() | nil
  def generic_kind(text, name) do
    # the group is dropped or empty when no kind is written
    case Regex.run(~r/^\+?#{name}<\s*(?:(&[012])\s*,)?/, text) do
      [_, kind] when is_binary(kind) and kind != "" -> kind
      [_ | _] -> "&1"
      nil -> nil
    end
  end

  # whether the type `t` mentions `name` through user types
  defp refers?(nil, _, _, _), do: false

  defp refers?(t, name, names, seen) do
    refs = for c <- t.ctors, f <- c.fields, n <- data_names(f.type), uniq: true, do: n

    name in refs or
      Enum.any?(refs -- seen, fn r ->
        r != t.name and refers?(names[r], name, names, [t.name | seen])
      end)
  end

  @doc "The user datatype names a type mentions."
  @spec data_names(type) :: [String.t()]
  def data_names({:data, n}), do: [n]
  def data_names({:list, t}), do: data_names(t)
  def data_names({:maybe, t}), do: data_names(t)
  def data_names({:map, t}), do: data_names(t)
  def data_names({:tuple, ts}), do: Enum.flat_map(ts, &data_names/1)
  def data_names({:result, e, t}), do: data_names(e) ++ data_names(t)
  def data_names(_), do: []

  @doc "Whether a type mentions a user datatype."
  @spec has_data?(type) :: boolean
  def has_data?(type), do: data_names(type) != []

  @doc "Whether a type has a finite value: some constructor's fields all do."
  @spec finite?(type, %{String.t() => data}, [String.t()]) :: boolean
  def finite?({:data, n}, names, seen) do
    n not in seen and
      case names[n] do
        nil ->
          false

        t ->
          Enum.any?(
            t.ctors,
            &Enum.all?(&1.fields, fn f -> finite?(f.type, names, [n | seen]) end)
          )
      end
  end

  def finite?({:tuple, ts}, names, seen), do: Enum.all?(ts, &finite?(&1, names, seen))

  def finite?({:result, e, t}, names, seen),
    do: finite?(e, names, seen) or finite?(t, names, seen)

  def finite?(_, _, _), do: true

  # dependency order: a type after the types its fields mention
  defp order(types) do
    names = Map.new(types, &{&1.name, &1})
    types |> Enum.reduce([], &visit(&1, names, &2)) |> Enum.reverse()
  end

  defp visit(t, names, acc) do
    if Enum.any?(acc, &(&1.name == t.name)) do
      acc
    else
      deps =
        for c <- t.ctors,
            f <- c.fields,
            n <- data_names(f.type),
            n != t.name,
            uniq: true,
            do: names[n]

      [t | Enum.reduce(deps, acc, &visit(&1, names, &2))]
    end
  end

  # Types
  # =====

  @word_types %{
    "U32" => :u32,
    "Nat" => :nat,
    "String" => :string,
    "Bool" => :bool,
    "Unit" => :unit,
    "F32" => :f32,
    "Char" => :char
  }

  @doc "The marshalled type a Bend type spells, if any; `types` are the user datatypes."
  @spec parse_type(String.t(), map | types) :: {:ok, type} | {:error, String.t()}
  def parse_type(text, types \\ []) do
    with {:ok, tree} <- tree(text, types), do: {:ok, tree.type}
  end

  @doc "The parsed type as a tree that keeps the text of every part (see `t:tree/0`)."
  @spec tree(String.t(), map | types) :: {:ok, tree} | {:error, String.t()}
  def tree(text, types \\ []) do
    ctx = ctx_of(types)

    tokens =
      ~r/[A-Za-z_][\w.]*|&[012]|[^\s]/
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [{at, len}] -> {binary_part(text, at, len), at, at + len} end)

    with {:ok, node, []} <- top_type(tokens, ctx),
         true <- type_depth(node.type) <= 32 do
      {:ok, with_text(node, text)}
    else
      {:error, _} = err -> err
      _ -> {:error, "unsupported type #{text}"}
    end
  end

  defp ctx_of(%{types: _, bad: _} = ctx), do: ctx
  defp ctx_of(types) when is_list(types), do: %{types: Map.new(types, &{&1.name, &1}), bad: %{}}

  defp with_text(%{from: from, to: to, parts: parts} = node, text) do
    %{
      type: node.type,
      text: binary_part(text, from, to - from),
      parts: Enum.map(parts, &with_text(&1, text))
    }
  end

  @doc "The kind index (1 or 2) and value type text of a `Map<...>` type, as written."
  @spec map_parts(String.t()) :: {1 | 2, String.t()}
  def map_parts(text) do
    [_, kind, value] = Regex.run(~r/^\+?Map<\s*(?:(&[12])\s*,)?\s*(.+)>$/s, String.trim(text))
    {if(kind == "&2", do: 2, else: 1), String.trim(value)}
  end

  # A Map is only a whole parameter or result: the shim converts it with
  # Base's Map.from_list and Map.to_list, which cannot reach into a value.
  defp top_type([{"+", _, _}, {"Map", _, _} = m, {"<", _, _} = lt | rest], ctx),
    do: top_type([m, lt | rest], ctx)

  defp top_type([{"Map", from, _}, {"<", _, _} | rest], ctx) do
    rest =
      case rest do
        [{kind, _, _}, {",", _, _} | tail] when kind in ["&1", "&2"] -> tail
        _ -> rest
      end

    case product(rest, 1, ctx) do
      {:ok, value, [{">", _, to} | tail]} ->
        {:ok, node({:map, value.type}, [value], from, to), tail}

      _ ->
        :error
    end
  end

  defp top_type(tokens, ctx), do: product(tokens, 0, ctx)

  defp type_depth({:tuple, ts}), do: 1 + Enum.max(Enum.map(ts, &type_depth/1))
  defp type_depth({:result, e, t}), do: 1 + max(type_depth(e), type_depth(t))
  defp type_depth({:data, _}), do: 0
  defp type_depth({_, t}), do: 1 + type_depth(t)
  defp type_depth(_), do: 0

  # the prelude's Bytes, under whatever alias the file imported it
  defp bytes_type(text), do: if(Regex.match?(~r/^(?:\w+\.)?Bytes$/, text), do: :bytes)

  defp node(type, parts, from, to), do: %{type: type, parts: parts, from: from, to: to}

  # Bounded recursive descent over `{token, from, to}`. Product binds
  # outside generic arguments; parentheses preserve nested tuples instead of
  # flattening them. Every node keeps the span of its text.
  defp product(tokens, depth, ctx) do
    with {:ok, first, rest} <- atom_type(tokens, depth, ctx) do
      product_tail([first], rest, depth, ctx)
    end
  end

  defp product_tail(types, [{"&", _, _} | rest], depth, ctx) when length(types) < 16 do
    with {:ok, next, tail} <- atom_type(rest, depth + 1, ctx) do
      product_tail(types ++ [next], tail, depth, ctx)
    end
  end

  defp product_tail([type], rest, _, _), do: {:ok, type, rest}

  defp product_tail(types, rest, _, _) do
    type = {:tuple, Enum.map(types, & &1.type)}
    {:ok, node(type, types, hd(types).from, List.last(types).to), rest}
  end

  defp atom_type(_, depth, _) when depth > 32, do: :error
  defp atom_type([{"+", _, _} | rest], depth, ctx), do: atom_type(rest, depth + 1, ctx)

  defp atom_type([{"(", from, _} | rest], depth, ctx) do
    case product(rest, depth + 1, ctx) do
      {:ok, type, [{")", _, to} | tail]} -> {:ok, %{type | from: from, to: to}, tail}
      _ -> :error
    end
  end

  defp atom_type([{name, from, _}, {"<", _, _} | rest], depth, ctx)
       when name in ["List", "Maybe", "Result"] do
    rest = drop_kinds(rest, if(name == "Result", do: 2, else: 1))

    with {:ok, first, tail} <- product(rest, depth + 1, ctx) do
      generic(name, first, tail, depth, from, ctx)
    end
  end

  defp atom_type([{word, from, to} | rest], _, ctx) do
    cond do
      type = Map.get(@word_types, word) || bytes_type(word) ->
        {:ok, node(type, [], from, to), rest}

      Map.has_key?(ctx.types, word) ->
        {:ok, node({:data, word}, [], from, to), rest}

      why = ctx.bad[word] ->
        {:error, "#{word} cannot cross: #{why}"}

      true ->
        :error
    end
  end

  defp atom_type([], _, _), do: :error

  defp drop_kinds([{a, _, _}, {",", _, _}, {b, _, _}, {",", _, _} | rest], 2)
       when a in ["&0", "&1", "&2"] and b in ["&0", "&1", "&2"],
       do: rest

  defp drop_kinds([{kind, _, _}, {",", _, _} | rest], 1) when kind in ["&0", "&1", "&2"], do: rest

  defp drop_kinds(tokens, _), do: tokens

  defp generic("List", type, [{">", _, to} | rest], _, from, _),
    do: {:ok, node({:list, type.type}, [type], from, to), rest}

  defp generic("Maybe", type, [{">", _, to} | rest], _, from, _),
    do: {:ok, node({:maybe, type.type}, [type], from, to), rest}

  defp generic("Result", error, [{",", _, _} | rest], depth, from, ctx) do
    case product(rest, depth + 1, ctx) do
      {:ok, value, [{">", _, to} | tail]} ->
        {:ok, node({:result, error.type, value.type}, [error, value], from, to), tail}

      _ ->
        :error
    end
  end

  defp generic(_, _, _, _, _, _), do: :error

  # Specs and typespecs
  # ===================

  @doc """
  The C codec's prefix type grammar: primitives, L/M child, R error/value,
  T arity:fields, D index: for a user datatype (`index` maps names to their
  slot in the generated type table).
  """
  @spec spec(type, %{String.t() => non_neg_integer}) :: String.t()
  def spec(type, index \\ %{})
  def spec(:u32, _), do: "u"
  def spec(:nat, _), do: "n"
  def spec(:string, _), do: "s"
  def spec(:bool, _), do: "b"
  def spec(:unit, _), do: "t"
  def spec(:bytes, _), do: "y"
  def spec(:f32, _), do: "f"
  def spec(:char, _), do: "c"
  def spec({:data, name}, index), do: "D#{Map.fetch!(index, name)}:"
  def spec({:map, t}, i), do: spec({:list, {:tuple, [:string, t]}}, i)
  def spec({:list, t}, i), do: "L" <> spec(t, i)
  def spec({:tuple, ts}, i), do: "T#{length(ts)}:" <> Enum.map_join(ts, &spec(&1, i))
  def spec({:maybe, t}, i), do: "M" <> spec(t, i)
  def spec({:result, e, t}, i), do: "R" <> spec(e, i) <> spec(t, i)

  @doc "The constructor table the Elixir codec needs: per type, each constructor's atom and field types."
  @spec codec_types(types) :: Bendler.Codec.types()
  def codec_types(types) do
    Map.new(types, fn t ->
      {t.name, Enum.map(t.ctors, &{&1.atom, Enum.map(&1.fields, fn f -> f.type end)})}
    end)
  end

  @doc "The Elixir typespec of a marshalled type; a user datatype refers to a local `@type`."
  @spec typespec(type) :: Macro.t()
  def typespec(:u32), do: quote(do: non_neg_integer())
  def typespec(:nat), do: quote(do: non_neg_integer())
  def typespec(:string), do: quote(do: String.t())
  def typespec(:bool), do: quote(do: boolean())
  def typespec(:unit), do: quote(do: :unit)
  def typespec(:bytes), do: quote(do: binary())
  def typespec(:f32), do: quote(do: float() | :nan | :infinity | :neg_infinity)
  def typespec(:char), do: quote(do: char())
  def typespec({:data, name}), do: {type_name(name), [], []}
  def typespec({:map, t}), do: quote(do: %{optional(String.t()) => unquote(typespec(t))})
  def typespec({:list, t}), do: quote(do: [unquote(typespec(t))])
  def typespec({:tuple, ts}), do: {:{}, [], Enum.map(ts, &typespec/1)}
  def typespec({:maybe, t}), do: quote(do: :none | {:some, unquote(typespec(t))})

  def typespec({:result, e, t}),
    do: quote(do: {:ok, unquote(typespec(t))} | {:error, unquote(typespec(e))})

  @doc "The name of the `@type` a user datatype gets in the generated module."
  @spec type_name(String.t()) :: atom
  def type_name(name),
    do: name |> String.replace(".", "_") |> Macro.underscore() |> String.to_atom()

  @doc "The `@type` definition of a user datatype: its constructors as tagged tuples."
  @spec data_typespec(data) :: Macro.t()
  def data_typespec(t) do
    ctors =
      Enum.map(t.ctors, fn
        %{atom: atom, fields: []} -> atom
        %{atom: atom, fields: fields} -> {:{}, [], [atom | Enum.map(fields, &typespec(&1.type))]}
      end)

    union = Enum.reduce(tl(ctors), hd(ctors), &{:|, [], [&2, &1]})
    quote(do: @type(unquote(type_name(t.name))() :: unquote(union)))
  end
end
