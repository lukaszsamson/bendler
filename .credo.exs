%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "mix.exs"], excluded: ["scratch/", "_build/", "deps/"]},
      strict: true,
      checks: %{
        enabled: [],
        extra: [],
        disabled: [
          # long generated-signature lines in the macro and docs
          {Credo.Check.Readability.MaxLineLength, [max_length: 120]}
        ]
      }
    }
  ]
}
