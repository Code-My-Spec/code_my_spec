defmodule CodeMySpecLocalWeb.SocketSupervisor do
  @moduledoc """
  Supervises long-lived Slipstream WebSocket connections to the server.

  On start, finds all unique accounts from local projects and starts
  one set of real-time sync sockets per account.
  """

  use Supervisor

  require Logger

  alias CodeMySpec.AgentHarness.HarnessProxySocket
  alias CodeMySpec.Issues.IssuesSocket
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.ProjectsSocket
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias Ecto.Adapters.SQL

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      if wait_for_repo(10) == :ok do
        build_children()
      else
        Logger.warning("[SocketSupervisor] Repo not ready — starting with no account sockets")
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp wait_for_repo(0), do: :timeout

  defp wait_for_repo(attempts) do
    case SQL.query(Repo, "SELECT 1", [], timeout: 5_000) do
      {:ok, _} ->
        :ok

      _ ->
        Process.sleep(500)
        wait_for_repo(attempts - 1)
    end
  end

  defp build_children do
    accounts_to_serve()
    |> Enum.flat_map(&children_for_account/1)
  end

  # A desktop install serves every account it has a local project for. A sprite
  # serves exactly one — the project it was provisioned for.
  #
  # Unscoped, this was the file-watcher bug again: "every account with a local
  # project" is a safe definition of "mine" only while the database is
  # per-machine. On centralized data a sprite started three sockets for each of
  # five accounts it had nothing to do with, and all fifteen failed auth and
  # retried forever.
  defp accounts_to_serve do
    case Application.get_env(:code_my_spec, :project_id) do
      nil ->
        Projects.list_local_account_ids()

      project_id ->
        case Projects.resolve_local_project(nil) do
          {:ok, %{account_id: account_id}} when not is_nil(account_id) ->
            [account_id]

          _ ->
            Logger.warning("[SocketSupervisor] no account for project #{project_id}")
            []
        end
    end
  end

  defp children_for_account(account_id) do
    project = Projects.first_local_project_for_account(account_id)

    case Scope.for_local_project(project) do
      {:ok, scope} ->
        # ProjectsSocket and IssuesSocket exist to replicate the server's rows
        # into a local database. A sprite reads and writes the server's rows
        # directly, so there is nothing to replicate — starting them buys a
        # reconnect loop and nothing else.
        #
        # HarnessProxySocket stays: it carries agent messages up to the operator
        # inbox and human replies back down, which is not replication and has no
        # substitute.
        replication =
          if sprite?() do
            []
          else
            [
              Supervisor.child_spec({ProjectsSocket, scope: scope}, id: {ProjectsSocket, account_id}),
              Supervisor.child_spec({IssuesSocket, scope: scope}, id: {IssuesSocket, account_id})
            ]
          end

        replication ++
          [
            Supervisor.child_spec({HarnessProxySocket, scope: scope},
              id: {HarnessProxySocket, account_id}
            )
          ]

      {:error, _} ->
        Logger.warning("[SocketSupervisor] Cannot build scope for account #{account_id}")
        []
    end
  end
  defp sprite?, do: not is_nil(Application.get_env(:code_my_spec, :project_id))
end
