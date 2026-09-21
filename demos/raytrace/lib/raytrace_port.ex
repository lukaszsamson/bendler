defmodule Bendler.Demos.RaytracePort do
  @moduledoc """
  A sphere raytracer (`demos/raytrace/raytrace.bend`), run as a port.

  The scene is a Bend user datatype built in Elixir: `scene/4` over
  `sphere/4` and `vec/3`. It crosses as tagged tuples and the pixels come
  back as the prelude's `Bytes`, three per pixel, row-major inside the
  requested tile.

  Elixir owns the scheduling: `render/4` cuts the image into tiles, hands
  them to Bend in batches (Bend forks the tiles, and each tile's rows,
  across every core), and assembles the rows. `stream/4` yields the tile
  rows as they arrive; `:on_tile` calls back per tile. `fly/5` goes the
  other way: one Bend call renders a whole camera turn and emits each
  frame as it finishes, and `save_apng/6` writes them into an animated
  PNG while the render is still running. A `:timeout` given
  to `start_link/1` bounds a call: past it the call raises
  `Bendler.Error` with reason `:timeout`, the owner stops and a supervisor
  restarts it.

  Start it under a supervisor:

      {:ok, sup} = Supervisor.start_link([{RaytracePort, threads: 4}], strategy: :one_for_one)
      {w, h, rgb} = RaytracePort.render(RaytracePort.default_scene(), 320, 240)
  """
  alias Bendler.Demos.Raytrace.{Apng, Png}

  use Bendler,
    otp_app: :bendler,
    source: "demos/raytrace/raytrace.bend",
    backend: :port,
    exports: [
      "render_tile",
      "render_tiles",
      "render_tiles_gpu",
      "render_checked",
      "fly",
      "fly_gpu",
      "upstream_checksum",
      "upstream_checksum_gpu"
    ]

  @typedoc "A tile: `{x0, y0, width, height}`."
  @type tile :: {non_neg_integer, non_neg_integer, pos_integer, pos_integer}

  @doc "A point or a colour. Integers are accepted and become floats."
  @spec vec(number, number, number) :: vec
  def vec(x, y, z), do: {:vec, x * 1.0, y * 1.0, z * 1.0}

  @doc "A sphere: centre, radius, colour, mirror fraction in 0..1."
  @spec sphere(vec, number, vec, number) :: sphere
  def sphere(center, radius, color, mirror),
    do: {:sphere, center, radius * 1.0, color, mirror * 1.0}

  @doc "A scene: the spheres, the point light, the eye, the sky colour."
  @spec scene([sphere], vec, vec, vec) :: scene
  def scene(spheres, light, eye, sky), do: {:scene, spheres, light, eye, sky}

  @doc """
  A small demonstration scene: five coloured balls on a large mirror
  floor sphere, a point light above and behind the eye, a blue sky.
  """
  @spec default_scene() :: scene
  def default_scene do
    scene(
      [
        sphere(vec(0, 0, 5), 1, vec(0.9, 0.25, 0.2), 0.35),
        sphere(vec(2.1, 0.4, 6), 1, vec(0.2, 0.85, 0.4), 0.4),
        sphere(vec(-2.1, 0.4, 6), 1, vec(0.25, 0.4, 0.95), 0.4),
        sphere(vec(1.0, -0.6, 3.5), 0.4, vec(0.95, 0.85, 0.2), 0.55),
        sphere(vec(-1.0, -0.6, 3.5), 0.4, vec(0.9, 0.5, 0.95), 0.55),
        sphere(vec(0, -10_001, 5), 10_000, vec(0.75, 0.75, 0.75), 0.3)
      ],
      vec(-3, 8, 1),
      vec(0, 0, 0),
      vec(0.08, 0.16, 0.32)
    )
  end

  @doc """
  Renders the whole `w` x `h` image and answers `{w, h, rgb}`, three
  bytes per pixel, row-major.

  Options:

    * `:tile` - the tile edge in pixels (default 64)
    * `:batch` - tiles per `render_tiles` call (default 16; the tiles of a
      call fork as a balanced tree, so bigger batches cost nothing on the
      CPU pool and are what the GPU lane wants: one bang per image)
    * `:on_tile` - `fun({x0, y0, tw, th}, rgb)`, called per tile as it
      arrives, for progressive display
    * `:lane` - `:cpu` (default) calls `render_tiles`; `:gpu` calls
      `render_tiles_gpu`, whose `!` ships the batch to the GPU when the
      port was started with `gpu: :on` (and to the CPU pool otherwise)
  """
  @spec render(scene, pos_integer, pos_integer, keyword) ::
          {pos_integer, pos_integer, binary}
  def render(scene, w, h, opts \\ []) do
    on_tile = Keyword.get(opts, :on_tile)

    rows =
      scene
      |> stream(w, h, opts)
      |> Enum.reduce(%{}, fn {tile, rgb}, acc ->
        if on_tile, do: on_tile.(tile, rgb)
        merge_tile(acc, tile, rgb)
      end)

    {w, h, rows |> Enum.sort() |> Enum.map_join("", &join_row/1)}
  end

  @doc """
  A stream of `{tile, rgb}` pairs, one per tile, in the order the tiles
  were cut. The Bend calls happen a batch at a time as the stream is
  consumed, so a caller can display rows before the image is complete.
  """
  @spec stream(scene, pos_integer, pos_integer, keyword) :: Enumerable.t()
  def stream(scene, w, h, opts \\ []) do
    tile = Keyword.get(opts, :tile, 64)
    batch = Keyword.get(opts, :batch, 16)
    render = if Keyword.get(opts, :lane, :cpu) == :gpu, do: &render_tiles_gpu/4, else: &render_tiles/4

    w
    |> tiles(h, tile)
    |> Stream.chunk_every(batch)
    |> Stream.flat_map(fn chunk -> Enum.zip(chunk, render.(scene, w, h, chunk)) end)
  end

  @doc "The tiles of a `w` x `h` image cut into `edge` x `edge` squares."
  @spec tiles(pos_integer, pos_integer, pos_integer) :: [tile]
  def tiles(w, h, edge) when edge > 0 do
    for y0 <- 0..(h - 1)//edge, x0 <- 0..(w - 1)//edge do
      {x0, y0, min(edge, w - x0), min(edge, h - y0)}
    end
  end

  @doc """
  Renders the scene and writes it to `path` as a PNG. Options are
  `render/4`'s.
  """
  @spec save_png(Path.t(), scene, pos_integer, pos_integer, keyword) :: :ok
  def save_png(path, scene, w, h, opts \\ []) do
    {^w, ^h, rgb} = render(scene, w, h, opts)
    File.write!(path, Png.encode(w, h, rgb))
  end

  # the tile's rows, collected per image row as `{x0, segment}` pieces
  defp merge_tile(acc, {x0, y0, tw, th}, rgb) do
    Enum.reduce(0..(th - 1), acc, fn dy, acc ->
      piece = {x0, :binary.part(rgb, dy * tw * 3, tw * 3)}
      Map.update(acc, y0 + dy, [piece], &[piece | &1])
    end)
  end

  defp join_row({_y, pieces}) do
    pieces |> Enum.sort() |> Enum.map_join("", &elem(&1, 1))
  end

  @doc """
  A lazy stream of one camera turn: `{:event, rgb}` per frame as Bend
  finishes it, then `{:done, frames}` with the number emitted.

  One Bend call renders every frame. The camera turns about the vertical
  axis through `{cx, cz}` (the `:center` option, default `{0.0, 5.0}`,
  the demo scene's middle) while the light stays where it is in the
  world. Backpressure is the acknowledgement: the worker renders the next
  frame only once this stream is asked for it, and halting early
  (`Enum.take/2`) ends the turn.

  Options:

    * `:center` - `{cx, cz}`, the point the camera turns about
    * `:lane` - `:cpu` (default) or `:gpu`, which needs `gpu: :on`

  """
  @spec fly(scene, pos_integer, pos_integer, pos_integer, keyword) :: Enumerable.t()
  def fly(scene, w, h, frames, opts \\ []) do
    {cx, cz} = Keyword.get(opts, :center, {0.0, 5.0})

    if Keyword.get(opts, :lane, :cpu) == :gpu,
      do: fly_gpu_stream(scene, w, h, frames, cx * 1.0, cz * 1.0),
      else: fly_stream(scene, w, h, frames, cx * 1.0, cz * 1.0)
  end

  @doc """
  Renders a camera turn into the animated PNG at `path`, appending each
  frame as it arrives, and answers how many frames the file holds.

  Options are `fly/5`'s plus `:delay`, the `{numerator, denominator}`
  seconds a frame is shown (default `{1, 20}`), and `:take`, a limit that
  cancels the turn after that many frames.
  """
  @spec save_apng(Path.t(), scene, pos_integer, pos_integer, pos_integer, keyword) ::
          non_neg_integer
  def save_apng(path, scene, w, h, frames, opts \\ []) do
    writer = Apng.open(path, w, h, frames: frames, delay: Keyword.get(opts, :delay, {1, 20}))
    stream = scene |> fly(w, h, frames, opts) |> frames_only(Keyword.get(opts, :take))

    Apng.close(Enum.reduce(stream, writer, fn rgb, a -> Apng.frame(a, rgb) end))
  end

  defp frames_only(stream, nil), do: Stream.flat_map(stream, &frame_of/1)
  defp frames_only(stream, take), do: stream |> frames_only(nil) |> Stream.take(take)

  defp frame_of({:event, rgb}), do: [rgb]
  defp frame_of({:done, _}), do: []
end
