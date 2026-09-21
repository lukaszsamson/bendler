# BACKEND=nif OUTPUT=/tmp/particles.svg MIX_ENV=test mix run demos/particles/render.exs
alias Bendler.Demos.{Particles, ParticlesNif, ParticlesPort}

module =
  case System.get_env("BACKEND", "port") do
    "port" -> ParticlesPort
    "nif" -> ParticlesNif
    _ -> raise "BACKEND must be port or nif"
  end

n = System.get_env("N", "16") |> String.to_integer()
ticks = System.get_env("TICKS", "180") |> String.to_integer()
path = System.get_env("OUTPUT", Path.join(System.tmp_dir!(), "bendler-particles.svg"))

owner =
  if module == ParticlesPort do
    {:ok, pid} = ParticlesPort.start_link()
    pid
  end

try do
  count = module.simulate_stream(Particles.cloud(n), ticks, 0.03) |> Particles.save_svg(path)
  IO.puts("Wrote #{count} snapshots of #{n} oscillators to #{path}")
after
  if owner, do: GenServer.stop(owner)
end
