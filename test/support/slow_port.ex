defmodule Bendler.Test.SlowPort do
  @moduledoc "A port with a short owner-held deadline and a queue of one, for the admission tests."
  use Bendler,
    otp_app: :bendler,
    source: "bend/fib.bend",
    backend: :port,
    exports: [:slow, :fib],
    timeout: 150,
    max_queue: 1,
    threads: 2
end
