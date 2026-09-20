# Run separately, not under mix run (keeps Nx/EXLA out of library dependencies):
#   elixir demos/mandelbrot/bench_nx.exs
#   NX_COMPILER=exla elixir demos/mandelbrot/bench_nx.exs
# Same DEPTHS / ITERATIONS / SAMPLES as bench.exs. EXLA explicitly uses host CPU.
backend = System.get_env("NX_COMPILER", "binary")
unless backend in ["binary", "exla"], do: raise("NX_COMPILER must be binary or exla")

deps =
  if backend == "exla", do: [{:nx, "== 0.10.0"}, {:exla, "== 0.10.0"}], else: [{:nx, "== 0.10.0"}]

Mix.install(deps)
Code.require_file("bench_support.exs", __DIR__)
Code.require_file("lib/mandelbrot_reference.ex", __DIR__)
Code.require_file("nx_kernel.exs", __DIR__)

if backend == "exla" do
  Application.put_env(:exla, :clients, host: [platform: :host])
end

opts =
  if backend == "exla", do: [compiler: EXLA, client: :host], else: [compiler: Nx.Defn.Evaluator]

checksum = Nx.Defn.jit(&MandelbrotNx.checksum/2, opts)
render = Nx.Defn.jit(&MandelbrotNx.render/2, opts)
pixels = Nx.Defn.jit(&MandelbrotNx.pixels/2, opts)
MandelbrotBench.environment()

IO.puts(
  "Nx 0.10.0 compiler=#{backend}; coordinates generated inside kernel; scalar readback included"
)

# Verify full-viewport pixel samples as well as the upstream known checksum.
ids = [0, 4095, 2048 * 4096 + 2730, 4096 * 4096 - 1, 7_654_321]
expected_pixels = Enum.map(ids, &Bendler.Demos.MandelbrotReference.pixel(&1, 51))
actual_pixels = pixels.(Nx.tensor(ids, type: :u32), Nx.u32(51)) |> Nx.to_flat_list()
if actual_pixels != expected_pixels, do: raise("Nx pixel differential failed")
known = checksum.(Nx.iota({256}, type: :u32), Nx.u32(7)) |> Nx.to_number()
if known != 887_240_761, do: raise("Nx upstream known answer failed: #{known}")

for {depth, iterations, count} <- MandelbrotBench.cases() do
  expected = Bendler.Demos.MandelbrotReference.checksum(depth, iterations)

  MandelbrotBench.measure(
    "nx-#{backend} pixels=#{count} iterations=#{iterations}",
    expected,
    fn ->
      render.(Nx.u32(iterations), count: count) |> Nx.to_number()
    end
  )
end
