defmodule Bendler.Demos.ParticlesTest do
  use ExUnit.Case, async: false
  alias Bendler.Demos.{Particles, ParticlesNif, ParticlesPort}

  setup do
    start_supervised!(ParticlesPort)
    :ok
  end

  test "Port and NIF streams have identical F32 tick snapshots" do
    cloud = Particles.cloud(16)
    port = Enum.to_list(ParticlesPort.simulate_stream(cloud, 20, 0.01))
    assert Enum.to_list(ParticlesNif.simulate_stream(cloud, 20, 0.01)) == port
    assert List.last(port) == {:done, 20}
    assert length(port) == 21
  end

  test "one oscillator agrees with the integration rule" do
    for module <- [ParticlesPort, ParticlesNif] do
      [{:event, {0, [{x, y}]}}, {:done, 1}] =
        Enum.to_list(module.simulate_stream({:body, 1.0, 0.0, 0.0, 1.0}, 1, 0.01))

      assert_in_delta x, 1.0, 1.0e-6
      assert_in_delta y, 0.01, 1.0e-6
    end
  end

  test "SVG writer streams snapshots and closes the document on early halt" do
    path = Path.join(System.tmp_dir!(), "particles_#{System.unique_integer([:positive])}.svg")
    on_exit(fn -> File.rm(path) end)
    stream = ParticlesNif.simulate_stream(Particles.cloud(4), 100, 0.01) |> Stream.take(3)
    assert Particles.save_svg(stream, path) == 3
    svg = File.read!(path)
    assert String.ends_with?(svg, "</svg>")
    assert length(Regex.scan(~r/<circle /, svg)) == 12
  end
end
