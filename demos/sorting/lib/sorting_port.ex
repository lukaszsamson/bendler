defmodule Bendler.Demos.SortingPort do
  @moduledoc """
  CPU tree-bitonic sorting and set operations on lists of U32 values.

  Start under a supervisor. `sort/1` preserves duplicates; `unique/1`,
  `union/2`, `intersection/2`, and `difference/2` return ascending unique
  lists. Difference means left minus right. `identity/1` measures transport.
  Inputs need not be sorted or power-of-two sized. No GPU is used. One
  worker is the default: the benchmark found finer-grained parallelism
  slower for these sizes. Override `threads:` at startup to experiment.
  """
  use Bendler,
    otp_app: :bendler,
    source: "demos/sorting/sorting.bend",
    backend: :port,
    threads: 1,
    exports: ["sort", "unique", "union", "intersection", "difference", "identity"]
end
