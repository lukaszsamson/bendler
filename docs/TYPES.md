# Composite type contract

Products, Maybe and Result are supported in arguments and return values on
both the Port and experimental NIF backends. They compose with lists and all
existing primitive types, including the Bytes prelude.

| Bend type / constructor | Elixir value |
|---|---|
| `U32 & String` | `{123, "text"}` |
| `U32 & String & Bool` | `{123, "text", true}` |
| `(U32 & String) & Bool` | `{{123, "text"}, true}` |
| `U32 & (String & Bool)` | `{123, {"text", true}}` |
| `Maybe<T>`: `None`, `Some(value)` | `:none`, `{:some, value}` |
| `Result<E, T>`: `Fail(error)`, `Done(value)` | `{:error, error}`, `{:ok, value}` |

Result's **error type comes first**. It is not restricted to a string or a
particular tuple. A `Fail` is ordinary return data, not a raised exception.
Transport failures still raise `Bendler.Error`. Options remain unambiguous:
`:none` and `{:some, :none}` represent different `Maybe<Maybe<T>>` values.

Use parentheses around product arguments in generics, for example
`Result<(U32 & Nat & String), (List<List<B.Bytes>> & Nat)>`.
Unparenthesized product chains map to flat Elixir tuples, although Bend's
underlying Tuple nodes are right-associated. Explicit parentheses retain
nested Elixir tuple shape. Tuples have 2–16 fields and type-expression nesting is
limited to 32 levels (runtime values may nest up to 2048 levels). Kind-qualified spellings such as `List<&2, U32>` and
`Result<&2, &2, U32, String>` are accepted by the signature reader. Existing
single-line signature and unsupported-user-datatype restrictions remain.

## Wire and runtime representation

New value tags are 8 (tuple: one-byte arity, then field values), 9 (None),
10 (Some plus value), 11 (Done plus value) and 12 (Fail plus error). Tag 0
alone denotes a transport error. Counts and primitive payloads retain the
existing big-endian encoding. The trusted generated prefix type specs use
`T<arity>:<fields>`, `M<child>` and `R<error><value>`; `L<child>` remains a
list. Both type-spec traversal and request validation are bounded.

Native requests are checked against the complete declared type before any
Bend def is dispatched. Inactive variant branches advance the type cursor
without consuming value bytes. Replies are decoded and checked against the
declared return type in Elixir. Empty lists and None therefore cannot desync
the next field's type. Malformed arities, branches, truncated values and
trailing bytes have regression coverage.

The C codec uses Base's canonical Tuple/Some/None/Done/Fail constructors at
the foreign-effect boundary, where the compiler boxes specialized values.
It does not infer arbitrary user-defined constructor layouts. This is still
an internal Bend 2.0.20 ABI, not a new stable foreign-library ABI. Rebuild
native artifacts when upgrading Bendler or Bend; no mixed-version wire
negotiation is provided. Generated modules receive matching Elixir specs.

See `test/composite_test.exs` for nested values and both transports, and
`demos/csv/` for a real parser using all three new type families.

## F32, Char and Map

| Bend | Elixir |
|---|---|
| `F32` | float; `:nan`, `:infinity`, `:neg_infinity` |
| `Char` | integer code point |
| `Map<V>`, `Map<&2, V>` | `%{binary => v}` |

**F32.** Bend 2 has no `F64`, so the boundary is single precision and says
so: an Elixir double is rounded to the nearest single on the way in
(`0.1` arrives as `0.10000000149011612`) and a double past the single
range (`abs(x) >= 3.4028235677973366e38`) raises `ArgumentError` rather
than silently becoming an infinity. Integers are not accepted. The BEAM has
no NaN or infinite floats, so those cross as the atoms `:nan`, `:infinity`
and `:neg_infinity` in both directions. `-0.0` survives. Wire tag 13 holds
the IEEE-754 bits; at runtime an `F32` term is the bare 32-bit word, like a
`U32`, so the C codec copies it without conversion.

**Char.** `Chr{code: U32}` is a newtype the compiler erases: a `Char` term
is the bare code point, and `String` cells hold the same words. Wire tag 14
carries 4 bytes. A request Char must be a code point (`0..0x10FFFF`, no
surrogate) or the native validator refuses the request before dispatch; a
reply Char is checked in Elixir, since Bend can build any `Chr{U32}`.
`List<&2, Char>` is what `String.to_list` returns and is exported as a
charlist.

