%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "mix.exs"], excluded: ["scratch/", "_build/", "deps/"]},
      strict: true,
      checks: %{
        extra: [
          # generated-signature docs and specs run long
          {Credo.Check.Readability.MaxLineLength, [max_length: 120]}
        ],
        disabled: []
      }
    }
  ]
}
