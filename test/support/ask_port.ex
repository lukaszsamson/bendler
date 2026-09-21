defmodule Bendler.Test.AskPort do
  @moduledoc false
  use Bendler,
    otp_app: :bendler,
    source: "bend/ask.bend",
    exports: ["once", "pull"],
    timeout: 10_000
end
