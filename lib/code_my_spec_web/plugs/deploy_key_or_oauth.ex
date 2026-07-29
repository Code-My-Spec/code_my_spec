defmodule CodeMySpecWeb.Plugs.DeployKeyOrOAuth do
  @moduledoc """
  Authenticates a bearer token that may be either a user's OAuth access token
  or a project's deploy key.

  A sprite has no user. It is provisioned for one project and handed that
  project's deploy key, which is the only credential it holds — there is no
  browser to run an OAuth flow in and no person sitting at it to run one.

  That matters for exactly one thing: reaching the human. Everything else a
  sprite does it does against the database directly. But a manual requirement —
  persona research, Three Amigos, release — is *defined* by needing a person,
  and `ask_user` is how the agent gets one. Without a credential the tool
  answers "ask in the terminal instead", and an unattended sprite has no
  terminal.

  So the deploy key resolves to the project's account owner: the question is
  raised as though that person asked to be interrupted, because on their
  project it is their decision to make.

  Deliberately narrow. This plug is mounted on the question routes only, not
  across the API. A deploy key should be able to interrupt its owner; it should
  not inherit the rest of what that owner can do.
  """

  import Plug.Conn

  alias CodeMySpec.Accounts
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope
  alias CodeMySpecWeb.UserAuth

  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, project} <- project_for_deploy_key(token),
         {:ok, user} <- account_owner(project.account_id) do
      conn
      |> assign(:current_scope, scope_for(user, project))
      |> assign(:deploy_key_project_id, project.id)
    else
      # Not a deploy key — could still be a perfectly good OAuth token, which
      # is how the desktop CLI reaches these same routes.
      _ -> UserAuth.require_oauth_token(conn, opts)
    end
  end

  defp project_for_deploy_key(token) do
    case Projects.get_project_by_deploy_key(token) do
      nil -> :error
      project -> {:ok, project}
    end
  end

  # The owner rather than any member: a question is an interruption, and
  # interrupting the wrong person is worse than not asking.
  defp account_owner(account_id) do
    case Accounts.get_account_owner(account_id) do
      nil ->
        Logger.warning("[DeployKeyOrOAuth] no owner for account #{account_id}")
        :error

      user ->
        {:ok, user}
    end
  end

  defp scope_for(user, project) do
    user
    |> Scope.for_user()
    |> Map.merge(%{
      active_account_id: project.account_id,
      active_project: project,
      active_project_id: project.id
    })
  end
end
