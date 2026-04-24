defmodule CodeMySpec.Stories.BootSync do
  @moduledoc """
  Syncs stories from the remote API on application boot.

  Runs as a Task under the supervision tree — non-blocking,
  fire-and-forget. If the remote API is unavailable, logs a
  warning and continues.
  """

  use Task, restart: :temporary

  require Logger

  import Ecto.Query

  alias CodeMySpec.Issues.RemoteSync, as: IssuesRemoteSync
  alias CodeMySpec.Personas.RemoteSync, as: PersonasRemoteSync
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.RemoteSync
  alias CodeMySpec.Users.Scope

  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  def run do
    projects =
      Project
      |> where([p], not is_nil(p.local_path))
      |> Repo.all()

    Enum.each(projects, &sync_project/1)
  end

  defp sync_project(project) do
    case Scope.for_local_project(project) do
      {:ok, scope} -> sync_with_scope(project, scope)
      {:error, _} -> :ok
    end
  end

  defp sync_with_scope(project, scope) do
    Logger.info("[BootSync] Syncing stories for #{project.name}")
    RemoteSync.sync(scope)
    Logger.info("[BootSync] Stories synced for #{project.name}")

    log_sync_result("Issues", project.name, IssuesRemoteSync.sync(scope))
    log_sync_result("Personas", project.name, PersonasRemoteSync.sync(scope))
  end

  defp log_sync_result(label, project_name, :ok) do
    Logger.info("[BootSync] #{label} synced for #{project_name}")
  end

  defp log_sync_result(label, project_name, {:ok, _}) do
    Logger.info("[BootSync] #{label} synced for #{project_name}")
  end

  defp log_sync_result(label, project_name, {:error, reason}) do
    Logger.warning("[BootSync] #{label} sync failed for #{project_name}: #{inspect(reason)}")
  end
end
