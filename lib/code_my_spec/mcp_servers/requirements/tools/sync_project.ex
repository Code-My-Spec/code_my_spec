defmodule CodeMySpec.McpServers.Requirements.Tools.SyncProject do
  @moduledoc """
  Sync project files and components.

  Pulls remote issues into the local DB, scans the filesystem, classifies
  and validates files, creates/updates components, and backfills file
  ownership. After sync, the computed requirement graph is up to date.
  """

  use Anubis.Server.Component, type: :tool

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

  # Nothing to scan from here. On the light harness the working copy is on the
  # harness, which watches it and pushes what it sees — so sync is continuous
  # and this tool has no files to walk. It used to try anyway and crash inside
  # FileSync, surfacing as a bare -32603 with no indication that the call was
  # simply in the wrong place.
  defp run_sync(%{cwd: nil} = _scope, frame) do
    text = """
    Nothing to sync from here — this server holds no working copy.

    The harness watches the project's files and reports what changes, so the \
    graph is already current. Write your file and re-check the requirement; \
    there is no sync step to run.
    """

    {:reply, Response.tool() |> Response.text(text), frame}
  end

  defp run_sync(scope, frame) do
    # `embed: false`. This used to carry the embed pre-pass — re-embedding the
    # framework knowledge corpus and re-projecting hex docs — on the grounds
    # that it is the manual full-sync surface and every hot-path caller opts
    # out. The intent was right; the cost was not survivable.
    #
    # Measured here: 4794 files, 54 changed, **1,700,691ms**. Twenty-eight
    # minutes, of which roughly 27 seconds was file work. The same scan without
    # embedding is 354ms. No MCP client waits twenty-eight minutes — it times
    # out, and the call meant to refresh the graph wedges the service instead.
    #
    # Embedding is now `refresh_embeddings`, asked for by name.
    with {:ok, file_result} <- FileSync.sync(scope, base_dir: scope.cwd, embed: false),
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

    Embeddings are not refreshed here — call `refresh_embeddings` if \
    `semantic_search` needs to see today's code.
    """
  end
end
