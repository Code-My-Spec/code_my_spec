defmodule CodeMySpec.McpServers.GoogleAds.Tools.ListAccessibleAccounts do
  @moduledoc "List the Google Ads accounts the connected user can access."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleTools

  schema do
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ads.list_accessible_accounts(token) do
      count = data |> Map.get("resourceNames", []) |> length()
      {:reply, GoogleTools.ok("Found #{count} accessible account(s).", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
