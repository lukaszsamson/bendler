defmodule Bendler.Demos.CsvStreamPort do
  @moduledoc "Incremental CSV kernel over the supervised Port backend; use CsvStream.parse_stream/2."
  use Bendler,
    otp_app: :bendler,
    source: "demos/csv/stream.bend",
    backend: :port,
    threads: 1,
    timeout: 5_000,
    exports: ["feed_csv"]
end
