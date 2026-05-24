defmodule CodeMySpec.McpServers.Requirements.Tools.SyncProject do
  @moduledoc """
  Sync project files and components.

  Pulls remote issues into the local DB, scans the filesystem, classifies
  and validates files, creates/updates components, and backfills file
  ownership. After sync, the computed requirement graph is up to date.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> run_sync(scope, frame)
      {:error, reason} -> {:reply, Response.tool() |> Response.error("#{reason}"), frame}
    end
  end

  defp run_sync(scope, frame) do
    with {:ok, file_result} <- FileSync.sync(scope, base_dir: scope.cwd),
         {:ok, comp_result} <- FileComponentSync.sync_from_files(scope, base_dir: scope.cwd) do
      text = format_result(file_result, comp_result)
      {:reply, Response.tool() |> Response.text(text), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("Sync failed: #{inspect(reason)}"), frame}
    end
  end

  defp format_result(file_result, comp_result) do
    files = file_result.total_files
    changed = length(file_result.changed_paths)
    components = length(comp_result.all_components)

    """
    # Sync Complete

    - Files: #{files} (#{changed} changed)
    - Components: #{components}

    Call `get_next_requirement` to find your next task.
    """
  end
end
