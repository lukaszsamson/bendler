defmodule Bendler.Gen do
  @moduledoc """
  Writes the shim: a Bend file whose `main` serves requests from the host
  through three foreign effects. `Bendler.fn` waits for the next request and
  answers its function index; `Bendler.arg` reads one argument of the type
  its spec spells; `Bendler.reply` writes the result back. The shim matches
  the index in `Bendler.step`, pulls the arguments, calls the user's def and
  replies. Values cross using Base's canonical boxed types and the controlled
  prelude (`Bytes`, `Dyn`); the C side does not infer arbitrary
  user-constructor layouts.

  A user datatype crosses as the prelude's `Dyn` tree. For each such type
  the shim gets generated converters: `Bendler.to_T` turns a list of `Dyn`
  into a list of `T` and `Bendler.of_T` the other way, each one def that
  recurses on a fuel argument (Bend allows no mutual recursion, so the
  loops over a type's own lists and options live inside the def), with
  helpers for the composite field types that do not mention `T`.
  """

  alias Bendler.Sig

  @prelude_alias "BendlerPrelude"
  @p "BendlerPrelude"
  # the converters' fuel: the largest Nat literal, one step per node
  @fuel "4294967295n"

  @doc """
  The shim source for the exports of the module at `import_path`;
  `prelude_path` is the prelude's, or nil; `types` the user datatypes.
  """
  @spec shim(String.t(), [Sig.t()], String.t() | nil, Sig.types()) :: String.t()
  def shim(import_path, sigs, prelude_path \\ nil, types \\ []) do
    index = types |> Enum.with_index() |> Map.new(fn {t, i} -> {t.name, i} end)
    st = %{defs: [], helpers: %{}, n: 0, types: Map.new(types, &{&1.name, &1}), index: index}
    st = if uses_data?(sigs), do: dyn_defs(types, st), else: st

    {arms, st} =
      sigs
      |> Enum.with_index()
      |> Enum.map_reduce(st, fn {sig, i}, st -> arm(sig, i, st) end)

    prelude = if prelude_path, do: "import #{prelude_path} as #{@prelude_alias}\n", else: ""

    """
    import Base
    import #{import_path} as M
    #{prelude}
    def Bendler.fn() -> IO(U32):
      import "./bendler_fn.c"
      import "./bendler_fn.js"

    def Bendler.arg(-A: Type, spec: String) -> IO(A):
      import "./bendler_arg.c"
      import "./bendler_arg.js"

    def Bendler.reply(-A: Type, spec: String, x: A) -> IO(Unit):
      import "./bendler_reply.c"
      import "./bendler_reply.js"
    #{emit_effect(sigs)}
    #{st.defs |> Enum.reverse() |> Enum.join("\n")}
    def Bendler.step(fn: U32) -> IO(Unit):
      match fn:
    #{Enum.join(arms, "\n")}
        case _:
          Bendler.reply(Unit, "!", Unit{})

    def Bendler.serve(fuel: Nat) -> IO(Unit):
      match fuel:
        case 0n:
          IO.pure(Unit, Unit{})
        case 1n+p:
          do IO<Unit>:
            fn : U32 <- Bendler.fn()
            Bendler.step(fn)
            Bendler.serve(p)

    def main() -> IO(Unit):
      Bendler.serve(4294967295n)
    """
  end

  defp arm(%Sig{name: name, params: params, ret: {ret_t, ret_text}} = sig, i, st) do
    {binds, st} =
      Enum.map_reduce(params, st, fn p, st ->
        data = Sig.has_data?(p.type)
        # a Dyn is linear: the user's `+` applies to the converted value
        q = if p.reusable and not data, do: "+", else: ""
        t = wire_type(p.type, p.text, st)
        spec = inspect(Sig.spec(p.type, st.index))
        {"        #{q}#{p.name} : #{t} <- Bendler.arg(#{t}, #{spec})", st}
      end)

    {args, st} = Enum.map_reduce(params, st, &from_wire(&1.type, &1.text, &1.name, &2))
    {args, st} = with_emitter(args, sig, st)
    call = "M.#{name}(#{Enum.join(args, ", ")})"

    reply_head =
      "Bendler.reply(#{wire_type(ret_t, ret_text, st)}, #{inspect(Sig.spec(ret_t, st.index))}, "

    {steps, st} =
      if sig.effectful do
        # the def answers IO(T): bind the result, then reply with it
        {wired, st} = to_wire(ret_t, ret_text, "r", st)

        {[
           "        r : #{shim_type(ret_text, st)} <- #{call}",
           "        #{reply_head}#{wired})"
         ], st}
      else
        {wired, st} = to_wire(ret_t, ret_text, call, st)
        {["        #{reply_head}#{wired})"], st}
      end

    arm = """
        case #{i}:
          do IO<Unit>:
    #{Enum.join(binds ++ steps, "\n")}\
    """

    {arm, st}
  end

  # The emitter argument the shim supplies: a lambda over `Bendler.emit`
  # of the event type, converted to the wire form exactly as a reply is.
  # `~` is the template form, which is what a def emitting more than once
  # needs (a Bend function type is Type-kinded, so a closure binder can
  # never be reusable).
  defp with_emitter(args, %Sig{emitter: nil}, st), do: {args, st}

  defp with_emitter(args, %Sig{emitter: e, emitter_at: at}, st) do
    {wired, st} = to_wire(e.type, e.text, "x", st)
    t = wire_type(e.type, e.text, st)
    lam = "x => Bendler.emit(#{t}, #{inspect(Sig.spec(e.type, st.index))}, #{wired})"
    {List.insert_at(args, at, if(e.template, do: "~(#{lam})", else: lam)), st}
  end

  defp emit_effect(sigs) do
    if uses_emit?(sigs) do
      """

      def Bendler.emit(-A: Type, spec: String, x: A) -> IO(Bool):
        import "./bendler_emit.c"
        import "./bendler_emit.js"
      """
    else
      ""
    end
  end

  # A Map crosses as Base's pair list of the same kind, a user datatype as
  # a Dyn; everything else as written.
  defp wire_type({:map, _}, text, st) do
    {k, v} = Sig.map_parts(text)
    "List<&#{k}, Sigma<&2, &#{k}, String, _ => #{shim_type(v, st)}>>"
  end

  defp wire_type(type, text, st) do
    if Sig.has_data?(type), do: "#{@p}.Dyn", else: shim_type(text, st)
  end

  defp from_wire({:map, _}, text, expr, st), do: {map_conv("from_list", text, expr, st), st}

  defp from_wire(type, text, expr, st) do
    if Sig.has_data?(type),
      do: to_expr(tree!(text, st), expr, %{fuel: @fuel, self: nil}, st),
      else: {expr, st}
  end

  defp to_wire({:map, _}, text, expr, st), do: {map_conv("to_list", text, expr, st), st}

  defp to_wire(type, text, expr, st) do
    if Sig.has_data?(type),
      do: of_expr(tree!(text, st), expr, %{fuel: @fuel, self: nil}, st),
      else: {expr, st}
  end

  defp map_conv(fun, text, expr, st) do
    {k, v} = Sig.map_parts(text)
    "Map.#{fun}(&#{k}, #{shim_type(v, st)}, #{expr})"
  end

  defp tree!(text, st) do
    {:ok, tree} = Sig.tree(text, Map.values(st.types))
    tree
  end

  # The user's alias for the prelude's Bytes becomes the shim's, and the
  # user's datatypes are reached through the module alias.
  defp shim_type(text, st) do
    text = Regex.replace(~r/\b(?:\w+\.)?Bytes\b/, text, "#{@prelude_alias}.Bytes")

    Enum.reduce(Map.keys(st.types), text, fn name, text ->
      Regex.replace(~r/(?<![\w.])#{Regex.escape(name)}\b/, text, "M.#{name}")
    end)
  end

  @doc "Whether any export carries the prelude's Bytes."
  @spec uses_bytes?([Sig.t()]) :: boolean
  def uses_bytes?(sigs), do: Enum.any?(sigs, &any_type?(&1, fn t -> t == :bytes end))

  @doc "Whether any export carries a user datatype."
  @spec uses_data?([Sig.t()]) :: boolean
  def uses_data?(sigs), do: Enum.any?(sigs, &any_type?(&1, fn t -> match?({:data, _}, t) end))

  @doc "Whether any export takes an emitter parameter."
  @spec uses_emit?([Sig.t()]) :: boolean
  def uses_emit?(sigs), do: Enum.any?(sigs, &(&1.emitter != nil))

  defp any_type?(sig, pred) do
    emitted = if sig.emitter, do: [sig.emitter.type], else: []

    Enum.any?(
      [elem(sig.ret, 0) | emitted] ++ Enum.map(sig.params, & &1.type),
      &walk?(&1, pred)
    )
  end

  defp walk?(t, pred) do
    pred.(t) or
      case t do
        {:tuple, ts} -> Enum.any?(ts, &walk?(&1, pred))
        {:result, e, v} -> walk?(e, pred) or walk?(v, pred)
        {_, inner} -> walk?(inner, pred)
        _ -> false
      end
  end

  # Converters
  # ==========

  # The defs every program with user datatypes gets, then each type's
  # converters in dependency order (helpers are appended as they are needed).
  defp dyn_defs(types, st) do
    st = add_def(st, touch_def())
    Enum.reduce(types, st, &type_defs/2)
  end

  defp touch_def do
    """
    # every Dyn constructor, reachable from main so the host may build any
    def Bendler.dyn_touch(n: U32) -> #{@p}.Dyn:
      match n:
        case 0:
          #{@p}.DU{0}
        case 1:
          #{@p}.DF{0.0}
        case 2:
          #{@p}.DN{0n}
        case 3:
          #{@p}.DS{""}
        case 4:
          #{@p}.DB{0, Array.new(U32, 0n, 0)}
        case 5:
          #{@p}.DL{[]}
        case _:
          #{@p}.DK{0, []}

    def Bendler.head_Dyn(xs: List<&1, #{@p}.Dyn>) -> #{@p}.Dyn:
      match xs:
        case x <> _:
          x
        case Nil{}:
          Bendler.dyn_touch(6)
    """
  end

  defp add_def(st, src), do: %{st | defs: [src | st.defs]}

  defp type_defs(t, st) do
    n = t.name
    k = Sig.list_kind(t)
    tn = "M.#{n}"
    ctx = %{fuel: "p", self: n}

    {to_arms, st} =
      t.ctors
      |> Enum.with_index()
      |> Enum.map_reduce(st, fn {c, i}, st -> to_arm(c, i, n, ctx, st) end)

    {of_arms, st} =
      t.ctors
      |> Enum.with_index()
      |> Enum.map_reduce(st, fn {c, i}, st -> of_arm(c, i, n, ctx, st) end)

    src = """
    def Bendler.default_#{n}() -> #{tn}:
      #{default_ctor(t, st)}

    def Bendler.head_#{n}(xs: List<#{k}, #{tn}>) -> #{tn}:
      match xs:
        case x <> _:
          x
        case Nil{}:
          Bendler.default_#{n}()

    def Bendler.maybe_#{n}(xs: List<#{k}, #{tn}>) -> Maybe<#{k}, #{tn}>:
      match xs:
        case x <> _:
          Some{x}
        case Nil{}:
          None{}

    def Bendler.opt_#{n}(m: Maybe<#{k}, #{tn}>) -> List<#{k}, #{tn}>:
      match m:
        case None{}:
          []
        case Some{x}:
          [x]

    def Bendler.to_#{n}(fuel: Nat, ds: List<&1, #{@p}.Dyn>) -> List<#{k}, #{tn}>:
      match fuel:
        case 0n:
          []
        case 1n++p:
          match ds:
            case Nil{}:
              []
            case d <> rest:
              match d:
                case #{@p}.DK{tag, kids}:
                  match tag:
    #{Enum.join(to_arms, "\n")}
                    case _:
                      Bendler.to_#{n}(p, rest)
                case _:
                  Bendler.to_#{n}(p, rest)

    def Bendler.of_#{n}(fuel: Nat, xs: List<#{k}, #{tn}>) -> List<&1, #{@p}.Dyn>:
      match fuel:
        case 0n:
          []
        case 1n++p:
          match xs:
            case Nil{}:
              []
            case x <> rest:
              match x:
    #{Enum.join(of_arms, "\n")}
    """

    add_def(st, src)
  end

  # `case i:` of to_T: the constructor's fields are pulled from the kids
  # one nested match at a time (Bend matches binders in binding order), then
  # converted; a short kids list skips the value
  defp to_arm(%{name: cname, fields: []}, i, n, _ctx, st) do
    {"                case #{i}:\n" <>
       "                  M.#{cname}{} <> Bendler.to_#{n}(p, rest)", st}
  end

  defp to_arm(%{name: cname, fields: fields}, i, n, ctx, st) do
    {exprs, st} =
      fields
      |> Enum.with_index()
      |> Enum.map_reduce(st, fn {f, j}, st -> to_expr(f.tree, "k#{j}", ctx, st) end)

    skip = "Bendler.to_#{n}(p, rest)"
    value = "M.#{cname}{#{Enum.join(exprs, ", ")}} <> #{skip}"
    body = pull("kids", length(fields), 18, value, skip)
    {"                case #{i}:\n" <> body, st}
  end

  # nested `case kj <> rj:` matches over `list`, `count` deep, `indent` spaces in
  defp pull(list, count, indent, value, skip) do
    Enum.reduce((count - 1)..0//-1, value, fn j, inner ->
      pad = String.duplicate(" ", indent + 4 * j)
      rest = if j == count - 1, do: "_", else: "r#{j}"

      "#{pad}match #{list_at(list, j)}:\n" <>
        "#{pad}  case k#{j} <> #{rest}:\n" <>
        "#{inner}\n" <>
        "#{pad}  case Nil{}:\n" <>
        "#{pad}    #{skip}"
    end)
    |> then(fn src ->
      # the innermost value sits under the deepest case
      String.replace(
        src,
        "\n#{value}\n",
        "\n#{String.duplicate(" ", indent + 4 * count)}#{value}\n"
      )
    end)
  end

  defp list_at(list, 0), do: list
  defp list_at(_, j), do: "r#{j - 1}"

  defp of_arm(%{name: cname, fields: fields}, i, n, ctx, st) do
    vars = Enum.map(0..(length(fields) - 1)//1, &"f#{&1}")

    {exprs, st} =
      fields
      |> Enum.zip(vars)
      |> Enum.map_reduce(st, fn {f, v}, st -> of_expr(f.tree, v, ctx, st) end)

    pat = if fields == [], do: "M.#{cname}{}", else: "M.#{cname}{#{Enum.join(vars, ", ")}}"

    {"                case #{pat}:\n" <>
       "                  #{@p}.DK{#{i}, [#{Enum.join(exprs, ", ")}]} <> Bendler.of_#{n}(p, rest)",
     st}
  end

  # the first constructor whose fields all have a finite value
  defp default_ctor(t, st) do
    c =
      Enum.find(
        t.ctors,
        &Enum.all?(&1.fields, fn f -> Sig.finite?(f.type, st.types, [t.name]) end)
      )

    "M.#{c.name}{#{Enum.map_join(c.fields, ", ", &default_expr(&1.type, st))}}"
  end

  defp default_expr(:u32, _), do: "0"
  defp default_expr(:nat, _), do: "0n"
  defp default_expr(:f32, _), do: "0.0"
  defp default_expr(:char, _), do: "Char.from_u32(0)"
  defp default_expr(:string, _), do: "\"\""
  defp default_expr(:bool, _), do: "False{}"
  defp default_expr(:unit, _), do: "Unit{}"
  defp default_expr(:bytes, _), do: "#{@p}.Bytes{0, Array.new(U32, 0n, 0)}"
  defp default_expr({:list, _}, _), do: "[]"
  defp default_expr({:maybe, _}, _), do: "None{}"
  defp default_expr({:data, n}, _), do: "Bendler.default_#{n}()"
  defp default_expr({:tuple, ts}, st), do: "(#{Enum.map_join(ts, ", ", &default_expr(&1, st))})"

  defp default_expr({:result, e, t}, st) do
    if Sig.finite?(e, st.types, []),
      do: "Fail{#{default_expr(e, st)}}",
      else: "Done{#{default_expr(t, st)}}"
  end

  # The Bend expression converting the Dyn `var` into a value of the tree's
  # type. Leaves use the prelude; a datatype its converter; the enclosing
  # type's own lists and options its converter directly (no helper may call
  # back into it); everything else a helper generated for the text.
  @to_leaf %{
    u32: "#{@p}.Dyn.u32",
    nat: "#{@p}.Dyn.nat",
    f32: "#{@p}.Dyn.f32",
    char: "#{@p}.Dyn.chr",
    string: "#{@p}.Dyn.str",
    bool: "#{@p}.Dyn.bool",
    unit: "#{@p}.Dyn.unit",
    bytes: "#{@p}.Dyn.bytes"
  }

  defp to_expr(%{type: leaf}, var, _ctx, st) when is_map_key(@to_leaf, leaf),
    do: {"#{@to_leaf[leaf]}(#{var})", st}

  defp to_expr(%{type: type, text: text, parts: parts}, var, ctx, st) do
    case type do
      {:data, n} ->
        {"Bendler.head_#{n}(Bendler.to_#{n}(#{ctx.fuel}, [#{var}]))", st}

      {:list, {:data, n}} when n == ctx.self ->
        {"Bendler.to_#{n}(#{ctx.fuel}, #{@p}.Dyn.list(#{var}))", st}

      {:maybe, {:data, n}} when n == ctx.self ->
        {"Bendler.maybe_#{n}(Bendler.to_#{n}(#{ctx.fuel}, #{@p}.Dyn.list(#{var})))", st}

      _ ->
        {name, st} = helper(:to, type, text, parts, st)
        {"#{name}(#{ctx.fuel}, #{var})", st}
    end
  end

  @of_leaf %{
    u32: "#{@p}.DU{$}",
    nat: "#{@p}.DN{$}",
    f32: "#{@p}.DF{$}",
    char: "#{@p}.DU{Char.to_u32($)}",
    string: "#{@p}.DS{$}",
    bool: "#{@p}.DU{Bool.to_u32($)}",
    unit: "#{@p}.Dyn.of_unit($)",
    bytes: "#{@p}.Dyn.of_bytes($)"
  }

  defp of_expr(%{type: leaf}, var, _ctx, st) when is_map_key(@of_leaf, leaf),
    do: {String.replace(@of_leaf[leaf], "$", var), st}

  defp of_expr(%{type: type, text: text, parts: parts}, var, ctx, st) do
    case type do
      {:data, n} ->
        {"Bendler.head_Dyn(Bendler.of_#{n}(#{ctx.fuel}, [#{var}]))", st}

      {:list, {:data, n}} when n == ctx.self ->
        {"#{@p}.DL{Bendler.of_#{n}(#{ctx.fuel}, #{var})}", st}

      {:maybe, {:data, n}} when n == ctx.self ->
        {"#{@p}.DL{Bendler.of_#{n}(#{ctx.fuel}, Bendler.opt_#{n}(#{var}))}", st}

      _ ->
        {name, st} = helper(:of, type, text, parts, st)
        {"#{name}(#{ctx.fuel}, #{var})", st}
    end
  end

  # A helper def per (direction, type text): its sub-helpers come first.
  defp helper(dir, type, text, parts, st) do
    key = {dir, String.replace(text, ~r/\s+/, " ")}

    case st.helpers[key] do
      nil ->
        name = "Bendler.#{dir}_#{st.n}"
        st = %{st | helpers: Map.put(st.helpers, key, name), n: st.n + 1}
        ctx = %{fuel: "fuel", self: nil}
        {src, st} = helper_src(dir, name, type, shim_type(text, st), parts, ctx, st)
        {name, add_def(st, src)}

      name ->
        {name, st}
    end
  end

  defp helper_src(:to, name, {:list, _}, text, [elem], ctx, st) do
    {e, st} = to_expr(elem, "d", ctx, st)

    {"""
     def #{name}.go(+fuel: Nat, ds: List<&1, #{@p}.Dyn>) -> #{text}:
       match ds:
         case Nil{}:
           []
         case d <> rest:
           #{e} <> #{name}.go(fuel, rest)

     def #{name}(+fuel: Nat, d: #{@p}.Dyn) -> #{text}:
       match d:
         case #{@p}.DL{xs}:
           #{name}.go(fuel, xs)
         case _:
           []
     """, st}
  end

  defp helper_src(:to, name, {:maybe, _}, text, [elem], ctx, st) do
    {e, st} = to_expr(elem, "d", ctx, st)

    {"""
     def #{name}.go(+fuel: Nat, ds: List<&1, #{@p}.Dyn>) -> #{text}:
       match ds:
         case Nil{}:
           None{}
         case d <> _:
           Some{#{e}}

     def #{name}(+fuel: Nat, d: #{@p}.Dyn) -> #{text}:
       match d:
         case #{@p}.DL{xs}:
           #{name}.go(fuel, xs)
         case _:
           None{}
     """, st}
  end

  defp helper_src(:to, name, {:tuple, _} = type, text, parts, ctx, st) do
    {exprs, st} =
      parts
      |> Enum.with_index()
      |> Enum.map_reduce(st, fn {part, j}, st -> to_expr(part, "k#{j}", ctx, st) end)

    dflt = default_expr(type, st)
    body = pull("ds", length(parts), 4, "(#{Enum.join(exprs, ", ")})", dflt)

    {"""
     def #{name}.go(+fuel: Nat, ds: List<&1, #{@p}.Dyn>) -> #{text}:
     #{body}

     def #{name}(+fuel: Nat, d: #{@p}.Dyn) -> #{text}:
       match d:
         case #{@p}.DL{xs}:
           #{name}.go(fuel, xs)
         case _:
           #{dflt}
     """, st}
  end

  defp helper_src(:to, name, {:result, _, _} = type, text, [err, val], ctx, st) do
    {e, st} = to_expr(err, "k", ctx, st)
    {v, st} = to_expr(val, "k", ctx, st)
    dflt = default_expr(type, st)

    {"""
     def #{name}(+fuel: Nat, d: #{@p}.Dyn) -> #{text}:
       match d:
         case #{@p}.DK{tag, kids}:
           match tag:
             case 1:
               match kids:
                 case k <> _:
                   Done{#{v}}
                 case Nil{}:
                   #{dflt}
             case _:
               match kids:
                 case k <> _:
                   Fail{#{e}}
                 case Nil{}:
                   #{dflt}
         case _:
           #{dflt}
     """, st}
  end

  defp helper_src(:of, name, {:list, _}, text, [elem], ctx, st) do
    {e, st} = of_expr(elem, "x", ctx, st)

    {"""
     def #{name}.go(+fuel: Nat, xs: #{text}) -> List<&1, #{@p}.Dyn>:
       match xs:
         case Nil{}:
           []
         case x <> rest:
           #{e} <> #{name}.go(fuel, rest)

     def #{name}(+fuel: Nat, x: #{text}) -> #{@p}.Dyn:
       #{@p}.DL{#{name}.go(fuel, x)}
     """, st}
  end

  defp helper_src(:of, name, {:maybe, _}, text, [elem], ctx, st) do
    {e, st} = of_expr(elem, "y", ctx, st)

    {"""
     def #{name}(+fuel: Nat, x: #{text}) -> #{@p}.Dyn:
       match x:
         case None{}:
           #{@p}.DL{[]}
         case Some{y}:
           #{@p}.DL{[#{e}]}
     """, st}
  end

  defp helper_src(:of, name, {:tuple, _}, text, parts, ctx, st) do
    vars = Enum.map(0..(length(parts) - 1)//1, &"a#{&1}")

    {exprs, st} =
      parts
      |> Enum.zip(vars)
      |> Enum.map_reduce(st, fn {part, v}, st -> of_expr(part, v, ctx, st) end)

    {"""
     def #{name}(+fuel: Nat, x: #{text}) -> #{@p}.Dyn:
       (#{Enum.join(vars, ", ")}) = x
       #{@p}.DL{[#{Enum.join(exprs, ", ")}]}
     """, st}
  end

  defp helper_src(:of, name, {:result, _, _}, text, [err, val], ctx, st) do
    {e, st} = of_expr(err, "y", ctx, st)
    {v, st} = of_expr(val, "y", ctx, st)

    {"""
     def #{name}(+fuel: Nat, x: #{text}) -> #{@p}.Dyn:
       match x:
         case Fail{y}:
           #{@p}.DK{0, [#{e}]}
         case Done{y}:
           #{@p}.DK{1, [#{v}]}
     """, st}
  end

  # Headers and glue
  # ================

  @doc """
  The per-module C header naming each export's argument and result specs,
  and the user datatypes' constructor specs (`count:` then per constructor
  `fields:` and the field specs), in the order `D<index>:` refers to.
  """
  @spec specs_h([Sig.t()], Sig.types()) :: String.t()
  def specs_h(sigs, types \\ []) do
    index = types |> Enum.with_index() |> Map.new(fn {t, i} -> {t.name, i} end)

    args =
      Enum.map_join(sigs, ", ", fn s ->
        inspect(Enum.map_join(s.params, "", &Sig.spec(&1.type, index)))
      end)

    rets = Enum.map_join(sigs, ", ", fn %{ret: {t, _}} -> inspect(Sig.spec(t, index)) end)

    type_specs =
      Enum.map_join(types, ", ", fn t ->
        ctors =
          Enum.map_join(t.ctors, "", fn c ->
            "#{length(c.fields)}:" <> Enum.map_join(c.fields, "", &Sig.spec(&1.type, index))
          end)

        inspect("#{length(t.ctors)}:" <> ctors)
      end)

    empty = fn list -> if list == [], do: "\"\"", else: "" end

    """
    // generated by bendler: the exports' type specs, in function-index order
    #define BENDLER_FN_COUNT #{length(sigs)}
    static const char* BENDLER_ARG_SPECS[] = { #{args}#{empty.(sigs)} };
    static const char* BENDLER_RET_SPECS[] = { #{rets}#{empty.(sigs)} };
    // the user datatypes' constructor specs, in D<index>: order
    #define BENDLER_TYPE_COUNT #{length(types)}
    static const char* BENDLER_TYPE_SPECS[] = { #{type_specs}#{empty.(types)} };
    """
  end

  @doc "The NIF glue with the loading module's name filled in."
  @spec nif_glue(String.t(), module) :: String.t()
  def nif_glue(template, module) do
    String.replace(template, "BENDLER_MODULE", "Elixir." <> inspect(module))
  end

  @doc """
  Rewrites the emitted C for hosting inside the BEAM: `main` becomes
  `bend_main`, the runtime's signal handlers stay uninstalled (the VM owns
  them), and its `_exit` on a runtime error becomes `bendler_die`, which
  freezes the runtime instead of killing the VM.
  """
  @spec host_in_beam!(String.t()) :: String.t()
  def host_in_beam!(c_source) do
    patches = [
      {~r/^int main\(int argc, char\*\* argv\) \{$/m, "int bend_main(int argc, char** argv) {",
       1},
      {~r/^  sigaction\(SIG[A-Z]+, &sa, NULL\);$/m, "", 2},
      {~r/^  signal\(SIGPIPE, SIG_IGN\);$/m, "", 1},
      {~r/^  _exit\(1\);$/m, "  bendler_die(1);", 1}
    ]

    body =
      Enum.reduce(patches, c_source, fn {re, with, expected}, src ->
        found = length(Regex.scan(re, src))

        if found != expected do
          raise Bendler.Error,
                "the emitted C does not match this bendler: #{inspect(re.source)} found #{found} times, expected #{expected}"
        end

        String.replace(src, re, with)
      end)

    # nothing that seizes the process may survive the patching (exit stays
    # only in cli_fail, whose arguments bendler controls)
    survivors =
      Enum.flat_map(
        [~r/^\s*sigaction\(/m, ~r/^\s*signal\(/m, ~r/\b_exit\(/, ~r/^\s*abort\(/m],
        &Regex.scan(&1, body)
      )

    if survivors != [] do
      raise Bendler.Error,
            "the emitted C still calls #{inspect(survivors)} after patching; refusing to host it in the BEAM"
    end

    "void bendler_die(int code);\nint bend_main(int argc, char** argv);\n" <> body
  end
end
