defmodule CodeMySpec.McpServers.Requirements.Tools.SyncProject do
  @moduledoc """
  Sync project files and components.

  Pulls remote stories / issues / personas into the local DB, scans the
  filesystem, classifies and validates files, creates/updates components, and
  backfills file ownership. After sync, the computed requirement graph is up
  to date.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.BddRules.RemoteSync, as: BddRulesRemoteSync
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Issues.RemoteSync, as: IssuesRemoteSync
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Personas.RemoteSync, as: PersonasRemoteSync
  alias CodeMySpec.Stories.RemoteSync, as: StoriesRemoteSync

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
    remote_lines = run_remote_syncs(scope)

    with {:ok, file_result} <- FileSync.sync(scope, base_dir: scope.cwd),
         {:ok, comp_result} <- FileComponentSync.sync_from_files(scope, base_dir: scope.cwd) do
      text = format_result(remote_lines, file_result, comp_result)
      {:reply, Response.tool() |> Response.text(text), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("Sync failed: #{inspect(reason)}"), frame}
    end
  end

  defp format_result(remote_lines, file_result, comp_result) do
    files = file_result.total_files
    changed = length(file_result.changed_paths)
    components = length(comp_result.all_components)

    """
    # Sync Complete

    #{remote_lines}
    - Files: #{files} (#{changed} changed)
    - Components: #{components}

    Call `get_next_requirement` to find your next task.
    """
  end

  defp run_remote_syncs(scope) do
    if OAuthClient.authenticated?() do
      [
        safe_sync("Stories", fn -> StoriesRemoteSync.sync(scope) end),
        safe_sync("Issues", fn -> IssuesRemoteSync.sync(scope) end),
        safe_sync("Personas", fn -> PersonasRemoteSync.sync(scope) end),
        safe_sync("BddRules", fn -> BddRulesRemoteSync.sync(scope) end)
      ]
      |> Enum.join("\n")
    else
      "- Remote sync: skipped (not authenticated)"
    end
  end

  defp safe_sync(label, fun) do
    case fun.() do
      :ok -> "- #{label}: synced from remote"
      {:ok, _} -> "- #{label}: synced from remote"
      {:error, reason} -> "- #{label}: sync failed (#{inspect(reason)})"
    end
  end
end
