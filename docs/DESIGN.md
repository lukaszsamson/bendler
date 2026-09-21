# Design

Why a Bend program is embedded the way it is, and what the runtime forces.

## The problem: there is no callable def

Bend's C output is one self-contained program with a `main`. There is no
`-o x.so`, no flag for a shared library, and no way to name a root other
than `main`. Upstream records the gap in `WONTFIX.txt` as entry #813, "A
native library target for pure defs": exporting chosen defs with a header
and a lifecycle is planned, not scheduled.

Emitting a shared object is trivial, because `-o x.c` hands over one C file
that clang builds with `-shared -fPIC`. The question is what can be called
inside it, and three properties of the compiler and runtime answer it:

- **Reachability and inlining.** A def gets a function id only if something
  reachable from `main` calls it *and* the compiler chose not to inline it.
  Small and tail-recursive defs are inlined into their callers, so a shim
  `main` that mentions every export keeps them reachable but not
  un-inlined. Naming roots needs a compiler change, in the shape of the
  `js_lib(book, roots)` path the JS lane already has plus a no-inline flag.
- **Layout.** Arguments and results of flat datatypes are multi-word and
  register-passed, packed constructors depend on their field shapes, and
  reusable (`+`) values must be reference-count sealed. Building those by
  hand from C is the fragile part: an early attempt to hand-build a user
  request constructor broke on packing and was dropped.
- **Reentrancy.** `corpus_eval` assumes the loop thread's allocator lane and
  the runtime's single root, so calls would have to be serialised anyway.

So bendler does not call defs. It keeps Bend's own `main` and event loop and
makes the **program** the server: a generated shim declares foreign effects
and loops, reading a function index, pulling each argument, calling the
user's def and replying. The user's def is called by Bend code, so inlining,
flat layouts and register passing stay the compiler's business.

```python
def Bendler.step(fn: U32) -> IO(Unit):
  match fn:
    case 0:
      do IO<Unit>:
        n : Nat <- Bendler.arg(Nat, "n")
        a : U32 <- Bendler.arg(U32, "u")
        +b : U32 <- Bendler.arg(U32, "u")
        Bendler.reply(U32, "u", M.fib(n, a, b))
    ...

def Bendler.serve(fuel: Nat) -> IO(Unit):   # a Nat fuel keeps termination honest
  match fuel:
    case 0n: IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        fn : U32 <- Bendler.fn()
        Bendler.step(fn)
        Bendler.serve(p)
```

The typed `Bendler.arg(-A: Type, spec: String) -> IO(A)` effect lets one C
function serve every type: the spec string tells it what to build, and
Bend's checker guarantees that `A` matches the def's parameter.

The cost of this shape is a hand-off. A direct call would run on the
scheduler thread itself; here every call crosses a pipe or a wake-up and
back. That is the price of not depending on compiler internals.

## The runtime facts that matter for embedding

- **A process-wide singleton.** `corpus_setup()` mmaps an 8 GiB
  `MAP_NORESERVE` arena at a high fixed hint, and all state (the corpus,
  the allocator lanes, the banks, the pool) is global static. Two shared
  objects each get their own copy of those statics and their own arena, so
  several NIF modules coexist, each with its own runtime. One runtime
  cannot be instantiated twice.
- **Threads never exit.** `pool_open()` lazily starts `--threads` worker
  pthreads at the first fork and they run for the process lifetime. Each
  maps a 2 GiB virtual stack, installs a `sigaltstack` and, once,
  process-wide `SIGSEGV` and `SIGBUS` handlers. `io_loop` also sets
  `SIGPIPE` to ignore. There is no stop-and-join protocol, which is why a
  NIF runtime is pinned for the VM's lifetime.
- **Errors leave the process.** `err_fail()` prints and `_exit(1)`s;
  runtime errors (a `Nat` past 2^48-1, a reference count on a closure, an
  alien request) reach it through `err_post`. For the port that is an
  ordinary worker exit; for the NIF the call is rerouted to `bendler_die`,
  which freezes the module instead of taking the VM down.
- **`io_loop` is the entry point and effects are the FFI.** `main` parses
  `--threads` and `--gpu`, calls `corpus_setup` and then `io_loop`, which
  evaluates `main`'s task and drives an event loop: each computation runs
  its pure code, in parallel, up to its next IO request, and the loop
  dispatches that request to a registered effect. A def whose body is
  `import "./x.c"` is implemented by a C function registered from a
  constructor; arguments arrive as boxed terms and results are built with
  `io_str`, `io_node` and `term_pak`. An effect can park on a file
  descriptor (`io_wait_on`) or run blocking work on a helper thread. Only
  the loop thread runs effects.
