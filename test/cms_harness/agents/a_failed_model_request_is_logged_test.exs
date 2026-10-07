defmodule CmsHarness.Agents.AFailedModelRequestIsLoggedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CmsHarness.Agents.ProviderTelemetry

  @event [:alloy, :provider, :request]

  test "a failed request says how long it ran and which attempt it was" do
    meta = %{
      provider: Alloy.Provider.OpenAICompat,
      model: "zai-org/GLM-5.3",
      streaming: true,
      attempt: 2,
      result: :error
    }

    log =
      capture_log([level: :warning], fn ->
        ProviderTelemetry.handle_event(@event, %{duration_ms: 15_003}, meta, nil)
      end)

    assert log =~ "model request failed after 15003ms"
    assert log =~ "zai-org/GLM-5.3 attempt 2"
  end

  test "a request that worked is not logged" do
    log =
      capture_log([level: :warning], fn ->
        ProviderTelemetry.handle_event(@event, %{duration_ms: 900}, %{result: :ok}, nil)
      end)

    refute log =~ "model request"
  end
end
