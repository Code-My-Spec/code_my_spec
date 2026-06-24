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
