defmodule CodeMySpec.McpServers.Gsc.Tools.CheckIndexingIssues do
  @moduledoc "Check multiple URLs (one per line, max 10) for indexing problems."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :urls, :string, required: true, doc: "URLs to check, one per line (max 10)"
  end

  @impl true
  def execute(params, frame) do
    urls = params.urls |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.check_indexing_issues(token, params.site_url, urls) do
      {:reply, GoogleTools.ok("Indexing check for #{params.site_url}.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
