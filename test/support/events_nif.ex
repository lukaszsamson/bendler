defmodule Bendler.Test.EventsNif do
  @moduledoc false
  use Bendler,
    otp_app: :bendler,
    source: "bend/events.bend",
    backend: :nif,
    threads: 2,
    timeout: 10_000,
    max_waiting: 2,
    exports: ["double", "tick", "count", "points", "pairs"]
end

defmodule Bendler.Test.EventsBoomNif do
  @moduledoc false
  use Bendler,
    otp_app: :bendler,
    source: "bend/events.bend",
    backend: :nif,
    threads: 1,
    timeout: 1_000,
    exports: ["fail_after"]
end
