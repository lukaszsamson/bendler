defmodule Bendler.Test.BoomNif do
  @moduledoc "A NIF module of its own, so a runtime error here freezes only its runtime."
  use Bendler,
    otp_app: :bendler,
    source: "bend/fib.bend",
    backend: :nif,
    exports: [:square, :fib, :slow],
    threads: 2,
    timeout: 150,
    max_waiting: 1
end
