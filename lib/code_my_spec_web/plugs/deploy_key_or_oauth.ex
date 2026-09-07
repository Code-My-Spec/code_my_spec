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
  alias CodeMySpec.WorkingCopies
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
      |> assign(:current_scope, scope_for(user, project) |> with_harness(conn))
      |> assign(:deploy_key_project_id, project.id)
    else
      # Not a deploy key — could still be a perfectly good OAuth token, which
      # is how the desktop CLI reaches these same routes.
      #
      # And how the *harness* reaches them: it trades its deploy key for a
      # short-lived access token and sends that, so this is the branch it
      # actually takes. Putting the harness lookup only in the branch above
      # left it dead for the one caller it was written for.
      _ -> conn |> UserAuth.require_oauth_token(opts) |> adopt_harness()
    end
  end

  defp adopt_harness(%Plug.Conn{halted: true} = conn), do: conn

  defp adopt_harness(conn) do
    case conn.assigns[:current_scope] do
      %{active_project_id: id} = scope when not is_nil(id) ->
        assign(conn, :current_scope, with_harness(scope, conn))

      _ ->
        conn
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

  # Which working copy is calling. The harness proxy already addresses itself as
  # `/mcp?harness=<id>` for exactly this reason; the scope just never picked it
  # up, so every read ran unscoped.
  #
  # That matters because `scope_to_harness/2` treats a nil harness as "no
  # filter" rather than "no results" — reasonable for the project-wide views it
  # was written for, and wrong here. `await_analysis` reported 1138 credo
  # problems to an agent whose own checkout had 552; the rest belonged to a
  # different worktree it cannot see and could not fix.
  defp with_harness(scope, conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case WorkingCopies.fetch(working_copy_id(conn)) do
      {:ok, harness} when harness.project_id == scope.active_project_id ->
        %{scope | active_working_copy_id: harness.id}

      # No harness named, or one belonging to another project. Left unscoped
      # rather than guessed: adopting the wrong checkout's identity is worse
      # than reading widely, and `WorkingCopies.issue/3` on the channel is where an
      # id is minted, not here.
      _ ->
        scope
    end
  end

  # The header is how it actually arrives. The harness proxy resolves
  # `/mcp?harness=<id>` on its own port and forwards to `/mcp/harness`, so the
  # query param never reaches here — reading only that made the first version
  # of this inert, and its test passed because the test supplied the param that
  # production does not.
  defp working_copy_id(conn) do
    List.first(get_req_header(conn, "x-harness-id")) || conn.query_params["harness"] || ""
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
