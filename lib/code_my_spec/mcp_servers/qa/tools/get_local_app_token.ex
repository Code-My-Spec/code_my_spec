defmodule CodeMySpec.McpServers.Qa.Tools.GetLocalAppToken do
  @moduledoc """
  Mint a short-lived access token for the caller's own copy's own running
  app instance, so it can be handed to `call_mcp_server` as that instance's
  `Authorization` header.

  b3005df9: a change whose deliverable is served by the harness itself (a new
  MCP tool, a `tool_docs` entry, a knowledge doc, a prompt) had no live route
  for QA to exercise before promotion -- `run_script`/`tool_docs` are served
  by the harness on *main's* checkout, and the change exists only on this
  copy until it lands. John's decision (question 0e26edb8): QA verifies such
  a change by calling the *copy's own* `/mcp/harness` -- the same route, but
  served by the app instance `ensure_app_running` started for this copy,
  compiled from this copy's own code.

  Reaching that instance over HTTP is not the gap: every non-main copy's app
  runs on `localhost` on this same machine (`AppInstance.database_name/1`'s
  own moduledoc: a clone of main's dev database, not a disposable copy with
  nothing in it), so the deploy key on this project's row was cloned right
  along with it, and `call_mcp_server` can already reach any `localhost` URL.
  The gap is auth: `/mcp/harness` sits behind `require_oauth_token`
  (`CodeMySpecWeb.Router`'s `:mcp_protected` pipeline), and nothing before
  this handed an agent a token good against that one instance's own,
  separate `AccessTokens` table.

  This does exactly what `CmsHarness.Token` already does for the harness
  itself -- trade the project's deploy key for a token at `POST
  /api/sprite/token` (`CodeMySpecWeb.SpriteTokenController`) -- except
  against the URL the caller names instead of the fixed server the harness
  always talks to, and it hands the *resulting* token back rather than
  holding it. The deploy key itself is read here and never returned: this
  tool's whole point is that the caller never needs to see it, the same
  shape `SpriteTokenController`'s own moduledoc gives for why a sprite
  trades its key for a token rather than presenting it everywhere.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects

  @exchange_timeout 30_000

  schema do
    field :url, :string,
      required: true,
      description: "Base URL of the copy's own running app instance, from ensure_app_running."
  end

  @impl true
  def execute(%{url: url} = params, frame) when is_binary(url) and url != "" do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- Projects.get_project(scope, scope.active_project_id) do
      {:reply, exchange(url, project.deploy_key), frame}
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  def execute(_params, frame) do
    {:reply, error("a url is required -- the one ensure_app_running gave you for this copy"), frame}
  end

  defp exchange(_url, nil), do: error(:no_deploy_key)

  defp exchange(url, deploy_key) do
    request =
      Req.new(
        method: :post,
        url: String.trim_trailing(url, "/") <> "/api/sprite/token",
        headers: [{"authorization", "Bearer " <> deploy_key}],
        retry: false,
        receive_timeout: @exchange_timeout
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}} ->
        ok(token, expires_in, url)

      {:ok, %{status: status}} ->
        error({:refused, status})

      {:error, reason} ->
        error({:unreachable, reason})
    end
  end

  defp ok(token, expires_in, url) do
    Response.tool()
    |> Response.text("""
    Access token for #{url}, valid #{expires_in}s: #{token}

    Use it with call_mcp_server against this same url, path "/mcp/harness",
    headers {"Authorization": "Bearer #{token}"} -- no X-Harness-Id needed,
    since this instance's own database holds only this one copy's data.
    """)
  end

  defp error(reason),
    do: Response.tool() |> Response.error("Could not get a token for that instance: #{inspect(reason)}")
end
