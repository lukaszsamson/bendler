# Composite type contract

Products, Maybe and Result are supported in arguments and return values on
both the Port and the experimental NIF backend. They compose with lists and
the primitive types, including the Bytes prelude.

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
`Result<&2, &2, U32, String>` are accepted by the signature reader. The
unsupported-user-datatype restrictions below still keep a def out.

## Wire and runtime representation

The wire tags are 0 (a transport error alone), 1 `U32`, 2 `Nat`,
3 `String`, 4 `Bool`, 5 `Unit`, 6 `List`, 7 `Bytes`, 8 tuple (a one-byte
arity, then the field values), 9 `None`, 10 `Some` plus value, 11 `Done`
plus value, 12 `Fail` plus error, 13 `F32`, 14 `Char` and 15 a datatype
(constructor index, field count, then the fields). 16 and 17 are not value
tags: they lead an EVENT and an ASK frame. Counts and primitive payloads
are big-endian. The trusted generated prefix type specs use
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
It does not infer arbitrary user-defined constructor layouts. This is
an internal Bend 2.0.20 ABI, not a stable foreign-library ABI. Rebuild
native artifacts when upgrading Bendler or Bend; no mixed-version wire
negotiation is provided. Generated modules receive matching Elixir specs.

See `test/composite_test.exs` for nested values on both transports, and
`demos/csv/` for a parser using tuples, Maybe and Result together.

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
generated module gets a `@type` per datatype, named after it in the same
way (`Shape` is `shape/0`, `Geo.Vec` is `geo_vec/0`); a hand-written
`@type` of that name in the module is a compile error, so use the
generated one. A one-element tuple is not a constructor: `{:dot}` raises,
`:dot` is the value.

Bend's own kinds apply to the fields: a `type T is Data:` may only hold
Data-kinded fields, which rules out tuples (`A & B` is Type-kinded) and
Bytes; hold them in a `type T is Type:` or use a small record datatype
instead of the tuple. A signature may span several lines.

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

## Events: `IO(T)` exports and emitter parameters

A def whose result is `IO(T)`, with `T` one of the marshalled types, is an
export like any other: the shim binds the result in its `do` block and
replies with it. Such a def may also take an **emitter**, a parameter
whose type is `T -> IO(Bool)`:

```python
def fly(~emit: B.Bytes -> IO(Bool), scene: Scene, w: U32, h: U32,
        frames: U32, cx: F32, cz: F32) -> IO(U32):
  ...
```

The emitter is not a wire argument and does not appear in the request
layout (`bendler_specs.h` and `bl_validate` see only the others). The shim
supplies it as `~(x => Bendler.emit(WireT, "<spec>", to_wire(x)))`, with
the same conversion a reply of that type gets, so a `Map` or a user
datatype crosses as an event exactly as it crosses as a result.

Write the emitter with `~`, Bend's template marker, whenever the def emits
more than once. A Bend function type is Type-kinded ("a closure captures",
and `adt_valid` keeps a function field out of `Data`), so a closure binder
can never be `+` and an ordinary parameter could be applied only once. A
template is substituted as syntax at compile time and has no such limit.
A plain `emit:` is accepted for a def that emits at most once; `+emit:` is
refused with that reason. At most one emitter per def, and an emitter
needs an `IO(T)` result.

| Bend | Elixir |
|---|---|
| `def f(~emit: T -> IO(Bool), ..) -> IO(R)` | `f(..)` and `f_stream(..)` |
| an `emit(x)` answering `True` | `{:event, x}` from the stream |
| an `emit(x)` answering `False` | the consumer has gone: stop |
| the def's result | `{:done, result}`, the stream's last element |

### The EVENT frame

Reply frames start with a value tag (`0` is the transport error). `16`
(`BL_EVENT`) is not a value tag: it leads an EVENT frame, whose body is
one encoded value of the emitter's type. `Bendler.Port` tells the two
frame kinds apart by that byte alone.

The host answers every event with an **acknowledgement frame**: one byte,
`1` to go on and `0` to stop, in the ordinary length prefix, on the same
stream that carries requests. The worker parks on it with the runtime's
`io_wait_on` (as `bl_frame_more` does), so the event loop is never spun,
and the in-flight request's bytes stay where they are in the input buffer
while the acknowledgement is consumed from behind them. The request frame
format is unchanged, and `BENDLER_MAX_FRAME` bounds an event like any
other frame.

At most one event is outstanding, so the worker cannot run ahead of its
consumer. A `False` is the only cancellation there is: it is typed, it is
cooperative, and a def that ignores it simply keeps being told `False`.

Events work on Port and the experimental NIF. The NIF delivers a typed
payload in `{:bendler_event, ref, sequence, binary}` and accepts
acknowledgements against the resource and sequence. These envelopes and
native entry points are internal; use the same generated `_stream`
Enumerable on either backend. Sequential IO-only exports and typed ask
callbacks work on both backends too.

## Typed ask callbacks

A function parameter specifically named `ask` with type
`~ask: Request -> IO(Response)` is a host callback. The generated Elixir
function has one additional, final argument, a unary handler with the
corresponding Request-to-Response typespec. Its input and result use the
existing codec types and generated datatype converters. A `Maybe` EOF and
a `Result` application error are ordinary typed responses, not transport errors.

One ASK frame (tag 17 plus an encoded Request) is outstanding at a time.
The response is a length-prefixed encoded Response, checked in Elixir and
again by the C validator before decoding. It is not an event acknowledgement.
An export may have one callback channel: ask or emit, not both. Experimental
NIF uses resource/sequence-checked native replies instead of framed stdin.
An abandoned NIF ask freezes its module; typed application errors do not.
See CONTRACTS.md for handler lifetime, deadlines
and failures, and `demos/csv/ASK.md` for a working chunk-reader contract.
