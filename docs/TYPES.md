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
nested Elixir tuple shape. Tuples have 2–16 fields and composite nesting is
limited to 32 levels. Kind-qualified spellings such as `List<&2, U32>` and
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
