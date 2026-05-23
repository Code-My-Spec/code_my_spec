defmodule CodeMySpec.Analytics.GoogleAnalytics.ReportingClient do
  @moduledoc """
  Req-based client for the Google Analytics Data API v1beta — the
  read side of GA, complementing the Measurement Protocol write side
  in `CodeMySpec.Analytics.GoogleAnalytics`.

  Used by spex tests via `CodeMySpecSpex.GaAssertions` to verify that
  events dispatched through MP actually landed in GA. Cassette-friendly
  via the same Req `plug` option pattern as
  `CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter` — tests inject a
  ReqCassette plug so HTTP can be recorded once and replayed
  deterministically.

  Auth flows through `CodeMySpec.Google.Auth.get_valid_token/1` so the
  refresh / expiration logic is shared with the admin API client.

  ## Configuration

      config :code_my_spec, CodeMySpec.Analytics.GoogleAnalytics.ReportingClient,
        endpoint: "https://analyticsdata.googleapis.com/v1beta",
        plug: nil  # tests set this to a ReqCassette plug

  ## Example

      iex> ReportingClient.run_realtime_report(scope, "508773792", %{
      ...>   "dimensions" => [%{"name" => "eventName"}],
      ...>   "metrics" => [%{"name" => "eventCount"}],
      ...>   "dimensionFilter" => %{
      ...>     "filter" => %{
      ...>       "fieldName" => "eventName",
      ...>       "stringFilter" => %{"value" => "sign_up", "matchType" => "EXACT"}
      ...>     }
      ...>   }
      ...> })
      {:ok, %{"rows" => [%{"dimensionValues" => [%{"value" => "sign_up"}], ...}]}}
  """

  require Logger

  alias CodeMySpec.Google.Auth
  alias CodeMySpec.Users.Scope

  @default_endpoint "https://analyticsdata.googleapis.com/v1beta"

  @doc """
  Runs a Realtime Report against a GA4 property.

  Realtime data covers the most recent 30 minutes and has a smaller
  dimension/metric surface than the standard Report API, but events
  appear within minutes rather than 24-48 hours — which is what makes
  round-trip cassette verification practical.

  `request` is the JSON body documented at
  https://developers.google.com/analytics/devguides/reporting/data/v1/rest/v1beta/properties/runRealtimeReport
  """
  @spec run_realtime_report(Scope.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_realtime_report(%Scope{} = scope, property_id, request, opts \\ [])
      when is_binary(property_id) and is_map(request) do
    post(scope, property_id, ":runRealtimeReport", request, opts)
  end

  @doc """
  Runs a standard Report against a GA4 property.

  Use this for windows where eventual consistency isn't a blocker
  (yesterday or earlier). For freshly-dispatched events use
  `run_realtime_report/3` instead.
  """
  @spec run_report(Scope.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def run_report(%Scope{} = scope, property_id, request)
      when is_binary(property_id) and is_map(request) do
    post(scope, property_id, ":runReport", request)
  end

  defp post(%Scope{} = scope, property_id, suffix, request, opts \\ []) do
    # Allow the caller to inject a pre-fetched token so the DB query
    # doesn't need to happen at request time — useful when the request
    # may run after a long sleep (e.g. cassette recording with GA
    # Realtime API ingest latency) where the Ecto sandbox connection
    # could be lost.
    token_result =
      case Keyword.get(opts, :token) do
        nil -> Auth.get_valid_token(scope)
        token when is_binary(token) -> {:ok, token}
      end

    with {:ok, token} <- token_result do
      url = endpoint() <> "/properties/" <> property_id <> suffix

      req_opts =
        [
          method: :post,
          url: url,
          headers: [{"authorization", "Bearer " <> token}],
          json: request,
          receive_timeout: 10_000
        ]
        |> Keyword.merge(plug_opt())

      case Req.request(req_opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("GA Reporting non-2xx",
            url: url,
            status: status,
            body: inspect(body)
          )

          {:error, {:unexpected_status, status, body}}

        {:error, reason} ->
          Logger.warning("GA Reporting HTTP error", url: url, error: inspect(reason))
          {:error, reason}
      end
    end
  end

  defp endpoint do
    Application.get_env(:code_my_spec, __MODULE__, [])
    |> Keyword.get(:endpoint, @default_endpoint)
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
