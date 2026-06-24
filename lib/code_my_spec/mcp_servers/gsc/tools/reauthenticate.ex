defmodule CodeMySpec.McpServers.Gsc.Tools.Reauthenticate do
  @moduledoc """
  Guidance for reconnecting the Google account when Search Console calls
  return auth errors.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.GoogleTools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    {:reply,
     GoogleTools.text(
       "Authentication is managed by CodeMySpec's Google integration, not a local " <>
         "browser flow. Reconnect your Google account (with the Search Console scope " <>
         "https://www.googleapis.com/auth/webmasters) from the integrations settings, " <>
         "then retry."
     ), frame}
  end
end
