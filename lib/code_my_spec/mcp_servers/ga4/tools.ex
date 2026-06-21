# Google Analytics (GA4) MCP tools, ported from
# https://github.com/googleanalytics/google-analytics-mcp — one Anubis
# component module per upstream tool. Thin wrappers over
# `CodeMySpec.Google.Ga4`, rendered via `CodeMySpec.McpServers.GoogleTools`.

defmodule CodeMySpec.McpServers.Ga4.Tools.GetAccountSummaries do
  @moduledoc "Retrieve the user's Google Analytics accounts and their property summaries."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.get_account_summaries(token) do
      {:reply, GoogleTools.ok("Found #{length(data)} account summaries.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Ga4.Tools.ListGoogleAdsLinks do
  @moduledoc "List the Google Ads links for a property."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string,
      required: true,
      doc: "Property ID — a number, or a string like \"properties/123456789\""
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.list_google_ads_links(token, params.property_id) do
      {:reply, GoogleTools.ok("Found #{length(data)} Google Ads links.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Ga4.Tools.GetPropertyDetails do
  @moduledoc "Return details about a Google Analytics property."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string,
      required: true,
      doc: "Property ID — a number, or a string like \"properties/123456789\""
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.get_property_details(token, params.property_id) do
      {:reply, GoogleTools.ok("Property details.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Ga4.Tools.ListPropertyAnnotations do
  @moduledoc """
  Return reporting data annotations for a property. Annotations are notes on
  GA4 for specific dates or periods (releases, campaigns, traffic events).
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string,
      required: true,
      doc: "Property ID — a number, or a string like \"properties/123456789\""
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.list_property_annotations(token, params.property_id) do
      {:reply, GoogleTools.ok("Found #{length(data)} annotations.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Ga4.Tools.GetCustomDimensionsAndMetrics do
  @moduledoc "Return the property's custom dimensions and metrics."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string,
      required: true,
      doc: "Property ID — a number, or a string like \"properties/123456789\""
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.get_custom_dimensions_and_metrics(token, params.property_id) do
      summary =
        "#{length(data.custom_dimensions)} custom dimensions, #{length(data.custom_metrics)} custom metrics."

      {:reply, GoogleTools.ok(summary, data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Ga4.Tools.RunReport do
  @moduledoc """
  Run a Google Analytics Data API report.

  `date_ranges` is a list of `{startDate, endDate}` objects, `dimensions`
  and `metrics` are lists of API field names. Filters and order_bys accept
  the Data API REST shapes (FilterExpression / OrderBy). Use
  get_custom_dimensions_and_metrics for a property's custom fields.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string, required: true, doc: "Property ID (number or \"properties/123\")"
    field :date_ranges, {:list, :map}, required: true, doc: "List of {startDate, endDate} objects"
    field :dimensions, {:list, :string}, required: true, doc: "Dimension field names"
    field :metrics, {:list, :string}, required: true, doc: "Metric field names"
    field :dimension_filter, :map, doc: "Data API FilterExpression for dimensions"
    field :metric_filter, :map, doc: "Data API FilterExpression for metrics"
    field :order_bys, {:list, :map}, doc: "List of Data API OrderBy objects"
    field :limit, :integer, doc: "Max rows per response (<= 250000)"
    field :offset, :integer, doc: "Start row (0-based)"
    field :currency_code, :string, doc: "ISO 4217 currency code"
    field :return_property_quota, :boolean, doc: "Include property quota in the response"
  end

  @impl true
  def execute(params, frame) do
    opts = CodeMySpec.McpServers.Ga4.Tools.report_opts(params)

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.run_report(token, params.property_id, opts) do
      {:reply, GoogleTools.ok("Report results.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Ga4.Tools.RunRealtimeReport do
  @moduledoc "Run a Google Analytics Data API realtime report (realtime dimensions/metrics only)."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string, required: true, doc: "Property ID (number or \"properties/123\")"
    field :dimensions, {:list, :string}, required: true, doc: "Realtime dimension field names"
    field :metrics, {:list, :string}, required: true, doc: "Realtime metric field names"
    field :dimension_filter, :map, doc: "Data API FilterExpression for dimensions"
    field :metric_filter, :map, doc: "Data API FilterExpression for metrics"
    field :order_bys, {:list, :map}, doc: "List of Data API OrderBy objects"
    field :limit, :integer, doc: "Max rows per response (<= 250000)"
    field :offset, :integer, doc: "Start row (0-based)"
    field :return_property_quota, :boolean, doc: "Include realtime property quota in the response"
  end

  @impl true
  def execute(params, frame) do
    opts = CodeMySpec.McpServers.Ga4.Tools.report_opts(params)

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.run_realtime_report(token, params.property_id, opts) do
      {:reply, GoogleTools.ok("Realtime report results.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Ga4.Tools.RunConversionsReport do
  @moduledoc """
  Run a Google Analytics conversions report. Use this instead of run_report
  for conversions, ad performance, ROAS, or attribution. Requires a
  conversion_spec.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string, required: true, doc: "Property ID (number or \"properties/123\")"
    field :date_ranges, {:list, :map}, required: true, doc: "List of {startDate, endDate} objects"
    field :dimensions, {:list, :string}, required: true, doc: "Allowed conversion dimensions"
    field :metrics, {:list, :string}, required: true, doc: "Allowed conversion metrics"
    field :conversion_spec, :map, required: true, doc: "{conversion_actions, attribution_model}"
    field :dimension_filter, :map, doc: "Data API FilterExpression for dimensions"
    field :metric_filter, :map, doc: "Data API FilterExpression for metrics"
    field :order_bys, {:list, :map}, doc: "List of Data API OrderBy objects"
    field :limit, :integer, doc: "Max rows per response (<= 250000)"
    field :offset, :integer, doc: "Start row (0-based)"
    field :currency_code, :string, doc: "ISO 4217 currency code"
    field :return_property_quota, :boolean, doc: "Include property quota in the response"
  end

  @impl true
  def execute(params, frame) do
    opts =
      params
      |> CodeMySpec.McpServers.Ga4.Tools.report_opts()
      |> Keyword.put(:conversion_spec, params.conversion_spec)

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.run_conversions_report(token, params.property_id, opts) do
      {:reply, GoogleTools.ok("Conversions report results.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Ga4.Tools.RunFunnelReport do
  @moduledoc """
  Run a Google Analytics Data API funnel report (Alpha). Each funnel step
  has a name and either an `event` shorthand or a complete
  `filter_expression`.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string, required: true, doc: "Property ID (number or \"properties/123\")"
    field :funnel_steps, {:list, :map}, required: true, doc: "Steps: each {name, event} or {name, filter_expression}"
    field :date_ranges, {:list, :map}, doc: "List of {startDate, endDate} objects"
    field :funnel_breakdown, :map, doc: "{breakdown_dimension: \"deviceCategory\"}"
    field :funnel_next_action, :map, doc: "{next_action_dimension: \"eventName\", limit: 5}"
    field :segments, {:list, :map}, doc: "List of Data API Segment objects"
    field :return_property_quota, :boolean, doc: "Include property quota in the response"
  end

  @impl true
  def execute(params, frame) do
    opts =
      [
        funnel_steps: params.funnel_steps,
        date_ranges: params[:date_ranges],
        funnel_breakdown: params[:funnel_breakdown],
        funnel_next_action: params[:funnel_next_action],
        segments: params[:segments],
        return_property_quota: params[:return_property_quota] || false
      ]

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.run_funnel_report(token, params.property_id, opts) do
      {:reply, GoogleTools.ok("Funnel report results.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Ga4.Tools do
  @moduledoc false

  # Builds the shared keyword opts for the report client functions from the
  # tool params, dropping nil values.
  @report_keys [
    :date_ranges,
    :dimensions,
    :metrics,
    :dimension_filter,
    :metric_filter,
    :order_bys,
    :limit,
    :offset,
    :currency_code,
    :return_property_quota
  ]

  @spec report_opts(map()) :: keyword()
  def report_opts(params) do
    @report_keys
    |> Enum.reduce([], fn key, acc ->
      case Map.get(params, key) do
        nil -> acc
        value -> [{key, value} | acc]
      end
    end)
  end
end
