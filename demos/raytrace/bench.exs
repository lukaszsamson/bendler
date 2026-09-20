# The raytrace demo's end-to-end benchmark.
#
#     MIX_ENV=test mix run demos/raytrace/bench.exs
#
# Optional: WIDTH=640 HEIGHT=480 SAMPLES=5 TILE=64 BATCH=4 THREADS=1,4,12
#
# Five warm samples per case after one warm-up, median/min/max reported.
# Every Port timing includes encoding the scene, the hand-off, the render
# and decoding the pixels; the assembly of tiles into one image happens in
# Elixir and is inside the tiled rows. Run it alone, with nothing else
# competing for the cores.
alias Bendler.Demos.RaytracePort
alias Bendler.Demos.RaytraceReference

width = String.to_integer(System.get_env("WIDTH", "640"))
height = String.to_integer(System.get_env("HEIGHT", "480"))
samples = String.to_integer(System.get_env("SAMPLES", "5"))
tile = String.to_integer(System.get_env("TILE", "64"))
batch = String.to_integer(System.get_env("BATCH", "4"))
cores = System.schedulers_online()

threads =
  System.get_env("THREADS", "1,#{min(4, cores)},#{cores}")
  |> String.split(",")
  |> Enum.map(&String.to_integer/1)
  |> Enum.uniq()

scene = RaytracePort.default_scene()

IO.puts(
  "Elixir #{System.version()} OTP #{System.otp_release()} " <>
    "#{:erlang.system_info(:system_architecture)}"
)

IO.puts(
  "schedulers=#{cores} image=#{width}x#{height} tile=#{tile} batch=#{batch} samples=#{samples}\n"
)

measure = fn label, fun ->
  fun.()

  times =
    for _ <- 1..samples do
      {us, _} = :timer.tc(fun)
      us / 1000
    end
    |> Enum.sort()

  IO.puts(
    "#{String.pad_trailing(label, 38)} median=#{Float.round(Enum.at(times, div(samples, 2)), 3)} ms " <>
      "min=#{Float.round(hd(times), 3)} max=#{Float.round(List.last(times), 3)}"
  )
end

for n <- threads do
  {:ok, pid} = RaytracePort.start_link(threads: n)

  try do
    measure.("bend whole image threads=#{n}", fn ->
      RaytracePort.render_tile(scene, width, height, 0, 0, width, height)
    end)

    measure.("bend tiled #{tile}px batch=#{batch} threads=#{n}", fn ->
      RaytracePort.render(scene, width, height, tile: tile, batch: batch)
    end)
  after
    GenServer.stop(pid)
  end
end

{:ok, pid} = RaytracePort.start_link(threads: cores)

try do
  # the hand-off: a 1x1 render does no measurable work, so what is left is
  # encoding the scene, the frame round trip and decoding three bytes
  measure.("bend 1x1 tile (hand-off only)", fn ->
    RaytracePort.render_tile(scene, width, height, 0, 0, 1, 1)
  end)

  # the same image with no spheres at all: the four rays per pixel still
  # fly and miss, the buffer is still built and still crosses, but no
  # sphere is ever tested. What is left is the plumbing.
  empty =
    RaytracePort.scene(
      [],
      RaytracePort.vec(-3, 8, 1),
      RaytracePort.vec(0, 0, 0),
      RaytracePort.vec(0.1, 0.2, 0.4)
    )

  measure.("bend whole image, no spheres", fn ->
    RaytracePort.render_tile(empty, width, height, 0, 0, width, height)
  end)

  bytes = width * height * 3
  tiles = RaytracePort.tiles(width, height, tile)

  IO.puts(
    "\ntransfer: scene #{length(elem(scene, 1))} spheres in, #{bytes} bytes out " <>
      "(#{Float.round(bytes / 1024 / 1024, 2)} MiB), #{length(tiles)} tiles, " <>
      "#{ceil(length(tiles) / batch)} calls when tiled\n"
  )
after
  GenServer.stop(pid)
end

# the same renderer in Elixir doubles. At 640x480 it takes minutes, so it
# is measured at a quarter of the edge, beside a Bend render of the same
# small image so the comparison is like for like.
ref_w = div(width, 4)
ref_h = div(height, 4)

{:ok, pid} = RaytracePort.start_link(threads: cores)

try do
  measure.("bend #{ref_w}x#{ref_h} threads=#{cores}", fn ->
    RaytracePort.render_tile(scene, ref_w, ref_h, 0, 0, ref_w, ref_h)
  end)
after
  GenServer.stop(pid)
end

measure.("elixir reference #{ref_w}x#{ref_h}", fn ->
  RaytraceReference.render(scene, ref_w, ref_h)
end)
