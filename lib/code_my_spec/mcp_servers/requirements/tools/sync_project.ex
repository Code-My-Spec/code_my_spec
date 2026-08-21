defmodule CodeMySpec.McpServers.Requirements.Tools.SyncProject do
  @moduledoc """
  Sync project files and components.

  Pulls remote issues into the local DB, scans the filesystem, classifies
  and validates files, creates/updates components, and backfills file
  ownership. After sync, the computed requirement graph is up to date.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Analysis
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

  # No working copy on this machine. The disk is on a harness, so the scan
  # happens there — see `remote_sync/2`.
  defp run_sync(%{cwd: nil} = scope, frame), do: remote_sync(scope, frame)

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
      # `cwd` is set for any resolved scope and is not the claim "there is a
      # working copy here" — the light harness has one and holds no checkout. So
      # the clause above cannot catch every remote case, and this is where the
      # rest arrive: the scan reached `Environments.Harness.stream_files/3`,
      # which refuses on purpose.
      #
      # It surfaced as `Sync failed: {:cannot_scan, :not_supported_on_harness}`,
      # which reads as a broken tool. `Validation.do_validate_stop/3` already
      # answers this exact tuple by re-asking as though there were no cwd; this
      # does the same.
      {:error, {:cannot_scan, _reason}} ->
        remote_sync(scope, frame)

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("Sync failed: #{inspect(reason)}"), frame}
    end
  end

  # The working copy is on a harness. Ask it to scan.
  #
  # This used to say "the graph is already current, there is no sync step to
  # run", which is true right up until it is not: the harness watches the
  # working copy, but watching stops while it is disconnected — it logs "File
  # changes are not being recorded" — and only a reconnect triggers a fresh full
  # scan. An agent with reason to think the graph was stale was told there was
  # nothing to do about it (b10c4b46).
  #
  # Asynchronous, and says so rather than implying the graph is current on
  # return. The scan runs where the disk is, the manifest comes back on the
  # ordinary `observations` path, and the server reconciles it — seconds for a
  # few thousand files. Same shape as `run_analysis`, which is the other thing
  # the server asks a harness to do.
  defp remote_sync(scope, frame) do
    case Analysis.request_rescan(scope) do
      :ok ->
        text = """
        # Rescan requested

        This server holds no working copy — the disk is on the harness, so the \
        scan runs there and the manifest comes back the way every other one \
        does. A few thousand files takes a few seconds.

        Nothing is synced on return from this call. Re-check the requirement or \
        the file you are waiting on; if it still looks stale after a few \
        seconds, the harness log names what it scanned and the server log names \
        what it reconciled.
        """

        {:reply, Response.tool() |> Response.text(text), frame}

      {:error, {:harness_not_registered, _details}} ->
        text = """
        Nothing to sync from here — this server holds no working copy, and no \
        harness is currently registered for this project to ask.

        A harness that has not joined the channel since this server started \
        cannot be addressed, even though its own `/health` will say connected — \
        that is about its socket, not about whether the server can reach it. \
        Restarting the harness rejoins, and a join scans the whole working copy \
        anyway.
        """

        {:reply, Response.tool() |> Response.text(text), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("Rescan failed: #{inspect(reason)}"), frame}
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
