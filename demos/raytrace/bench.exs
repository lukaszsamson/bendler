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

# The fly-through: one call, many frames, each acknowledged
# =========================================================
#
# FLY_FRAMES=24 FLY_WIDTH=320 FLY_HEIGHT=240 override the size of this
# section, which is smaller than the single-image one above because it
# renders every frame.

fly_frames = String.to_integer(System.get_env("FLY_FRAMES", "24"))
fly_w = String.to_integer(System.get_env("FLY_WIDTH", "320"))
fly_h = String.to_integer(System.get_env("FLY_HEIGHT", "240"))

frames_of = fn stream ->
  Stream.flat_map(stream, fn
    {:event, rgb} -> [rgb]
    {:done, _} -> []
  end)
end

IO.puts("\nfly-through #{fly_w}x#{fly_h} frames=#{fly_frames}\n")

{:ok, pid} = RaytracePort.start_link(threads: cores)

try do
  # time to the first frame: the whole turn is one call, so this is the
  # render of frame 0 plus one event round trip, not the whole turn
  measure.("fly: time to first frame", fn ->
    scene |> RaytracePort.fly(fly_w, fly_h, fly_frames) |> frames_of.() |> Enum.take(1)
  end)

  # per-frame latency: the gaps between consecutive frames arriving
  gaps =
    scene
    |> RaytracePort.fly(fly_w, fly_h, fly_frames)
    |> frames_of.()
    |> Enum.reduce({System.monotonic_time(:microsecond), []}, fn _, {t, acc} ->
      now = System.monotonic_time(:microsecond)
      {now, [(now - t) / 1000 | acc]}
    end)
    |> elem(1)
    |> Enum.sort()

  IO.puts(
    "#{String.pad_trailing("fly: per-frame latency", 38)} " <>
      "median=#{Float.round(Enum.at(gaps, div(length(gaps), 2)), 3)} ms " <>
      "min=#{Float.round(hd(gaps), 3)} max=#{Float.round(List.last(gaps), 3)}"
  )

  # the acknowledgement round trip: one call emitting N frames against N
  # separate whole-image calls of the same size. The difference is the
  # per-frame request/reply the events replace, minus the ack they add.
  measure.("fly: #{fly_frames} frames in one call", fn ->
    scene |> RaytracePort.fly(fly_w, fly_h, fly_frames) |> Enum.to_list()
  end)

  measure.("fly: #{fly_frames} separate render calls", fn ->
    for _ <- 1..fly_frames,
        do: RaytracePort.render_tile(scene, fly_w, fly_h, 0, 0, fly_w, fly_h)
  end)

  # cancellation latency: from the third frame of a 100000-frame turn
  # arriving to the port answering a trivial call again. The `Enum.take`
  # refuses the next event and waits for the def to return inside it.
  cancels =
    for _ <- 1..samples do
      last =
        scene
        |> RaytracePort.fly(fly_w, fly_h, 100_000)
        |> frames_of.()
        |> Stream.map(fn _ -> System.monotonic_time(:microsecond) end)
        |> Enum.take(3)
        |> List.last()

      19_281 = RaytracePort.upstream_checksum(3, 40)
      (System.monotonic_time(:microsecond) - last) / 1000
    end
    |> Enum.sort()

  IO.puts(
    "#{String.pad_trailing("fly: cancel to next call answered", 38)} " <>
      "median=#{Float.round(Enum.at(cancels, div(samples, 2)), 3)} ms " <>
      "min=#{Float.round(hd(cancels), 3)} max=#{Float.round(List.last(cancels), 3)}"
  )

  measure.("fly: save_apng #{fly_frames} frames", fn ->
    path = Path.join(System.tmp_dir!(), "bendler_bench_fly.png")
    RaytracePort.save_apng(path, scene, fly_w, fly_h, fly_frames)
    File.rm(path)
  end)
after
  GenServer.stop(pid)
end

# The GPU lane, when this build has a device program beside the executable.
# One bang per frame, at a smaller size: macOS aborts a Metal command
# buffer that holds the device too long ("Impacting Interactivity"), and a
# whole 320x240 frame in one bang is past that limit here. GPU_FLY_WIDTH
# and GPU_FLY_HEIGHT override it.
gpu_sidecar = Bendler.Build.artifact_path(:bendler, "bendler_demos_raytrace_port", :port) <> ".gpu"
gpu_w = String.to_integer(System.get_env("GPU_FLY_WIDTH", "128"))
gpu_h = String.to_integer(System.get_env("GPU_FLY_HEIGHT", "96"))

if File.regular?(gpu_sidecar) do
  {:ok, pid} = RaytracePort.start_link(threads: cores, gpu: :on, timeout: 600_000)

  try do
    measure.("fly: #{fly_frames} frames #{gpu_w}x#{gpu_h} CPU", fn ->
      scene |> RaytracePort.fly(gpu_w, gpu_h, fly_frames) |> Enum.to_list()
    end)

    measure.("fly: #{fly_frames} frames #{gpu_w}x#{gpu_h} GPU", fn ->
      scene |> RaytracePort.fly(gpu_w, gpu_h, fly_frames, lane: :gpu) |> Enum.to_list()
    end)
  after
    GenServer.stop(pid)
  end
else
  IO.puts("\n(no #{Path.basename(gpu_sidecar)}: the GPU lane is not measured here)")
end
