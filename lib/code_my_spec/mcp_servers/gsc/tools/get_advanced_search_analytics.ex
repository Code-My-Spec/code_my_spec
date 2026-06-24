defmodule CodeMySpec.McpServers.Gsc.Tools.GetAdvancedSearchAnalytics do
  @moduledoc """
  Advanced search analytics with sorting, multi-dimension filtering, search
  type, and pagination.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :start_date, :string, doc: "YYYY-MM-DD (default 28 days ago)"
    field :end_date, :string, doc: "YYYY-MM-DD (default today)"
    field :dimensions, :string, doc: "Comma-separated dimensions (default query)"
    field :search_type, :string, doc: "WEB, IMAGE, VIDEO, NEWS, DISCOVER (default WEB)"
    field :row_limit, :integer, doc: "Max rows (max 25000, default 1000)"
    field :start_row, :integer, doc: "Pagination start row (default 0)"
    field :sort_by, :string, doc: "clicks, impressions, ctr, position (default clicks)"
    field :sort_direction, :string, doc: "ascending or descending (default descending)"
    field :filter_dimension, :string, doc: "Single filter dimension: query, page, country, device"
    field :filter_operator, :string, doc: "contains, equals, notContains, notEquals (default contains)"
    field :filter_expression, :string, doc: "Single filter value"
    field :filters, {:list, :map}, doc: "List of {dimension, operator, expression} filter objects (AND logic). Overrides single-filter params."
    field :data_state, :string, doc: "all (default) or final"
  end

  @impl true
  def execute(params, frame) do
    opts =
      params
      |> Map.take([
        :start_date,
        :end_date,
        :dimensions,
        :search_type,
        :row_limit,
        :start_row,
        :sort_by,
        :sort_direction,
        :filter_dimension,
        :filter_operator,
        :filter_expression,
        :filters,
        :data_state
      ])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_advanced_search_analytics(token, params.site_url, opts) do
      {:reply, GoogleTools.ok("Advanced search analytics for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
