defmodule CodeMySpec.McpServers.Gsc.Tools.CompareSearchPeriods do
  @moduledoc "Compare search analytics between two time periods, sorted by click delta."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :period1_start, :string, required: true, doc: "Period 1 start (YYYY-MM-DD)"
    field :period1_end, :string, required: true, doc: "Period 1 end (YYYY-MM-DD)"
    field :period2_start, :string, required: true, doc: "Period 2 start (YYYY-MM-DD)"
    field :period2_end, :string, required: true, doc: "Period 2 end (YYYY-MM-DD)"
    field :dimensions, :string, doc: "Dimensions to group by (default query)"
    field :limit, :integer, doc: "Top results to compare (default 10)"
  end

  @impl true
  def execute(params, frame) do
    opts = [
      period1_start: params.period1_start,
      period1_end: params.period1_end,
      period2_start: params.period2_start,
      period2_end: params.period2_end,
      dimensions: params[:dimensions] || "query",
      limit: params[:limit] || 10
    ]

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.compare_search_periods(token, params.site_url, opts) do
      {:reply, GoogleTools.ok("Period comparison for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
