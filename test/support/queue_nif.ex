defmodule Bendler.Test.QueueNif do
  @moduledoc "A NIF with room for one waiter behind the call in flight, and a short deadline."
  use Bendler,
    otp_app: :bendler,
    source: "bend/fib.bend",
    backend: :nif,
    exports: [:fib, :slow],
    threads: 2,
    timeout: 150,
    max_waiting: 2
end
