defmodule CodeMySpec.Analytics.GoogleAnalytics do
  @moduledoc """
  Server-side delivery of activation events to Google Analytics via
  the Measurement Protocol (GA4).

  Subscribed to `CodeMySpec.Analytics`'s telemetry event in
  `application.ex`. Each dispatched event becomes a Measurement
  Protocol payload posted to the configured endpoint.

  Delivery is fire-and-forget per product direction — failures are
  logged and dropped. No retry queue, no DLQ.

  ## Configuration

      config :code_my_spec, CodeMySpec.Analytics.GoogleAnalytics,
        measurement_id: "G-XXXXXXX",
        api_secret: System.fetch_env!("GA4_MP_API_SECRET"),
        endpoint: "https://www.google-analytics.com/mp/collect",
        http_adapter: CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter

  In test, set `http_adapter` to a module that captures the payload
  to a registered sink — see `attach_test_subscriber/1`.
  """

  require Logger

  alias CodeMySpec.Utils.MapAccess

  @telemetry_event CodeMySpec.Analytics.telemetry_event()

  @doc """
  Attaches the GA handler to the analytics telemetry stream. Called
  from `application.ex`; safe to call multiple times.
  """
  def attach do
    :telemetry.attach(
      handler_id(),
      @telemetry_event,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event(@telemetry_event, _measurements, metadata, _config) do
    origin = Map.get(metadata, :origin, :server)

    Logger.info("GA MP handler received event",
      event: metadata.event,
      user_id: MapAccess.get(metadata.payload, :user_id),
      origin: origin
    )

    case origin do
      :browser ->
        # Browser-originated events are forwarded to GA by gtag on the
        # client. Skipping MP delivery here avoids double-counting.
        :ok

      :server ->
        payload = build_payload(metadata.event, metadata.payload)
        deliver(payload, metadata.event)
    end
  end

  @doc """
  Registers `pid` to receive a copy of every Measurement Protocol
  payload as `{:ga_measurement_protocol, payload}`. Used by spex
  tests via the Fixtures bridge.
  """
  def attach_test_subscriber(pid) when is_pid(pid) do
    :persistent_term.put({__MODULE__, :test_subscriber}, pid)
    :ok
  end

  @doc "Removes the registered test subscriber, if any."
  def detach_test_subscriber(_pid) do
    :persistent_term.erase({__MODULE__, :test_subscriber})
    :ok
  end

  defp build_payload(event_name, payload) do
    user_id = MapAccess.get(payload, :user_id)

    %{
      client_id: client_id(payload),
      user_id: to_string_or_nil(user_id),
      events: [
        %{
          name: to_string(event_name),
          params: event_params(payload)
        }
      ]
    }
  end

  # GA4 event params. session_id (when threaded from the _ga_<container> cookie)
  # belongs inside the event params, not at the payload root — that's what
  # stitches the conversion to the browser's gtag session (rule f9b2c751).
  defp event_params(payload) do
    payload
    |> stringify_params()
    |> maybe_put_session_id(payload)
  end

  defp maybe_put_session_id(params, payload) do
    case MapAccess.get(payload, :ga_session_id) do
      sid when is_binary(sid) and sid != "" -> Map.put(params, "session_id", sid)
      _ -> params
    end
  end

  # client_id resolution order:
  #   1. Explicit `ga_client_id` in the payload — the _ga cookie value threaded
  #      by registration.ex (plug → session → socket assign → dispatch arg).
  #      This stitches the server-side conversion to the browser's GA4 session.
  #   2. Stable per-user fallback: "cms-" <> first 16 hex chars of SHA-256(user_id).
  #      Same user always gets the same id even without a _ga cookie (first_cli_connect).
  #   3. Last resort: UUID. Should not happen for conversion events in practice.
  defp client_id(payload) do
    explicit = MapAccess.get(payload, :ga_client_id)
    user_id = MapAccess.get(payload, :user_id)

    cond do
      is_binary(explicit) and explicit != "" ->
        explicit

      not is_nil(user_id) ->
        # Deterministic per-user id for conversions without a _ga cookie
        # (e.g. first_cli_connect — no browser session in that flow).
        hash =
          :crypto.hash(:sha256, to_string(user_id))
          |> Base.encode16(case: :lower)
          |> String.slice(0, 16)

        "cms-" <> hash

      true ->
        # Last resort: random UUID. Avoids all events collapsing into one
        # GA profile but won't stitch to any browser session.
        Ecto.UUID.generate()
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp stringify_params(payload) do
    payload
    |> Map.delete(:user_id)
    |> Map.delete("user_id")
    |> Map.delete(:ga_client_id)
    |> Map.delete("ga_client_id")
    |> Map.delete(:ga_session_id)
    |> Map.delete("ga_session_id")
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp deliver(payload, event) do
    case test_subscriber() do
      nil -> deliver_via_http(payload, event)
      pid -> send(pid, {:ga_measurement_protocol, payload})
    end
  end

  defp test_subscriber do
    case :persistent_term.get({__MODULE__, :test_subscriber}, nil) do
      nil -> nil
      pid -> if Process.alive?(pid), do: pid
    end
  end

  defp deliver_via_http(payload, event) do
    config = Application.get_env(:code_my_spec, __MODULE__, [])

    measurement_id = Keyword.get(config, :measurement_id)
    api_secret = Keyword.get(config, :api_secret)
    user_id = MapAccess.get(payload, :user_id)

    if is_nil(measurement_id) or is_nil(api_secret) do
      # Debug, not warning. GA being unconfigured is a steady state, not an
      # anomaly — it is the intended condition in test and in any dev checkout
      # without GA4 credentials, and this runs once per analytics event. At
      # warning level it emitted 2,190 lines in a single suite run, which
      # buries the warnings that do mean something.
      #
      # A deployment that wants GA and has not configured it is worth saying
      # loudly, but once at boot rather than per event.
      Logger.debug("GA MP delivery skipped: missing measurement_id or api_secret",
        event: event,
        user_id: user_id,
        mp_status: :missing_config
      )

      :ok
    else
      endpoint =
        Keyword.get(config, :endpoint, "https://www.google-analytics.com/mp/collect")

      adapter = Keyword.get(config, :http_adapter, __MODULE__.HTTPAdapter)

      url =
        endpoint <>
          "?" <>
          URI.encode_query(%{"measurement_id" => measurement_id, "api_secret" => api_secret})

      try do
        adapter.post(url, payload, event: event, user_id: user_id)
      rescue
        err ->
          Logger.warning("GA MP delivery raised",
            event: event,
            user_id: user_id,
            mp_status: :raised,
            error: inspect(err)
          )
      catch
        kind, reason ->
          Logger.warning("GA MP delivery threw",
            event: event,
            user_id: user_id,
            mp_status: :threw,
            error: inspect({kind, reason})
          )
      end

      :ok
    end
  end

  defp handler_id, do: {__MODULE__, :ga_measurement_protocol}
end
