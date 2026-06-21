defmodule CodeMySpec.Google.Ga4 do
  @moduledoc """
  Hand-written `Req` client for the Google Analytics Admin and Data APIs,
  ported from the
  [google-analytics-mcp](https://github.com/googleanalytics/google-analytics-mcp)
  server.

  The upstream server uses the gRPC client libraries with protobuf
  (snake_case) field names; this port targets the REST surface, so request
  bodies and responses use the REST **camelCase** field names documented at
  https://developers.google.com/analytics/devguides/reporting/data/v1/rest.

  Each public function maps 1:1 to a tool and returns `{:ok, data}` /
  `{:error, reason}`. The `CodeMySpec.McpServers.Ga4` tool modules are thin
  wrappers that resolve a token and render the result.

  ## APIs

  - Admin API (`v1beta` / `v1alpha`): `https://analyticsadmin.googleapis.com`
  - Data API (`v1beta` / `v1alpha`): `https://analyticsdata.googleapis.com`

  ## Test injection

  Tests set `config :code_my_spec, #{inspect(__MODULE__)}, plug: plug` to
  route `Req` through a `ReqCassette` plug.
  """

  @admin "https://analyticsadmin.googleapis.com"
  @data "https://analyticsdata.googleapis.com"

  @type token :: String.t()
  @type property :: integer() | String.t()
  @type result :: {:ok, map() | list()} | {:error, term()}

  # ── Admin: account & property info ────────────────────────────────────

  @doc "Lists the user's GA accounts and their property summaries."
  @spec get_account_summaries(token) :: {:ok, [map()]} | {:error, term()}
  def get_account_summaries(token) do
    list_all(token, @admin <> "/v1beta/accountSummaries", "accountSummaries")
  end

  @doc "Lists Google Ads links for a property."
  @spec list_google_ads_links(token, property) :: {:ok, [map()]} | {:error, term()}
  def list_google_ads_links(token, property_id) do
    with {:ok, rn} <- property_rn(property_id) do
      list_all(token, @admin <> "/v1beta/#{rn}/googleAdsLinks", "googleAdsLinks")
    end
  end

  @doc "Returns details about a property."
  @spec get_property_details(token, property) :: result
  def get_property_details(token, property_id) do
    with {:ok, rn} <- property_rn(property_id) do
      request(:get, @admin <> "/v1beta/#{rn}", token)
    end
  end

  @doc "Lists reporting data annotations for a property (Admin v1alpha)."
  @spec list_property_annotations(token, property) :: {:ok, [map()]} | {:error, term()}
  def list_property_annotations(token, property_id) do
    with {:ok, rn} <- property_rn(property_id) do
      list_all(
        token,
        @admin <> "/v1alpha/#{rn}/reportingDataAnnotations",
        "reportingDataAnnotations"
      )
    end
  end

  # ── Data: metadata ────────────────────────────────────────────────────

  @doc """
  Returns the property's custom dimensions and metrics, filtered from the
  Data API metadata response by `customDefinition`.
  """
  @spec get_custom_dimensions_and_metrics(token, property) :: result
  def get_custom_dimensions_and_metrics(token, property_id) do
    with {:ok, rn} <- property_rn(property_id),
         {:ok, metadata} <- request(:get, @data <> "/v1beta/#{rn}/metadata", token) do
      custom_dimensions =
        metadata |> Map.get("dimensions", []) |> Enum.filter(&Map.get(&1, "customDefinition", false))

      custom_metrics =
        metadata |> Map.get("metrics", []) |> Enum.filter(&Map.get(&1, "customDefinition", false))

      {:ok, %{custom_dimensions: custom_dimensions, custom_metrics: custom_metrics}}
    end
  end

  # ── Data: reports ─────────────────────────────────────────────────────

  @doc """
  Runs a core report (Data API `runReport`).

  `opts` keys (all optional unless noted):
  `:date_ranges` (required, list of `%{"startDate" => ..., "endDate" => ...}`),
  `:dimensions` (required, list of strings), `:metrics` (required, list of
  strings), `:dimension_filter`, `:metric_filter`, `:order_bys`, `:limit`,
  `:offset`, `:currency_code`, `:return_property_quota`.
  """
  @spec run_report(token, property, keyword()) :: result
  def run_report(token, property_id, opts) do
    with {:ok, rn} <- property_rn(property_id) do
      body =
        base_report_body(opts)
        |> put_present("dateRanges", opts[:date_ranges])

      request(:post, @data <> "/v1beta/#{rn}:runReport", token, json: body)
    end
  end

  @doc "Runs a realtime report (Data API `runRealtimeReport`)."
  @spec run_realtime_report(token, property, keyword()) :: result
  def run_realtime_report(token, property_id, opts) do
    with {:ok, rn} <- property_rn(property_id) do
      body = base_report_body(opts)
      request(:post, @data <> "/v1beta/#{rn}:runRealtimeReport", token, json: body)
    end
  end

  @doc """
  Runs a conversions report (Data API `v1alpha` `runReport` with a
  `conversionSpec`). `:conversion_spec` is required.
  """
  @spec run_conversions_report(token, property, keyword()) :: result
  def run_conversions_report(token, property_id, opts) do
    with {:ok, rn} <- property_rn(property_id) do
      body =
        base_report_body(opts)
        |> put_present("dateRanges", opts[:date_ranges])
        |> Map.put("conversionSpec", opts[:conversion_spec] || %{})

      request(:post, @data <> "/v1alpha/#{rn}:runReport", token, json: body)
    end
  end

  @doc """
  Runs a funnel report (Data API `v1alpha` `runFunnelReport`).

  `:funnel_steps` is a required non-empty list. Each step is a map with a
  `"name"` and either a `"filter_expression"` (a complete REST
  FunnelFilterExpression) or an `"event"` (event name shorthand).
  """
  @spec run_funnel_report(token, property, keyword()) :: result
  def run_funnel_report(token, property_id, opts) do
    funnel_steps = opts[:funnel_steps] || []

    with {:ok, rn} <- property_rn(property_id),
         {:ok, steps} <- build_funnel_steps(funnel_steps) do
      body =
        %{
          "funnel" => %{"steps" => steps},
          "dateRanges" => opts[:date_ranges] || [],
          "returnPropertyQuota" => opts[:return_property_quota] || false
        }
        |> maybe_put_funnel_breakdown(opts[:funnel_breakdown])
        |> maybe_put_funnel_next_action(opts[:funnel_next_action])
        |> put_present("segments", opts[:segments])

      request(:post, @data <> "/v1alpha/#{rn}:runFunnelReport", token, json: body)
    end
  end

  # ── Report body construction ──────────────────────────────────────────

  defp base_report_body(opts) do
    %{
      "dimensions" => Enum.map(opts[:dimensions] || [], &%{"name" => &1}),
      "metrics" => Enum.map(opts[:metrics] || [], &%{"name" => &1}),
      "returnPropertyQuota" => opts[:return_property_quota] || false
    }
    |> put_present("dimensionFilter", opts[:dimension_filter])
    |> put_present("metricFilter", opts[:metric_filter])
    |> put_present("orderBys", opts[:order_bys])
    |> put_present("limit", opts[:limit])
    |> put_present("offset", opts[:offset])
    |> put_present("currencyCode", opts[:currency_code])
  end

  defp build_funnel_steps([]), do: {:error, :empty_funnel_steps}

  defp build_funnel_steps(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {step, i}, {:ok, acc} ->
      name = Map.get(step, "name", "Step #{i}")

      case build_funnel_filter(step) do
        {:ok, filter_expr} ->
          {:cont, {:ok, [%{"name" => name, "filterExpression" => filter_expr} | acc]}}

        :error ->
          {:halt, {:error, {:invalid_funnel_step, i}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp build_funnel_filter(%{"filter_expression" => expr}), do: {:ok, expr}

  defp build_funnel_filter(%{"event" => event}),
    do: {:ok, %{"funnelEventFilter" => %{"eventName" => event}}}

  defp build_funnel_filter(_), do: :error

  defp maybe_put_funnel_breakdown(body, %{"breakdown_dimension" => dim}) do
    Map.put(body, "funnelBreakdown", %{"breakdownDimension" => %{"name" => dim}})
  end

  defp maybe_put_funnel_breakdown(body, _), do: body

  defp maybe_put_funnel_next_action(body, %{"next_action_dimension" => dim} = next) do
    config = %{"nextActionDimension" => %{"name" => dim}}
    config = if next["limit"], do: Map.put(config, "limit", next["limit"]), else: config
    Map.put(body, "funnelNextAction", config)
  end

  defp maybe_put_funnel_next_action(body, _), do: body

  # ── Core request ──────────────────────────────────────────────────────

  defp request(method, url, token, opts \\ []) do
    req_opts =
      [
        method: method,
        url: url,
        headers: [
          {"authorization", "Bearer #{token}"},
          {"accept", "application/json"},
          {"user-agent", "CodeMySpec"}
        ]
      ]
      |> Keyword.merge(opts)
      |> Keyword.merge(plug_opt())

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body || %{}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:ga4_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Follows nextPageToken, accumulating the named collection across pages.
  defp list_all(token, url, key, acc \\ [], page_token \\ nil) do
    opts = if page_token, do: [params: [pageToken: page_token]], else: []

    case request(:get, url, token, opts) do
      {:ok, body} ->
        items = acc ++ Map.get(body, key, [])

        case Map.get(body, "nextPageToken") do
          nil -> {:ok, items}
          "" -> {:ok, items}
          next -> list_all(token, url, key, items, next)
        end

      {:error, _} = error ->
        error
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  @doc """
  Normalizes a property identifier to a `properties/<number>` resource
  name. Accepts an integer, a numeric string, or a `properties/<number>`
  string.
  """
  @spec property_rn(property) :: {:ok, String.t()} | {:error, {:invalid_property_id, term()}}
  def property_rn(property_id) when is_integer(property_id), do: {:ok, "properties/#{property_id}"}

  def property_rn(property_id) when is_binary(property_id) do
    trimmed = String.trim(property_id)

    cond do
      numeric?(trimmed) ->
        {:ok, "properties/#{trimmed}"}

      String.starts_with?(trimmed, "properties/") ->
        numeric_part = trimmed |> String.split("/") |> List.last()
        if numeric?(numeric_part), do: {:ok, "properties/#{numeric_part}"}, else: invalid(property_id)

      true ->
        invalid(property_id)
    end
  end

  def property_rn(other), do: invalid(other)

  defp invalid(value), do: {:error, {:invalid_property_id, value}}

  defp numeric?(s), do: s != "" and String.match?(s, ~r/^\d+$/)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
