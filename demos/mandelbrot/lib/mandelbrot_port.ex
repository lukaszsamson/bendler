defmodule Bendler.Demos.MandelbrotPort do
  @moduledoc """
  Bend's fixed-point Mandelbrot histogram/recolour checksum, through a CPU port.

  `depth` selects the first `64 * 2^depth` pixels of the fixed 4096×4096
  viewport, not a resized image. Depth 18 covers the entire viewport.
  The result is a U32 checksum, not image data. Start under a supervisor.
  """
  use Bendler,
    otp_app: :bendler,
    source: "demos/mandelbrot/mandelbrot.bend",
    backend: :port,
    exports: ["rend", "pix"]

  @doc "Computes the upstream histogram-equalized checksum (wrapping U32 arithmetic)."
  @spec checksum(0..18, 1..4096) :: non_neg_integer()
  def checksum(depth, iterations)
      when is_integer(depth) and depth in 0..18 and
             is_integer(iterations) and iterations in 1..4096 do
    rend(depth, iterations)
  end

  def checksum(_, _), do: raise(ArgumentError, "expected depth 0..18 and iterations 1..4096")
end
