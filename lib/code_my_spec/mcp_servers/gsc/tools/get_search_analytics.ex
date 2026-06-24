defmodule CodeMySpec.McpServers.Gsc.Tools.GetSearchAnalytics do
  @moduledoc """
  Top queries and pages with clicks, impressions, CTR, and position for a
  property over the last N days.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :days, :integer, doc: "Days to look back (default 28)"
    field :dimensions, :string, doc: "Comma-separated dimensions: query, page, device, country, date (default query)"
    field :row_limit, :integer, doc: "Rows to return (default 20, max 500)"
  end

  @impl true
  def execute(params, frame) do
    opts =
      [
        days: params[:days] || 28,
        dimensions: params[:dimensions] || "query",
        row_limit: params[:row_limit] || 20
      ]

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_search_analytics(token, params.site_url, opts) do
      {:reply, GoogleTools.ok("Search analytics for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
