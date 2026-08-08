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
  `OAuthClient.get_token/0`.

  Two different situations reach here and they need different answers, which is
  why this does not simply say "signed out":

    * no credential at all — sign in, and the link has to work
    * a project deploy key, which *is* a credential and authenticates fine, but
      is scoped to one project. Account-level calls like listing projects
      cannot succeed with it no matter how many times somebody signs in.

  Telling the second case to go and authenticate sends them round a loop that
  cannot terminate. The path matters too: `/auth` 404s — the page is
  `/app/auth`.
  """
  def not_authenticated_error do
    auth_url = "#{CodeMySpec.PublicUrl.local_base()}/app/auth"

    error("""
    This call needs an account-level credential and the harness does not have one.

    If it is running on a project deploy key (CMS_DEPLOY_KEY), that key is scoped to a single project — it authenticates, but it cannot see your other projects, so signing in again will not help. Name the project directly instead.

    If there is no credential at all, sign in at #{auth_url}. The agent cannot complete the OAuth flow itself — you need to do it once manually. An already-open session then needs /mcp to reconnect before it picks the new credential up.
    """)
  end
end
