defmodule Bendler.Demos.CsvAskNif do
  @moduledoc "Experimental NIF CSV aggregation with typed chunk callbacks. Handler failure freezes this module."
  use Bendler,
    otp_app: :bendler,
    source: "demos/csv/ask.bend",
    backend: :nif,
    threads: 1,
    timeout: 30_000,
    exports: ["aggregate"]
end
