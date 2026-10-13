defmodule CodeMySpec.McpServers.Requirements.Tools.SyncProject do
  @moduledoc """
  Sync project files and components.

  Pulls remote issues into the local DB, scans the filesystem, classifies
  and validates files, creates/updates components, and backfills file
  ownership, then recomputes the requirement graph.

  The recompute is what makes "after sync, the graph is up to date" true. The
  event projection only moves rows that already exist, so a story coming back
  into the graph (made ready, or reopened after a promotion) had no
  requirements at all until something recomputed (2026-10-12, stories 1046 and
  1092 at 0/0).
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Analysis
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements

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
    environment = Validators.mcp_environment(frame)

    with {:ok, file_result} <- FileSync.sync(scope, environment: environment),
         {:ok, comp_result} <-
           FileComponentSync.sync_from_files(scope, environment: environment),
         {:ok, requirements} <- recompute(scope) do
      text = format_result(file_result, comp_result, requirements)
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
  #
  # The component half runs here too, in full: it reads the file rows the
  # server already holds, so a component main's code no longer names is pruned
  # without waiting for a manifest that changes something (14f4f837).
  defp remote_sync(scope, frame) do
    {:ok, _components} = FileComponentSync.sync_from_files(scope)

    case {recompute(scope), Analysis.request_rescan(scope)} do
      {{:error, reason}, _rescan} ->
        {:reply, Response.tool() |> Response.error("Recompute failed: #{inspect(reason)}"), frame}

      {{:ok, requirements}, :ok} ->
        text = """
        # Rescan requested

        This server holds no working copy — the disk is on the harness, so the \
        scan runs there and the manifest comes back the way every other one \
        does. A few thousand files takes a few seconds.

        Nothing is synced on return from this call. Re-check the requirement or \
        the file you are waiting on; if it still looks stale after a few \
        seconds, the harness log names what it scanned and the server log names \
        what it reconciled.

        Components were reconciled against main's code as it stands: a \
        discovered component whose module main no longer has is gone, whatever \
        another checkout still holds. A module only on a feature copy becomes a \
        component once it is promoted.

        The requirement graph was recomputed from what this server holds now: \
        #{requirements} requirements. The manifest moves them again when it lands.
        """

        {:reply, Response.tool() |> Response.text(text), frame}

      {_recomputed, {:error, {:harness_not_registered, _details}}} ->
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

      {_recomputed, {:error, reason}} ->
        {:reply, Response.tool() |> Response.error("Rescan failed: #{inspect(reason)}"), frame}
    end
  end

  defp recompute(scope) do
    case Requirements.recompute(scope) do
      {{nodes, _edges}, _actionable, _checked_at} -> {:ok, length(nodes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_result(file_result, comp_result, requirements) do
    files = file_result.total_files
    changed = length(file_result.changed_paths)
    components = length(comp_result.all_components)

    """
    # Sync Complete

    - Files: #{files} (#{changed} changed)
    - Components: #{components}
    - Requirements: #{requirements} (recomputed)

    Call `get_next_requirement` to find your next task.
    """
  end
end
