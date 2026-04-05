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

    Enum.each(projects, fn project ->
      case Scope.for_local_project(project) do
        {:ok, scope} ->
          Logger.info("[BootSync] Syncing stories for #{project.name}")

          case RemoteSync.sync(scope) do
            :ok ->
              Logger.info("[BootSync] Stories synced for #{project.name}")

            {:error, reason} ->
              Logger.warning("[BootSync] Story sync failed for #{project.name}: #{inspect(reason)}")
          end

          case IssuesRemoteSync.sync(scope) do
            :ok ->
              Logger.info("[BootSync] Issues synced for #{project.name}")

            {:error, reason} ->
              Logger.warning("[BootSync] Issues sync failed for #{project.name}: #{inspect(reason)}")
          end

        {:error, _} ->
          :ok
      end
    end)
  end
end
