defmodule Bendler.Demos.Particles do
  @moduledoc "Deterministic oscillator fixtures and a streaming SVG trajectory writer."

  @doc "Builds a balanced tree of particles distributed on offset rings."
  @spec cloud(pos_integer()) :: tuple()
  def cloud(n) when n in 1..4096 do
    for i <- 0..(n - 1) do
      theta = 2 * :math.pi() * i / n
      radius = 0.3 + 0.6 * rem(i, 7) / 6
      x = radius * :math.cos(theta)
      y = radius * :math.sin(theta)
      {:body, x, y, -0.7 * y, 0.7 * x}
    end
    |> tree()
  end

  defp tree([body]), do: body

  defp tree(bodies) do
    {a, b} = Enum.split(bodies, div(length(bodies), 2))
    {:fork, tree(a), tree(b)}
  end

  @doc "Writes tick snapshots as SVG dots incrementally; does not collect the stream. Returns tick count."
  @spec save_svg(Enumerable.t(), Path.t()) :: non_neg_integer()
  def save_svg(stream, path) do
    File.open!(path, [:write], fn io ->
      IO.binwrite(
        io,
        ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 640"><rect width="640" height="640" fill="#101827"/>)
      )

      try do
        Enum.reduce(stream, 0, fn
          {:event, {tick, points}}, n ->
            hue = rem(tick * 3, 360)

            for {x, y} <- points do
              IO.binwrite(
                io,
                ~s(<circle cx="#{320 + x * 280}" cy="#{320 - y * 280}" r="1.1" fill="hsl\(#{hue},80%,65%\)" opacity="0.35"/>)
              )
            end

            n + 1

          {:done, _}, n ->
            n
        end)
      after
        IO.binwrite(io, "</svg>")
      end
    end)
  end
end
