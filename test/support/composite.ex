defmodule Bendler.Test.CompositePort do
  @moduledoc false
  use Bendler, otp_app: :bendler, source: "bend/composite.bend", backend: :port, threads: 1
end

defmodule Bendler.Test.CompositeNif do
  @moduledoc false
  use Bendler, otp_app: :bendler, source: "bend/composite.bend", backend: :nif, threads: 1
end