- **Term layout.** A term is a 64-bit word: a 7-bit tag, 16 bits of aux (a
  constructor or function id) and a 40-bit location. Small constructors are
  packed into the word, larger ones are nodes allocated in a size class, and
  flat datatypes travel unboxed as several registers between segments.
  Base's `String` is a cons list of chars, `List` is cons and nil nodes,
  `Nat` is immediate up to 2^48-1, and `Bool` and `Unit` are packed.

Every value bendler moves is a Base type the runtime lays out itself, built
exactly the way the runtime's own effects build one. That is the reason the
C side never has to know the layout of a user constructor, and the reason a
Bend release that changes the runtime must trigger a rebuild: the C side
uses internals (`io_eff`, `io_str`, `ctr_take`) that carry no ABI promise.

## The two transports

Both share the same shim, the same codec and the same effects. Only the
transport header differs.

- **Port.** Length-prefixed frames on stdin and stdout, with the reads
  parked using `io_wait_on`, so the event loop is never spun. Elixir's
  `{:packet, 4}` matches the 4-byte prefix, and `--threads N` is an
  ordinary command-line argument. A separate POSIX launcher owns the worker
  process group so a deadline or owner death terminates and reaps it. This
  is the default and the recommended backend: it keeps the OS process
  boundary, so a runtime error, a freeze or a hard kill costs a worker, not
  the VM.
- **NIF.** The emitted C is patched (`main` becomes `bend_main`, the
  runtime's signal handlers are dropped so the VM keeps its own, `_exit`
  becomes `bendler_die`) and linked as a shared library with a small
  `erl_nif` entry table. The patches are asserted to have matched, and the
  build fails if any `sigaction`, `signal`, `_exit` or `abort` call
  survives. See [NIF.md](NIF.md) for the call path and the hazards.

## Compared with Rustler and Zigler

| | Rustler | Zigler | Bendler |
|---|---|---|---|
| Build | a Mix compiler runs `cargo`; the crate exports NIFs via macros | `use Zig` compiles at Elixir compile time and runs `zig` | `use Bendler` builds at compile time: `bend -o shim.c`, then `clang` |
| Load | `@on_load` and `:erlang.load_nif` | the same | the same for the NIF, or a supervised port owner |
| Function surface | you write `#[rustler::nif]` functions | you write Zig functions and Zigler generates the stubs | parsed from Bend `def` signatures: every exportable def is a function |
| Term marshalling | `Encoder`/`Decoder`, direct `ERL_NIF_TERM` access | direct `beam.term` access | a frame codec; Bend never touches `ERL_NIF_TERM` |
| Threading | your code on the scheduler, with dirty flags per function | the same | always off-scheduler: the work happens on Bend's own threads |
| Failures | panics become exceptions | Zig errors are mapped | the runtime's `_exit` is intercepted; the runtime freezes, the VM lives |
| Reload | supported with care | supported | not supported |

The structural difference is that Rust and Zig functions *are* C functions a
scheduler can call, while Bend defs are segments of a state machine driven by
a runtime that owns its threads and heap. The natural interface to that is
"message the running program", which is what the port does and what the NIF
does internally.

## Why user datatypes cross as a `Dyn` tree

The compiler decides a constructor's memory layout, flattening fields of
non-recursive types into the parent node, so C cannot build a user
constructor. The prelude instead declares `Dyn`, a small tree of leaves
(`DU`, `DF`, `DN`, `DS`, `DB`) and nodes (`DL` for lists, tuples and
options, `DK{tag, kids}` for constructors and Result), whose constructors C
can build canonically like the Base ones.

For each user type the build generates two Bend defs into the shim,
`Bendler.to_T` and `Bendler.of_T`, which convert between `Dyn` and `T`.
Bend allows neither forward references nor mutual recursion, so each is one
def recursing on a `Nat` fuel, with the loops over the type's own lists and
options inside it. The converters are total: a `Dyn` of the wrong shape,
which validation already excludes, yields the type's first finite
constructor. The rules this imposes on a datatype are in [TYPES.md](TYPES.md).

## Why `Map` crosses as a pair list

Base's `Map<a, V>` is a Patricia trie on string keys. Laying one out from C
would tie bendler to its internals, so the wire form is a list of key and
value pairs and the generated shim wraps the user's def with
`Map.from_list` on the way in and `Map.to_list` on the way out. Building
the trie costs `O(n log n)` string comparisons in Bend, which is the price
of not knowing the layout. Because the conversion wraps the whole call, a
`Map` must be a whole parameter or result.

## Why emitters are template parameters

An emitter is a closure binder, and a Bend function type is Type-kinded: a
closure captures, and `adt_valid` keeps a function field out of `Data`. A
closure binder can therefore never be reusable (`+`), and an ordinary
parameter could be applied only once. A template (`~`) is substituted as
syntax at compile time and has no such limit, so a def that emits more than
once must write `~emit:`. `+emit:` is refused with that reason, and a plain
`emit:` is accepted for a def that emits at most once. The same applies to
an `ask` callback parameter.
