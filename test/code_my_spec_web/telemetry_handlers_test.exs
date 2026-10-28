defmodule CodeMySpecWeb.TelemetryHandlersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodeMySpecWeb.TelemetryHandlers

  def handle_event(_event, _measurements, _meta, _config), do: raise("handler crashed")

  test "a handler telemetry detached after it raised is attached again" do
    id = {__MODULE__, make_ref()}
    event = [:telemetry_handlers_test, :probe]
    attach = fn -> :telemetry.attach(id, event, &__MODULE__.handle_event/4, nil) end
    :ok = attach.()
    on_exit(fn -> :telemetry.detach(id) end)

    server =
      start_supervised!(%{
        id: make_ref(),
        start: {TelemetryHandlers, :start_link, [[{"Probe", attach}], []]}
      })

    assert TelemetryHandlers.check(server) == []

    capture_log(fn -> :telemetry.execute(event, %{}, %{}) end)
    refute Enum.any?(:telemetry.list_handlers(event), &(&1.id == id))

    log = capture_log(fn -> assert TelemetryHandlers.check(server) == ["Probe"] end)
    assert log =~ "Probe had been detached"
    assert Enum.any?(:telemetry.list_handlers(event), &(&1.id == id))
  end
end
