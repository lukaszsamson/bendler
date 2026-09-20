defmodule Bendler.Examples.FibPort do
  @moduledoc "The example Bend module `bend/fib.bend`, run as a port. Start it with `start_link/1`."
  use Bendler, otp_app: :bendler, source: "bend/fib.bend", backend: :port
end
