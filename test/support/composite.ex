defmodule Bendler.Test.CompositePort do
  @moduledoc false
  use Bendler, otp_app: :bendler, source: "bend/composite.bend", backend: :port, threads: 1
end

defmodule Bendler.Test.RecordOnlyPort do
  @moduledoc false
  use Bendler,
    otp_app: :bendler,
    source: "bend/composite.bend",
    exports: ["rec_echo"],
    backend: :port,
    threads: 1
end

defmodule Bendler.Test.RecordOnlyNif do
  @moduledoc false
  use Bendler,
    otp_app: :bendler,
    source: "bend/composite.bend",
    exports: ["rec_echo"],
    backend: :nif,
    threads: 1
end

defmodule Bendler.Test.CompositeNif do
  @moduledoc false
  use Bendler, otp_app: :bendler, source: "bend/composite.bend", backend: :nif, threads: 1
end
