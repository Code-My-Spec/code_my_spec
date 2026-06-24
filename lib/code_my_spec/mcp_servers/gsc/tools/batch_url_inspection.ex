defmodule CodeMySpec.McpServers.Gsc.Tools.BatchUrlInspection do
  @moduledoc "Inspect up to 10 URLs at once (one per line)."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :urls, :string, required: true, doc: "URLs to inspect, one per line (max 10)"
  end

  @impl true
  def execute(params, frame) do
    urls = split_lines(params.urls)

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.batch_url_inspection(token, params.site_url, urls) do
      {:reply, GoogleTools.ok("Inspected #{data.count} URLs.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end

  defp split_lines(text) do
    text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end
end
