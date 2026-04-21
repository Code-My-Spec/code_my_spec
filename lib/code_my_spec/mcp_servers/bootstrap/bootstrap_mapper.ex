defmodule CodeMySpec.McpServers.Bootstrap.BootstrapMapper do
  @moduledoc """
  Maps bootstrap tool results to MCP responses.
  """

  alias Anubis.Server.Response

  def install_success(path) do
    Response.tool()
    |> Response.text("Installed: #{path}")
  end

  def install_success(path, _extras) do
    Response.tool()
    |> Response.text("Installed: #{path}")
  end

  def init_success(config_path, project_name) do
    Response.tool()
    |> Response.text("Project initialized: #{project_name}\nConfig: #{config_path}")
  end

  def status_response(text, _data) do
    Response.tool()
    |> Response.text(text)
  end

  def error(reason) when is_binary(reason) do
    Response.tool()
    |> Response.error(reason)
  end

  def error(reason), do: error(inspect(reason))

  @doc """
  Friendly error for `:not_authenticated` / `:needs_authentication` from
  `OAuthClient.get_token/0`. Tells the user exactly where to sign in.
  """
  def not_authenticated_error do
    auth_url = "#{CodeMySpecLocalWeb.Endpoint.url()}/auth"

    error("""
    Not authenticated. Visit #{auth_url} in your browser and sign in before calling CodeMySpec MCP tools.

    The agent cannot complete the OAuth flow itself — you need to sign in once manually.
    """)
  end
end
