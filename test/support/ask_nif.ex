defmodule Bendler.Test.AskNif do
  @moduledoc false
  use Bendler,
    otp_app: :bendler,
    source: "bend/ask.bend",
    backend: :nif,
    exports: ["once", "pull"],
    timeout: 10_000
end
