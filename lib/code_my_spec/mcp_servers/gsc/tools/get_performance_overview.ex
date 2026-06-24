defmodule CodeMySpec.McpServers.Gsc.Tools.GetPerformanceOverview do
  @moduledoc "Summary totals plus a daily trend for a property over the last N days."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :days, :integer, doc: "Days to look back (default 28)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_performance_overview(token, params.site_url, params[:days] || 28) do
      {:reply, GoogleTools.ok("Performance overview for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