**Map.** Base's `Map<a, V>` is a Patricia trie on string keys. Laying it out
from C would tie bendler to its internals, so the wire form is the pair list
`List<&k, Sigma<&2, &k, String, _ => V>>` and the generated shim wraps the
user's def: `M.f(Map.from_list(&k, V, xs))` on the way in and
`Map.to_list(&k, V, M.f(...))` on the way out, with `k` the kind the
signature wrote (`Map<V>` is `Map<&1, V>`; `Map.get` and reusable `+`
binders want `Map<&2, V>`). Building the trie is `O(n log n)` string
comparisons in Bend, which is the cost of not knowing the layout. Because
the conversion wraps the whole call, a Map must be a whole parameter or
result; `List<Map<U32>>` or `Map<U32> & U32` keep a def out. Keys are
valid UTF-8 binaries; other keys, including invalid UTF-8 binaries, raise
`ArgumentError` before dispatch. Unlike ordinary String values, keys must not
undergo lossy replacement, since distinct keys could collapse into one entry.
The Elixir side receives the pair list and builds the map in `check/3`;
duplicates cannot occur because the trie has none.

## User datatypes

A `type` declared in the exported file crosses as tagged tuples:

```
type Shape is Data:
  Circle{r: U32}
  Rect{w: U32, h: U32, name: String}
  Dot{}

type Tree is Data:
  Leaf{v: U32}
  Node{l: Tree, ms: Maybe<&2, Tree>, ts: List<&2, Tree>, tag: String}
```

| Bend | Elixir |
|---|---|
| `Circle{3}` | `{:circle, 3}` |
| `Rect{1, 2, "r"}` | `{:rect, 1, 2, "r"}` |
| `Dot{}` | `:dot` |
| `Node{Leaf{1}, None{}, [], "n"}` | `{:node, {:leaf, 1}, :none, [], "n"}` |

The constructor name is underscored (`MNode` is `:m_node`) and the
generated module gets a `@type` per datatype. A one-element tuple is not a
constructor: `{:dot}` raises, `:dot` is the value.

**How it crosses.** The compiler decides a constructor's memory layout
(fields of non-recursive types are flattened into the parent node), so
bendler does not build user constructors from C. Instead the prelude
declares `Dyn`, a small tree of leaves (`DU`, `DF`, `DN`, `DS`, `DB`) and
nodes (`DL` for lists, tuples and options; `DK{tag, kids}` for
constructors and Result), whose constructors C can build canonically like
the Base ones. The shim gets generated defs: `Bendler.to_T(fuel, ds)`
turns a list of `Dyn` into a list of `T` and `Bendler.of_T(fuel, xs)` the
other way. Bend allows neither forward references nor mutual recursion, so
each is one def that recurses on a `Nat` fuel, with the loops over the
type's own lists and options inside it; composite field types that do not
mention `T` get their own acyclic helpers. Wire tag 15 carries the
constructor index and field count; the native validator checks both
against the generated `BENDLER_TYPE_SPECS` table before dispatch, and the
Elixir side converts `{:data, index, fields}` into the tagged tuple in
`check/4`. The converters are total: a `Dyn` of the wrong shape (which
validation excludes) yields the type's first finite constructor.

**Rules**, each reported as the reason a def is skipped:

- 1–255 constructors per type, and 0–255 fields per constructor; the codec
  also rejects oversized caller-supplied tables rather than truncating bytes;
- no type parameters, no erased (`-`) fields, no `Map` field, and a
  `Map<V>` parameter's `V` holds no datatype;
- a type may hold itself only as a whole field `T`, `List<T>` or
  `Maybe<T>`, spelled `List<&2, T>` and `Maybe<&2, T>` when `T is Data`
  (Bend requires that kind anyway); `List<Maybe<T>>` or `(T & U32)` inside
  `T` are not converted;
- two types may not refer to each other (a type may hold another type
  that does not hold it back);
- some constructor must have a finite value, for the fallback.

**Limits and cost.** Values nest up to 2048 constructors deep (a linked
list of 2048 cells; use `List<T>` for sequences). Each node costs a `Dyn`
allocation on both sides plus the converter's pattern matches: a 4093-node
tree crosses into Bend in 1.6 ms and round-trips in 3.6 ms through the
port, and a list of 10,000 three-field records in 5.3 ms, of which the
Elixir encoder is about a third. Prefer flat `List<T>` of small records
over deep recursion when speed matters.
