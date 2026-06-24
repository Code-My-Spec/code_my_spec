defmodule CodeMySpec.McpServers.Gsc.Tools.GetSearchByPageQuery do
  @moduledoc "Search analytics for a specific page, broken down by query."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :page_url, :string, required: true, doc: "The specific page URL to analyze"
    field :days, :integer, doc: "Days to look back (default 28)"
    field :row_limit, :integer, doc: "Rows to return (default 20, max 500)"
  end

  @impl true
  def execute(params, frame) do
    opts = [days: params[:days] || 28, row_limit: params[:row_limit] || 20]

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_search_by_page_query(token, params.site_url, params.page_url, opts) do
      {:reply, GoogleTools.ok("Queries for #{params.page_url}.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
