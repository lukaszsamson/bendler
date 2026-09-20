defmodule Bendler.Demos.RaytraceReference do
  @moduledoc """
  The same raytracer as `demos/raytrace/raytrace.bend`, in Elixir doubles.

  Every step is the Bend kernel's, in the same order: the guard-shifted
  nearest-hit fold over the spheres, the 2x2 supersampling, the shadow
  probe, five levels of mirror bounce in accumulator form, and the same
  clamp-and-truncate quantisation. Bend computes in F32 and this in
  doubles, so a channel sitting on a quantisation boundary can land one
  step apart; the tests measure that difference rather than assume it
  away.
  """

  alias Bendler.Demos.RaytracePort

  @miss 1.0e9
  @eps 1.0e-3
  @ambient 0.1
  @diffuse 0.85
  @depth 4

  @doc "The whole `w` x `h` image as `{w, h, rgb}`, three bytes per pixel."
  @spec render(RaytracePort.scene(), pos_integer, pos_integer) ::
          {pos_integer, pos_integer, binary}
  def render(scene, w, h), do: {w, h, render_tile(scene, w, h, 0, 0, w, h)}

  @doc "The `tw` x `th` tile at `(x0, y0)` as packed RGB bytes, row-major."
  @spec render_tile(
          RaytracePort.scene(),
          pos_integer,
          pos_integer,
          non_neg_integer,
          non_neg_integer,
          non_neg_integer,
          non_neg_integer
        ) :: binary
  def render_tile(_scene, _w, _h, _x0, _y0, tw, th) when tw == 0 or th == 0, do: <<>>

  def render_tile({:scene, spheres, light, eye, sky}, w, h, x0, y0, tw, th) do
    fs = Enum.map(spheres, &flatten/1)
    {:vec, lpx, lpy, lpz} = light
    ctx = %{fs: fs, light: {lpx, lpy, lpz}, eye: xyz(eye), sky: xyz(sky)}
    hw = w / 2
    hh = h / 2

    for y <- y0..(y0 + th - 1), x <- x0..(x0 + tw - 1), into: <<>> do
      pixel(ctx, x, y, hw, hh)
    end
  end

  defp xyz({:vec, x, y, z}), do: {x, y, z}

  defp flatten({:sphere, {:vec, cx, cy, cz}, r, {:vec, er, eg, eb}, m}),
    do: {cx, cy, cz, r, er, eg, eb, m}

  defp pixel(ctx, x, y, hw, hh) do
    x1 = (x + 0.25 - hw) / hw
    x2 = (x + 0.75 - hw) / hw
    y1 = (hh - (y + 0.25)) / hw
    y2 = (hh - (y + 0.75)) / hw

    {r1, g1, b1} = subray(ctx, x1, y1)
    {r2, g2, b2} = subray(ctx, x2, y1)
    {r3, g3, b3} = subray(ctx, x1, y2)
    {r4, g4, b4} = subray(ctx, x2, y2)

    <<quant(r1 + r2 + (r3 + r4)), quant(g1 + g2 + (g3 + g4)), quant(b1 + b2 + (b3 + b4))>>
  end

  defp quant(sum), do: trunc(255 * clamp01(sum * 0.25))

  defp clamp01(x) when x < 0, do: 0.0
  defp clamp01(x) when x > 1, do: 1.0
  defp clamp01(x), do: x

  defp subray(ctx, fx, fy) do
    dl = :math.sqrt(fx * fx + fy * fy + 1)
    d = {fx / dl, fy / dl, 1 / dl}
    o = ctx.eye
    trace(@depth, nearest(ctx.fs, o, d), ctx, o, d, {0.0, 0.0, 0.0}, 1.0)
  end

  # the nearest hit, or `:miss`: the first strict minimum, the order the
  # Bend fold walks the list
  defp nearest(fs, o, d) do
    Enum.reduce(fs, :miss, fn s, best ->
      t = isect(s, o, d)

      case best do
        :miss when t < @miss -> {t, s}
        {bt, _} when t < bt -> {t, s}
        other -> other
      end
    end)
  end

  defp nearest_t(fs, o, d) do
    Enum.reduce(fs, @miss, fn s, bt ->
      t = isect(s, o, d)
      if t < bt, do: t, else: bt
    end)
  end

  defp isect({cx, cy, cz, r, _, _, _, _}, {ox, oy, oz}, {dx, dy, dz}) do
    px = ox - cx
    py = oy - cy
    pz = oz - cz
    b = px * dx + py * dy + pz * dz
    disc = b * b - (px * px + py * py + pz * pz - r * r)

    if disc < 0, do: @miss, else: near_root(-b - :math.sqrt(disc))
  end

  defp near_root(t) when t < @eps, do: @miss
  defp near_root(t), do: t

  defp trace(_dep, :miss, ctx, _o, _d, {ar, ag, ab}, w) do
    {skyr, skyg, skyb} = ctx.sky
    {ar + w * skyr, ag + w * skyg, ab + w * skyb}
  end

  defp trace(dep, {t, s}, ctx, {sox, soy, soz}, {rdx, rdy, rdz}, {ar, ag, ab}, w) do
    {cx, cy, cz, rr, er, eg, eb, m} = s
    hx = sox + t * rdx
    hy = soy + t * rdy
    hz = soz + t * rdz
    nx = (hx - cx) / rr
    ny = (hy - cy) / rr
    nz = (hz - cz) / rr
    {lpx, lpy, lpz} = ctx.light
    lvx = lpx - hx
    lvy = lpy - hy
    lvz = lpz - hz
    ll = :math.sqrt(lvx * lvx + lvy * lvy + lvz * lvz)
    lx = lvx / ll
    ly = lvy / ll
    lz = lvz / ll
    df = max(0.0, nx * lx + ny * ly + nz * lz)
    so2 = {hx + @eps * nx, hy + @eps * ny, hz + @eps * nz}
    st = nearest_t(ctx.fs, so2, {lx, ly, lz})
    shaded = if st < ll, do: 0.0, else: df
    lum = @ambient + @diffuse * shaded
    bounce(dep, ctx, so2, {rdx, rdy, rdz}, {nx, ny, nz}, {ar, ag, ab}, w, {lum, {er, eg, eb}, m})
  end

  defp bounce(0, _ctx, _so2, _rd, _n, {ar, ag, ab}, w, {lum, {er, eg, eb}, _m}) do
    {ar + w * lum * er, ag + w * lum * eg, ab + w * lum * eb}
  end

  defp bounce(dep, ctx, so2, {rdx, rdy, rdz}, {nx, ny, nz}, {ar, ag, ab}, w, surface) do
    {lum, {er, eg, eb}, m} = surface
    k2 = 2 * (rdx * nx + rdy * ny + rdz * nz)
    d2 = {rdx - k2 * nx, rdy - k2 * ny, rdz - k2 * nz}

    acc = {
      ar + w * lum * er * (1 - m),
      ag + w * lum * eg * (1 - m),
      ab + w * lum * eb * (1 - m)
    }

    trace(dep - 1, nearest(ctx.fs, so2, d2), ctx, so2, d2, acc, w * m)
  end
end
