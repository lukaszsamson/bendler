defmodule Bendler.Test.EventsPort do
  @moduledoc "Effectful exports with typed emitters, over the port backend."
  use Bendler,
    otp_app: :bendler,
    source: "bend/events.bend",
    backend: :port,
    threads: 2,
    exports: ["double", "tick", "count", "points", "pairs"]
end

defmodule Bendler.Test.EventsDeadlinePort do
  @moduledoc "The same exports with a short total deadline, for the timeout test."
  use Bendler,
    otp_app: :bendler,
    source: "bend/events.bend",
    backend: :port,
    threads: 2,
    timeout: 300,
    exports: ["count"]
end
