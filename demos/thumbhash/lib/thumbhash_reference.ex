defmodule Bendler.Demos.ThumbhashReference do
  @moduledoc """
  A verbatim copy of `Thumbhash` from `Hentioe/thumbhash-ex` (MIT), renamed
  so the demo's differential tests need no dependency, with two fixes:

  1. The reference passes no `w`/`h` when it encodes the alpha channel,
     which crashes on any image with transparency (`params.w` is `nil` in
     `step_by_cx`). Here the alpha channel gets `w` and `h` like the other
     three, as the original JavaScript does.
  2. Both flag bits are mis-positioned by operator precedence:
     `if has_alpha, do: 1, else: 0 <<< 23` parses as
     `if(has_alpha, do: 1, else: (0 <<< 23))`, so the alpha flag lands in
     bit 0 of the 24-bit header (colliding with `l_dc`) and the landscape
     flag in bit 0 of the 16-bit header (colliding with `lx`/`ly`), never
     in bits 23 and 15. The documented test vector was produced by that
     code. Here the flags are shifted as in the JavaScript
     (`(isLandscape ? 1 : 0) << 15`).
  """

  import Bitwise

  defmodule RGBA do
    @moduledoc false
    defstruct r: 0, g: 0, b: 0, a: 0
  end

  defmodule LQPA do
    @moduledoc false
    defstruct l: :array.new(), q: :array.new(), p: :array.new(), a: :array.new()

    def new(size) do
      %__MODULE__{l: :array.new(size), q: :array.new(size), p: :array.new(size), a: :array.new(size)}
    end
  end

  defmodule Params do
    @moduledoc false
    defstruct [:channel, :nx, :ny, :w, :h]
  end

  @doc "Encodes a `w`x`h` RGBA binary to a ThumbHash binary."
  def encode(w, h, rgba) when is_binary(rgba) do
    rgba_to_thumb_hash(w, h, rgba |> :binary.bin_to_list() |> :array.from_list())
  end

  def rgba_to_thumb_hash(w, h, rgba) do
    if w > 100 or h > 100, do: raise(ArgumentError, "#{w}x#{h} doesn't fit in 100x100")
    pixels_count = w * h
    avg = calculate_avg_rgba(pixels_count, rgba)
    has_alpha = avg.a < w * h
    l_limit = if has_alpha, do: 5, else: 7
    lx = max(1, round(l_limit * w / max(w, h)))
    ly = max(1, round(l_limit * h / max(w, h)))
    lqpa = caculate_lqpa(pixels_count, avg, rgba)

    {l_dc, l_ac, l_scale} =
      encode_channel(%Params{channel: lqpa.l, nx: max(3, lx), ny: max(3, ly), w: w, h: h})

    {p_dc, p_ac, p_scale} = encode_channel(%Params{channel: lqpa.p, nx: 3, ny: 3, w: w, h: h})
    {q_dc, q_ac, q_scale} = encode_channel(%Params{channel: lqpa.q, nx: 3, ny: 3, w: w, h: h})

    {a_dc, a_ac, a_scale} =
      if has_alpha do
        # the fix: the original copy omits w and h here
        encode_channel(%Params{channel: lqpa.a, nx: 5, ny: 5, w: w, h: h})
      else
        {nil, nil, nil}
      end

    hash =
      caculate_hash(w > h, lx, ly, has_alpha, %{
        l: {l_dc, l_scale},
        p: {p_dc, p_scale},
        q: {q_dc, q_scale},
        a: {a_dc, a_scale}
      })

    ac_start = if has_alpha, do: 6, else: 5
    ac_list = if has_alpha, do: [l_ac, p_ac, q_ac, a_ac], else: [l_ac, p_ac, q_ac]
    calculate_bytes(ac_start, ac_list, :array.from_list(hash, 0))
  end

  defp caculate_hash(is_landscape, lx, ly, has_alpha, %{
         l: {l_dc, l_scale},
         p: {p_dc, p_scale},
         q: {q_dc, q_scale},
         a: {a_dc, a_scale}
       }) do
    header24 = caculate_header24(has_alpha, l_dc, p_dc, q_dc, l_scale)
    header16 = caculate_header16(is_landscape, lx, ly, p_scale, q_scale)

    hash = [
      header24 &&& 255,
      header24 >>> 8 &&& 255,
      header24 >>> 16,
      header16 &&& 255,
      header16 >>> 8
    ]

    if has_alpha do
      hash ++ [round(15 * a_dc) ||| round(15 * a_scale) <<< 4]
    else
      hash
    end
  end

  defp caculate_header24(has_alpha, l_dc, p_dc, q_dc, l_scale) do
    round(63 * l_dc) ||| round(31.5 + 31.5 * p_dc) <<< 6 ||| round(31.5 + 31.5 * q_dc) <<< 12 |||
      round(31 * l_scale) <<< 18 ||| if(has_alpha, do: 1, else: 0) <<< 23
  end

  defp caculate_header16(is_landscape, lx, ly, p_scale, q_scale) do
    if(is_landscape, do: ly, else: lx) ||| round(63 * p_scale) <<< 3 |||
      round(63 * q_scale) <<< 9 ||| if(is_landscape, do: 1, else: 0) <<< 15
  end

  defp calculate_avg_rgba(pixels_count, rgba) do
    avg =
      Enum.reduce(0..(pixels_count - 1), %RGBA{}, fn i, %{r: r, g: g, b: b, a: a} ->
        j = i * 4
        alpha = :array.get(j + 3, rgba) / 255

        %RGBA{
          r: r + alpha / 255 * :array.get(j, rgba),
          g: g + alpha / 255 * :array.get(j + 1, rgba),
          b: b + alpha / 255 * :array.get(j + 2, rgba),
          a: a + alpha
        }
      end)

    if avg.a > 0 do
      %{avg | r: avg.r / avg.a, g: avg.g / avg.a, b: avg.b / avg.a}
    else
      avg
    end
  end

  defp caculate_lqpa(pixels_count, avg, rgba) do
    Enum.reduce(0..(pixels_count - 1), LQPA.new(pixels_count), fn i, lqpa ->
      %{l: l, q: q, p: p, a: a} = lqpa
      j = i * 4
      alpha = :array.get(j + 3, rgba) / 255
      r = avg.r * (1 - alpha) + alpha / 255 * :array.get(j, rgba)
      g = avg.g * (1 - alpha) + alpha / 255 * :array.get(j + 1, rgba)
      b = avg.b * (1 - alpha) + alpha / 255 * :array.get(j + 2, rgba)

      %LQPA{
        l: :array.set(i, (r + g + b) / 3, l),
        p: :array.set(i, (r + g) / 2 - b, p),
        q: :array.set(i, r - g, q),
        a: :array.set(i, alpha, a)
      }
    end)
  end

  defp calculate_bytes(ac_start, ac_list, hash) do
    {hash, _} =
      Enum.reduce(ac_list, {hash, 0}, fn ac, {hash, ac_index} ->
        Enum.reduce(ac, {hash, ac_index}, fn f, {hash, ac_index} ->
          i = ac_start + (ac_index >>> 1)
          nv = :array.get(i, hash) ||| round(15 * f) <<< ((ac_index &&& 1) <<< 2)
          {:array.set(i, nv, hash), ac_index + 1}
        end)
      end)

    hash |> :array.to_list() |> :binary.list_to_bin()
  end

  # Thumbhash.ChannelEncoder, verbatim
  def encode_channel(params) do
    {ac, dc, scale} = step_by_cy(params, 0, 0, {[], 0, 0})
    ac = if scale != 0, do: Enum.map(ac, fn f -> 0.5 + 0.5 / scale * f end), else: ac
    {dc, ac, scale}
  end

  defp step_by_cy(params, cy, cx, {ac, dc, scale}) when cy < params.ny do
    {ac, dc, scale} = step_by_cx(params, cx, cy, {ac, dc, scale})
    step_by_cy(params, cy + 1, 0, {ac, dc, scale})
  end

  defp step_by_cy(_params, _cy, _cx, {ac, dc, scale}), do: {ac, dc, scale}

  defp step_by_cx(params, cx, cy, {ac, dc, scale})
       when cx * params.ny < params.nx * (params.ny - cy) do
    fx =
      Enum.reduce(0..(params.w - 1), :array.new(), fn x, fx ->
        :array.set(x, :math.cos(:math.pi() / params.w * cx * (x + 0.5)), fx)
      end)

    f =
      Enum.reduce(0..(params.h - 1), 0, fn y, f ->
        fy = :math.cos(:math.pi() / params.h * cy * (y + 0.5))

        f +
          Enum.reduce(0..(params.w - 1), 0, fn x, f ->
            f + :array.get(x + y * params.w, params.channel) * :array.get(x, fx) * fy
          end)
      end)

    f = f / (params.w * params.h)

    {ac, dc, scale} =
      if cx != 0 || cy != 0 do
        {ac ++ [f], dc, max(scale, abs(f))}
      else
        {ac, f, scale}
      end

    step_by_cx(params, cx + 1, cy, {ac, dc, scale})
  end

  defp step_by_cx(_params, _cx, _ny, {ac, dc, scale}), do: {ac, dc, scale}
end
