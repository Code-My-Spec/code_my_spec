defmodule CodeMySpec.Migration.Client do
  @moduledoc """
  Sends a local project's authored graph to the cloud.

  The receiving half is `CodeMySpecWeb.MigrationsController`, which lands the
  whole payload in one transaction. This half only has to read the local
  project and hand it over, so a failure here costs nothing but the attempt —
  the local copy is never written to.

  Auth is the same shape every other local-to-cloud call uses (see
  `CodeMySpec.Issues.RemoteClient`): the stored OAuth token as a bearer, and
  `x-project-id` naming the cloud project to fill. That header is what the
  server's `ProjectScopeOverride` turns into a scope, so it decides which
  project receives the work — it is not the local project's id.
  """

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Migration

  # The payload is one project's whole graph — ~1,500 rows for a mature one —
  # and the server does the insert in a single transaction, so this waits
  # rather than retries. A second attempt would adopt what the first landed.
  @receive_timeout 300_000

  @doc """
  Reads `scope`'s local project and sends it to the cloud project named by
  `:cloud_project_id`.

  Options:

    * `:cloud_project_id` — required; the project on the server to fill.
    * `:token` — bearer token; defaults to the stored OAuth token.
    * `:base_url` — defaults to the configured server.
    * `:plug` — test seam, as elsewhere.
  """
  @spec migrate(CodeMySpec.Users.Scope.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def migrate(scope, opts \\ []) do
    with {:ok, cloud_project_id} <- fetch_cloud_project_id(opts),
         {:ok, token} <- token_for(opts) do
      payload = Migration.export_project(scope)
      send_payload(payload, cloud_project_id, token, opts)
    end
  end

  defp send_payload(payload, cloud_project_id, token, opts) do
    [
      url: base_url(opts) <> "/api/migrations",
      json: payload,
      headers: [authorization: "Bearer #{token}", "x-project-id": cloud_project_id],
      receive_timeout: @receive_timeout,
      retry: false
    ]
    |> Req.new()
    |> maybe_plug(opts)
    |> Req.post()
    |> handle_response()
  end

  defp handle_response({:ok, %{status: 200, body: %{"migrated" => summary}}}),
    do: {:ok, summary}

  # The server says what it refused and why; passing its own words through
  # beats restating them, since the person reading this is the one who has to
  # decide what to do about it.
  defp handle_response({:ok, %{status: status, body: %{"reason" => reason}}}),
    do: {:error, {:refused, status, reason}}

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, {:unexpected_response, status, body}}

  defp handle_response({:error, reason}), do: {:error, {:unreachable, reason}}

  defp fetch_cloud_project_id(opts) do
    case Keyword.get(opts, :cloud_project_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :cloud_project_id_required}
    end
  end

  defp token_for(opts) do
    case opts[:token] do
      nil -> OAuthClient.get_token()
      token -> {:ok, token}
    end
  end

  # `CMS_BASE_URL` so a build can be aimed at a different server without
  # rebuilding it — which is how this gets tested before release, and how a
  # self-hosted server would be reached.
  defp base_url(opts) do
    Keyword.get(opts, :base_url) || System.get_env("CMS_BASE_URL") ||
      Application.get_env(:code_my_spec, :base_url, "https://codemyspec.com")
  end

  defp maybe_plug(req, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end
end
