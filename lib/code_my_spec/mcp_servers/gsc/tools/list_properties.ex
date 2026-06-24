defmodule CodeMySpec.McpServers.Gsc.Tools.ListProperties do
  @moduledoc """
  List all Google Search Console properties the user has access to. Always
  call this first to get the exact site_url needed for other tools.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.list_properties(token) do
      {:reply, GoogleTools.ok("Found #{data.count} GSC properties.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
