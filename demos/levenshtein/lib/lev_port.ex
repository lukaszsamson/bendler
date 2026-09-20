defmodule Bendler.Examples.LevPort do
  @moduledoc "Batched Levenshtein distance (`demos/levenshtein/lev.bend`), run as a port. Start it with `start_link/1`."
  use Bendler, otp_app: :bendler, source: "demos/levenshtein/lev.bend", backend: :port
end
