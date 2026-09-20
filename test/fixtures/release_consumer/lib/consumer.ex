defmodule Consumer.Calc do
  @moduledoc false
  use Bendler, otp_app: :consumer, source: "bend/calc.bend"
end
