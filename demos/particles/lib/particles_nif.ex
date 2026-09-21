defmodule Bendler.Demos.ParticlesNif do
  @moduledoc "Experimental NIF particle tick stream with one outstanding event."
  use Bendler,
    otp_app: :bendler,
    source: "demos/particles/particles.bend",
    backend: :nif,
    threads: 2,
    timeout: 30_000,
    max_waiting: 4,
    exports: ["advance", "positions", "simulate", "pulse"]
end
