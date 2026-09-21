defmodule Bendler.Demos.CsvStreamNif do
  @moduledoc "Experimental incremental CSV NIF kernel; use CsvStream.parse_stream/2 with backend: :nif."
  use Bendler,
    otp_app: :bendler,
    source: "demos/csv/stream.bend",
    backend: :nif,
    threads: 1,
    timeout: 5_000,
    max_waiting: 4,
    exports: ["feed_csv"]
end
