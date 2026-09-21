defmodule Bendler.Demos.ParticlesPort do
  @moduledoc "Particle tick stream over Port; pair with ParticlesNif for transport comparison."
  use Bendler,
    otp_app: :bendler,
    source: "demos/particles/particles.bend",
    backend: :port,
    threads: 2,
    timeout: 30_000,
    exports: ["advance", "positions", "simulate", "pulse"]
end
