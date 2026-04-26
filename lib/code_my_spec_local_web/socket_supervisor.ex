defmodule CodeMySpecLocalWeb.SocketSupervisor do
  @moduledoc """
  Supervises long-lived Slipstream WebSocket connections to the server.

  On start, finds all unique accounts from local projects and starts
  one set of real-time sync sockets per account.
  """

  use Supervisor

  require Logger

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
    Projects.list_local_account_ids()
    |> Enum.flat_map(&children_for_account/1)
  end

  defp children_for_account(account_id) do
    project = Projects.first_local_project_for_account(account_id)

    case Scope.for_local_project(project) do
      {:ok, scope} ->
        [
          Supervisor.child_spec({ProjectsSocket, scope: scope}, id: {ProjectsSocket, account_id})
        ]

      {:error, _} ->
        Logger.warning("[SocketSupervisor] Cannot build scope for account #{account_id}")
        []
    end
  end
end
