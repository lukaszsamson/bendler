defmodule Bendler.Examples.MurmurPort do
  @moduledoc "Murmur3 x86_32 (`demos/murmur3/murmur.bend`), run as a port. Bytes cross as `List<U32>`. Start it with `start_link/1`."
  use Bendler, otp_app: :bendler, source: "demos/murmur3/murmur.bend", backend: :port
end
