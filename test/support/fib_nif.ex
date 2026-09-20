defmodule Bendler.Examples.FibNif do
  @moduledoc "The example Bend module `bend/fib.bend`, loaded as a NIF."
  use Bendler, otp_app: :bendler, source: "bend/fib.bend", backend: :nif
end
