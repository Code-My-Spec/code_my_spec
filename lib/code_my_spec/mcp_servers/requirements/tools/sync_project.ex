defmodule CodeMySpec.McpServers.Requirements.Tools.SyncProject do
  @moduledoc """
  Sync project files and components.

  Scans the filesystem, classifies and validates files, creates/updates
  components, and backfills file ownership. After sync, the computed
  requirement graph is up to date.
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
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      with {:ok, file_result} <- FileSync.sync(scope, base_dir: scope.cwd),
           {:ok, comp_result} <- FileComponentSync.sync_from_files(scope, base_dir: scope.cwd) do
        files = file_result.total_files
        changed = length(file_result.changed_paths)
        components = length(comp_result.all_components)

        text = """
        # Sync Complete

        - Files: #{files} (#{changed} changed)
        - Components: #{components}

        Call `get_next_requirement` to find your next task.
        """

        response = Response.tool() |> Response.text(text)
        {:reply, response, frame}
      else
        {:error, reason} ->
          {:reply, Response.tool() |> Response.error("Sync failed: #{inspect(reason)}"), frame}
      end
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{reason}"), frame}
    end
  end
end
