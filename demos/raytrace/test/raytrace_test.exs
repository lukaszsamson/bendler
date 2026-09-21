defmodule Bendler.Demos.RaytraceTest do
  use ExUnit.Case, async: false

  alias Bendler.Demos.Raytrace.{Apng, Png}
  alias Bendler.Demos.RaytracePort
  alias Bendler.Demos.RaytraceReference

  @tiny RaytracePort.scene(
          [
            RaytracePort.sphere(
              RaytracePort.vec(0, 0, 4),
              1,
              RaytracePort.vec(0.9, 0.3, 0.2),
              0.5
            ),
            RaytracePort.sphere(
              RaytracePort.vec(0, -1001, 4),
              1000,
              RaytracePort.vec(0.7, 0.7, 0.7),
              0.25
            )
          ],
          RaytracePort.vec(-3, 8, 1),
          RaytracePort.vec(0, 0, 0),
          RaytracePort.vec(0.1, 0.2, 0.4)
        )

  @sky RaytracePort.scene(
         [],
         RaytracePort.vec(-3, 8, 1),
         RaytracePort.vec(0, 0, 0),
         RaytracePort.vec(0.1, 0.2, 0.4)
       )

  test "the upstream fixed scene still checksums bit-exactly" do
    start_supervised!({RaytracePort, threads: 4})
    # 2^6 = 64 rows of 80 pixels, the upstream benchmark's "small" size
    assert RaytracePort.upstream_checksum(6, 80) == 402_971
    # two more sizes, each taken from a run of the upstream file itself
    assert RaytracePort.upstream_checksum(3, 40) == 19_281
    assert RaytracePort.upstream_checksum(7, 123) == 1_245_125
  end

  test "a pinned tiny scene renders the same bytes as it did when it was pinned" do
    start_supervised!({RaytracePort, threads: 2})
    rgb = RaytracePort.render_tile(@tiny, 24, 18, 0, 0, 24, 18)

    assert byte_size(rgb) == 24 * 18 * 3

    assert Base.encode16(:crypto.hash(:sha256, rgb), case: :lower) ==
             "960e0e8547bf63e79f4bc1f46741974a809f5bed1da52fac7c38bec4543a3501"
  end

  test "a scene with no spheres is the sky colour everywhere" do
    start_supervised!({RaytracePort, threads: 1})
    rgb = RaytracePort.render_tile(@sky, 4, 2, 0, 0, 4, 2)
    assert rgb == String.duplicate(<<25, 51, 102>>, 8)
    assert rgb == RaytraceReference.render_tile(@sky, 4, 2, 0, 0, 4, 2)
  end

  test "tiles assembled equal one big tile, whatever the tile size" do
    start_supervised!({RaytracePort, threads: 4})
    scene = RaytracePort.default_scene()
    whole = RaytracePort.render_tile(scene, 48, 36, 0, 0, 48, 36)

    for edge <- [7, 16, 48, 64] do
      assert {48, 36, ^whole} = RaytracePort.render(scene, 48, 36, tile: edge, batch: 3)
    end
  end

  test "an empty tile list renders nothing and a refused tile is a Result error" do
    start_supervised!({RaytracePort, threads: 1})
    assert RaytracePort.render_tiles(@tiny, 16, 16, []) == []

    assert {:ok, rgb} = RaytracePort.render_checked(@tiny, 16, 16, 0, 0, 16, 16)
    assert byte_size(rgb) == 16 * 16 * 3

    for bad <- [{0, 0, 0, 4}, {0, 0, 4, 0}, {8, 0, 16, 4}, {0, 8, 4, 16}] do
      {x0, y0, tw, th} = bad

      assert RaytracePort.render_checked(@tiny, 16, 16, x0, y0, tw, th) ==
               {:error, "tile out of the image, or empty"}
    end
  end

  test "the tile callback sees every tile exactly once" do
    start_supervised!({RaytracePort, threads: 2})
    parent = self()

    {32, 24, rgb} =
      RaytracePort.render(@tiny, 32, 24, tile: 16, on_tile: &send(parent, {:tile, &1, &2}))

    seen =
      for _ <- 1..4, into: MapSet.new() do
        assert_received {:tile, {_, _, tw, th} = tile, bytes}
        assert byte_size(bytes) == tw * th * 3
        tile
      end

    assert seen == MapSet.new(RaytracePort.tiles(32, 24, 16))
    refute_received {:tile, _, _}
    assert byte_size(rgb) == 32 * 24 * 3
  end

  test "F32 against doubles: the same image but for a handful of quantisation steps" do
    start_supervised!({RaytracePort, threads: 4})
    scene = RaytracePort.default_scene()
    {w, h} = {96, 72}
    {^w, ^h, bend} = RaytracePort.render(scene, w, h, tile: 32)
    {^w, ^h, elixir} = RaytraceReference.render(scene, w, h)
    assert byte_size(bend) == byte_size(elixir)

    diffs =
      Enum.zip_with(:binary.bin_to_list(bend), :binary.bin_to_list(elixir), &abs(&1 - &2))

    n = length(diffs)
    max = Enum.max(diffs)
    mean = Enum.sum(diffs) / n
    off = Enum.count(diffs, &(&1 > 0))

    IO.puts(
      "\nF32 vs double on #{w}x#{h}: max #{max}, mean #{Float.round(mean, 5)}, " <>
        "#{off}/#{n} channels differ (#{Float.round(off * 100 / n, 3)}%)"
    )

    # most channels are bit-identical; the rest sit on a quantisation,
    # silhouette or shadow boundary where single and double precision
    # disagree about which side they are on
    assert off / n < 0.01
    assert mean < 0.05
    assert max <= 24
  end

  test "a render that outlives its deadline stops the owner; the next one works" do
    pid = start_supervised!({RaytracePort, threads: 1, timeout: 20})
    ref = Process.monitor(pid)

    assert_raise Bendler.Error, fn ->
      RaytracePort.render_tile(RaytracePort.default_scene(), 512, 512, 0, 0, 512, 512)
    end

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :timeout}}, 2_000
    # the supervisor put a fresh port back under the same name
    Process.sleep(100)
    assert byte_size(RaytracePort.render_tile(@sky, 2, 2, 0, 0, 2, 2)) == 12
  end

  test "the deadline reason is :timeout" do
    start_supervised!({RaytracePort, threads: 1, timeout: 20})

    reason =
      try do
        RaytracePort.render_tile(RaytracePort.default_scene(), 512, 512, 0, 0, 512, 512)
        nil
      rescue
        e in Bendler.Error -> e.reason
      end

    assert reason == :timeout
  end

  test "the PNG writer round-trips through zlib" do
    start_supervised!({RaytracePort, threads: 2})
    {w, h, rgb} = RaytracePort.render(@tiny, 12, 8, tile: 8)
    png = Png.encode(w, h, rgb)

    assert <<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>> = png
    assert <<13::32, "IHDR", ^w::32, ^h::32, 8, 2, 0, 0, 0, _crc::32, rest::binary>> = rest
    assert <<len::32, "IDAT", idat::binary-size(len), _crc2::32, iend::binary>> = rest
    assert iend == <<0::32, "IEND", :erlang.crc32("IEND")::32>>

    lines = IO.iodata_to_binary(:zlib.uncompress(idat))
    assert byte_size(lines) == h * (1 + w * 3)

    stride = w * 3
    assert for(<<0, row::binary-size(^stride) <- lines>>, into: <<>>, do: row) == rgb
  end

  # A `.gpu` sidecar is written only after Bend's `--gpu-build` succeeds, so
  # its presence proves that this compiled port includes a device program. It
  # does not probe or start a GPU while ExUnit discovers tests; macOS is the
  # supported Metal host and other hosts explicitly report this test skipped.
  @gpu_artifact Bendler.Build.artifact_path(:bendler, "bendler_demos_raytrace_port", :port) <>
                  ".gpu"
  @gpu_available match?({:unix, :darwin}, :os.type()) and File.regular?(@gpu_artifact)

  @tag skip:
         if(@gpu_available,
           do: false,
           else: "requires a macOS build with #{Path.basename(@gpu_artifact)}"
         )
  test "the GPU lane renders the upstream scene bit-exactly and a tile the same as the CPU" do
    start_supervised!({RaytracePort, threads: 4, gpu: :on, timeout: 60_000})
    assert RaytracePort.upstream_checksum_gpu(6, 80) == 402_971
    assert RaytracePort.upstream_checksum_gpu(3, 40) == 19_281
    scene = RaytracePort.default_scene()
    [gpu] = RaytracePort.render_tiles_gpu(scene, 640, 480, [{64, 64, 64, 64}])
    [cpu] = RaytracePort.render_tiles(scene, 640, 480, [{64, 64, 64, 64}])
    assert gpu == cpu
  end

  test "the GPU defs run on the CPU pool when the port has no GPU" do
    start_supervised!({RaytracePort, threads: 2})
    assert RaytracePort.upstream_checksum_gpu(6, 80) == 402_971
    scene = RaytracePort.default_scene()
    {_, _, a} = RaytracePort.render(scene, 96, 72, lane: :gpu)
    {_, _, b} = RaytracePort.render(scene, 96, 72)
    assert a == b
  end

  # The fly-through: one call, many frames, each emitted as it finishes
  # =================================================================

  defp frames(stream) do
    Stream.flat_map(stream, fn
      {:event, rgb} -> [rgb]
      {:done, _} -> []
    end)
  end

  test "a fly-through emits whole frames of the right size, the first one being render/4's" do
    start_supervised!({RaytracePort, threads: 4})
    scene = RaytracePort.default_scene()

    list = RaytracePort.fly(scene, 64, 48, 6) |> Enum.to_list()
    assert List.last(list) == {:done, 6}
    [{:event, rgb} | _] = list
    assert byte_size(rgb) == 64 * 48 * 3

    # frame 0 is the untouched scene, so it is exactly what render/4 draws
    assert {64, 48, rgb} == RaytracePort.render(scene, 64, 48)
    # and the camera really turns: later frames differ
    assert length(Enum.uniq(Enum.to_list(frames(RaytracePort.fly(scene, 32, 24, 4))))) == 4
  end

  test "a fly-through can be cancelled and the port serves the next call" do
    start_supervised!({RaytracePort, threads: 4})
    scene = RaytracePort.default_scene()

    taken = RaytracePort.fly(scene, 32, 24, 10_000) |> frames() |> Enum.take(3)
    assert length(taken) == 3
    assert RaytracePort.upstream_checksum(3, 40) == 19_281
  end

  test "save_apng/6 writes a parseable animated PNG whose frames match the stream" do
    start_supervised!({RaytracePort, threads: 4})
    scene = RaytracePort.default_scene()
    path = Path.join(System.tmp_dir!(), "bendler_fly_#{System.unique_integer([:positive])}.png")
    on_exit(fn -> File.rm(path) end)

    assert RaytracePort.save_apng(path, scene, 48, 36, 5) == 5
    types = path |> File.read!() |> Apng.chunks() |> Enum.map(&elem(&1, 0))

    assert Enum.take(types, 3) == ["IHDR", "acTL", "fcTL"]
    assert List.last(types) == "IEND"
    assert Enum.count(types, &(&1 == "fcTL")) == 5
    assert Enum.count(types, &(&1 == "IDAT")) == 1
    assert Enum.count(types, &(&1 == "fdAT")) == 4

    # acTL announces exactly the frames that arrived
    {"acTL", <<count::32, plays::32>>} =
      path |> File.read!() |> Apng.chunks() |> List.keyfind("acTL", 0)

    assert {count, plays} == {5, 0}
  end

  test "a cancelled fly-through leaves an animated PNG with the frames it got" do
    start_supervised!({RaytracePort, threads: 4})
    scene = RaytracePort.default_scene()
    path = Path.join(System.tmp_dir!(), "bendler_cut_#{System.unique_integer([:positive])}.png")
    on_exit(fn -> File.rm(path) end)

    assert RaytracePort.save_apng(path, scene, 32, 24, 10_000, take: 2) == 2

    {"acTL", <<2::32, 0::32>>} =
      path |> File.read!() |> Apng.chunks() |> List.keyfind("acTL", 0)

    assert RaytracePort.upstream_checksum(3, 40) == 19_281
  end

  test "correcting an APNG frame count preserves its repeat count" do
    path = Path.join(System.tmp_dir!(), "bendler_plays_#{System.unique_integer([:positive])}.png")
    on_exit(fn -> File.rm(path) end)
    writer = Apng.open(path, 1, 1, frames: 3, plays: 7)
    assert writer |> Apng.frame(<<0, 0, 0>>) |> Apng.close() == 1

    assert {"acTL", <<1::32, 7::32>>} =
             path |> File.read!() |> Apng.chunks() |> List.keyfind("acTL", 0)
  end

  @tag skip:
         if(@gpu_available,
           do: false,
           else: "requires a macOS build with #{Path.basename(@gpu_artifact)}"
         )
  test "the GPU lane renders the same fly-through frames as the CPU lane" do
    start_supervised!({RaytracePort, threads: 4, gpu: :on, timeout: 120_000})
    scene = RaytracePort.default_scene()
    gpu = RaytracePort.fly(scene, 64, 48, 3, lane: :gpu) |> frames() |> Enum.to_list()
    cpu = RaytracePort.fly(scene, 64, 48, 3) |> frames() |> Enum.to_list()
    assert gpu == cpu
  end
end
