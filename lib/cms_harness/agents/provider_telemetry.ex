defmodule CmsHarness.Agents.ProviderTelemetry do
  @moduledoc """
  Logs a failed model request with how long it ran and which attempt it was.

  A turn that dies on `%Req.TransportError{reason: :timeout}` says nothing about
  which limit fired; the duration does — Req's 15s default, a 30s connect, or
  what was left of the turn's deadline.
  """
  require Logger

  @event [:alloy, :provider, :request]

  def attach do
    :telemetry.attach(__MODULE__, @event, &__MODULE__.handle_event/4, nil)
  end

  def handle_event(@event, %{duration_ms: ms}, %{result: :error} = meta, _config) do
    Logger.warning(
      "[CmsHarness] model request failed after #{ms}ms: " <>
        "#{inspect(meta[:provider])} #{meta[:model]} attempt #{meta[:attempt]}, " <>
        "streaming=#{meta[:streaming]}"
    )
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok
end
