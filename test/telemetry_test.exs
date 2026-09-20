defmodule Bendler.TelemetryTest do
  use ExUnit.Case, async: false
  alias Bendler.Test.{CompositeNif, CompositePort}

  setup do
    id = {__MODULE__, make_ref()}
    events = for event <- [:start, :stop, :exception], do: [:bendler, :call, event]
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    start_supervised!({CompositePort, []})
    :ok
  end

  def handle_event(event, measurements, metadata, pid),
    do: send(pid, {event, measurements, metadata})

  test "both generated backends emit matched spans without argument contents" do
    for backend <- [CompositePort, CompositeNif] do
      assert backend.pair({1, "private"}) == {1, "private"}

      assert_receive {[:bendler, :call, :start], %{system_time: _},
                      %{module: ^backend, function: :pair, telemetry_span_context: context}}

      assert_receive {[:bendler, :call, :stop], measurements,
                      %{module: ^backend, telemetry_span_context: ^context} = metadata}

      assert measurements.duration >= 0
      refute Map.has_key?(metadata, :args)
      refute Map.has_key?(metadata, :result)

      if backend == CompositePort do
        assert measurements.wait_time >= 0
        assert measurements.run_time >= 0
        assert measurements.queue_depth == 0
      else
        refute Map.has_key?(measurements, :run_time)
      end
    end
  end

  test "encoding failures emit sanitized exception metadata and preserve the exception" do
    assert_raise ArgumentError, fn -> CompositePort.pair({-1, "private"}) end
    assert_receive {[:bendler, :call, :start], _, %{telemetry_span_context: context}}

    assert_receive {[:bendler, :call, :exception], %{duration: duration},
                    %{reason: ArgumentError, kind: :error, telemetry_span_context: ^context} =
                      metadata}

    assert duration >= 0
    refute inspect(metadata) =~ "private"
    refute_receive {[:bendler, :call, :stop], _, _}
    assert CompositePort.pair({0, "ok"}) == {0, "ok"}
  end
end
