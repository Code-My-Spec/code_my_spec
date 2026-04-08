defmodule CodeMySpecLocalWeb.SocketSupervisor do
  @moduledoc """
  Supervises long-lived Slipstream WebSocket connections to the server.

  On start, finds all unique accounts from local projects and starts
  one set of real-time sync sockets per account.
  """

  use Supervisor

  require Logger

  import Ecto.Query

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Projects.ProjectsSocket
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = build_children()
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children do
    Project
    |> where([p], not is_nil(p.local_path))
    |> select([p], p.account_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.flat_map(&children_for_account/1)
  end

  defp children_for_account(account_id) do
    # Use any project in this account to build the scope
    project =
      Project
      |> where([p], p.account_id == ^account_id and not is_nil(p.local_path))
      |> limit(1)
      |> Repo.one()

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
