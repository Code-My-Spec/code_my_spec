defmodule CodeMySpec.Validation do
  @moduledoc """
  What a stop does before deciding: sync the files the turn changed and run the
  in-process validators, which record Problems. A stop never starts, ingests or
  waits on a subprocess analyzer, and never blocks on Problems: they gate at
  promotion (John, 2026-10-18). Which findings block there is
  `Validation.Blocking`'s answer.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Analysis,
      CodeMySpec.Configurations,
      CodeMySpec.FileEdits,
      CodeMySpec.Files,
      CodeMySpec.StaticAnalysis,
      CodeMySpec.Users.Scope
    ]

  require Logger

  alias CodeMySpec.Analysis
  alias CodeMySpec.Configurations
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.Users.Scope

  # Analyzer atoms that execute as mix subprocesses → their Analysis source.
  # A stop runs only the rest (the in-process validators).
  @subprocess_analyzers %{credo: "credo", exunit_stale: "exunit", spex_stale: "spex"}

  @doc """
  Run the full validation pipeline for a stop hook.

  Returns `{:ok, %{changed_files:, analysis:}}`. It never blocks.

  ## Options

  - `:session_id` - external session id; when present, the changed-file
    set is intersected with PostToolUse-attributed edits for this
    `(session_id, agent_id)`.
  - `:agent_id` - sub-agent id; nil means the main agent. Combined with
    `:session_id` for the FileEdits attribution lookup.

  A stop never starts, ingests or waits on analysis; it reads what runs already
  persisted. A spec that needs findings lands them as an analysis run first, and
  only then stops.
  """
  @spec validate_stop(Scope.t(), map() | nil, keyword()) ::
          {:ok, %{changed_files: [map()], analysis: map()}}
  def validate_stop(%Scope{} = scope, task, opts \\ []) do
    start = System.monotonic_time(:millisecond)

    result = do_validate_stop(scope, task, opts)

    elapsed = System.monotonic_time(:millisecond) - start
    Logger.info("[Validation] validate_stop completed in #{elapsed}ms")

    result
  end

  # No project bound yet — a stop hook firing before `init_project`. There is
  # nothing to check and nothing to check it against.
  defp do_validate_stop(%Scope{active_project_id: nil}, _task, _opts) do
    {:ok, %{changed_files: [], analysis: %{enqueued: [], memoized: []}}}
  end

  # No working copy on this machine: ask the harness that holds this project.
  # Only when none does is there nothing to check against.
  defp do_validate_stop(%Scope{cwd: nil} = scope, task, opts) do
    case Analysis.remote_executor(scope) do
      {:ok, _harness} ->
        remote_validate_stop(scope, task, opts)

      :none ->
        {:ok, %{changed_files: [], analysis: %{enqueued: [], memoized: []}}}
    end
  end

  defp do_validate_stop(%Scope{cwd: cwd} = scope, task, opts) do
    case FileSync.sync_changed(scope, base_dir: cwd) do
      {:ok, sync_result} -> local_validate_stop(scope, task, opts, cwd, sync_result)
      {:error, {:cannot_scan, _}} -> do_validate_stop(%{scope | cwd: nil}, task, opts)
    end
  end

  # `cwd` is set for any resolved scope, including on the server where no local
  # environment can scan the checkout. A sync that cannot scan falls back to the
  # `cwd: nil` path rather than answering from a walk that never happened.
  defp local_validate_stop(%Scope{} = scope, task, opts, cwd, sync_result) do
    FileComponentSync.sync_from_files(scope,
      base_dir: cwd,
      changed_paths: sync_result.changed_paths,
      removed_module_names: sync_result.removed_module_names
    )

    # An agent with no session names its own changed set. The scan's dirty list
    # cannot stand in for it: by turn end the file just written has usually been
    # synced already and is no longer dirty.
    all_changed =
      case agent_changed_files(scope, opts) do
        [] -> resolve_changed_files(scope, task, sync_result)
        edited -> edited
      end

    changed_files = filter_by_session_attribution(all_changed, scope, cwd, task, opts)

    config = Configurations.get_or_create(scope)

    analysis = run_pipeline(scope, task, changed_files, config, opts)

    {:ok, %{changed_files: changed_files, analysis: analysis}}
  end

  # The same pipeline minus the two steps that need a disk here: the harness has
  # already reconciled its manifest (so File rows are current), and in-process
  # validators read file contents, which never cross the wire. The decision is
  # identical; only where the files were read differs.
  defp remote_validate_stop(scope, task, opts) do
    {changed_files, consume_ledger} = remote_changed_files(scope, task, opts)
    config = Configurations.get_or_create(scope)

    analysis = run_pipeline(scope, task, changed_files, config, opts)

    consume_ledger.()
    {:ok, %{changed_files: changed_files, analysis: analysis}}
  end

  # With a task: every File row whose mtime (off the harness's manifest) moved
  # since the task started, narrowed by attribution — mtime cannot tell an agent's
  # write from a rebase. `cwd` is nil here by construction; the harness sends
  # edit paths project-relative, so `relativize/2` passes them through.
  #
  # No cleanup thunk: `changed_files_for_task/3` intersects the ledger with the
  # task window, and consuming rows would starve it for the rest of the task.
  defp remote_changed_files(scope, %{started_at: started_at} = task, opts)
       when not is_nil(started_at) do
    {changed_files_for_task(scope, task, opts), fn -> :ok end}
  end

  # Without a task: what this session wrote, as PostToolUse recorded it. Empty
  # means a quiet stop. The second element consumes the returned paths once they
  # have been used, so the next stop with nothing new sees an empty ledger
  # instead of this one's leftovers. See knowledge/analysis, "Changed files and attribution".
  defp remote_changed_files(scope, _task, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        agent_id = Keyword.get(opts, :agent_id)
        paths = attributed_paths(session_id, agent_id)
        files = Files.get_by_paths(scope, paths)
        {files, fn -> consume_attributed_paths(session_id, agent_id, paths) end}

      _ ->
        {agent_changed_files(scope, opts), fn -> :ok end}
    end
  end

  defp consume_attributed_paths(session_id, nil, paths),
    do: FileEdits.consume_edits(session_id, paths)

  defp consume_attributed_paths(session_id, agent_id, paths) when is_binary(agent_id),
    do: FileEdits.consume_edits_by_agent(session_id, agent_id, paths)

  @doc false
  def remote_changed_files_for_test(scope, task, opts),
    do: remote_changed_files(scope, task, opts)

  # The same answer for an agent with no session: the files it touched, as
  # `FileEdits.track_agent_edit/2` records them.
  #
  # No cleanup thunk: `get_edited_files_for_agent/1` is never consumed, so a
  # continuous in-BEAM agent could accumulate a stale ledger the way sessions did.
  # Unmeasured.
  defp agent_changed_files(scope, opts) do
    case Keyword.get(opts, :agent_id) do
      agent_id when is_binary(agent_id) ->
        agent_id
        |> FileEdits.get_edited_files_for_agent()
        |> then(&Files.get_by_paths(scope, &1))

      _ ->
        []
    end
  end

  @doc """
  Public only so the property that matters can be asserted directly: mtime
  moves, git state does not, and the blocking set follows what the session
  recorded rather than the clock. Same reasoning as `blocking_key/1`.
  """
  def changed_files_for_task(scope, %{started_at: started_at} = task, opts) do
    scope
    |> Files.changed_since(started_at)
    |> filter_by_session_attribution(scope, nil, task, opts)
  end

  # When a session is in play, narrow the changed-file set to files this
  # session+agent actually wrote (via PostToolUse); otherwise a parallel
  # session's writes leak into this stop. No session → no filter.
  defp filter_by_session_attribution(files, _scope, cwd, task, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        # PostToolUse stores whatever Claude passed, typically absolute;
        # `Files.path` is project-relative.
        attributed =
          session_id
          |> attributed_paths(Keyword.get(opts, :agent_id))
          |> Enum.map(&relativize(&1, cwd))
          |> MapSet.new()

        narrow_to_attributed(files, attributed, session_id, opts, task_started_at(task))

      _ ->
        files
    end
  end

  defp task_started_at(%{started_at: %DateTime{} = started_at}), do: started_at
  defp task_started_at(_task), do: nil

  # How many mtime-dirty files with zero attribution stop looking like a turn
  # and start looking like a rebase. Deliberately generous: over it the set is
  # discarded, and discarding a real turn's work is the expensive mistake.
  @rebase_sized 25

  # A session that recorded no edits wrote nothing; fail closed to an empty set
  # rather than blocking on every mtime-dirty file. Under `@rebase_sized` the
  # dirty set is kept unless `git_rewrite_at` (stamped by PostToolUse on a Bash
  # command able to move HEAD) is at or after the task start.
  # See knowledge/analysis, "Changed files and attribution".
  defp narrow_to_attributed(files, attributed, session_id, opts, started_at) do
    case {MapSet.size(attributed), length(files)} do
      {0, dirty} when dirty > @rebase_sized ->
        Logger.warning(
          "[Validation] session #{session_id} recorded no edits, but #{dirty} file(s) " <>
            "look changed — more than a turn writes. Treating the turn as having " <>
            "written nothing rather than blocking on all of them; if the agent did " <>
            "edit files, PostToolUse attribution is not reaching this project's " <>
            "File paths."
        )

        []

      {0, _dirty} ->
        if git_rewrote_tree?(opts, started_at) do
          Logger.warning(
            "[Validation] session #{session_id} recorded no edits, and ran a git " <>
              "command that can move HEAD since this task started — treating the " <>
              "dirty file(s) as inherited history rather than this turn's work."
          )

          []
        else
          files
        end

      _ ->
        Enum.filter(files, &MapSet.member?(attributed, &1.path))
    end
  end

  # `:git_rewrite_at` arrives in the options: the caller (the stop hook) knows
  # the agent and reads it; this module sits below agents.
  defp git_rewrote_tree?(opts, started_at) do
    case Keyword.get(opts, :git_rewrite_at) do
      %DateTime{} = rewrote_at ->
        is_nil(started_at) or DateTime.compare(rewrote_at, started_at) != :lt

      _ ->
        false
    end
  end

  defp relativize(path, cwd) when is_binary(path) and is_binary(cwd) do
    cond do
      Path.type(path) == :relative -> path
      String.starts_with?(path, cwd <> "/") -> Path.relative_to(path, cwd)
      true -> Path.relative_to(path, cwd)
    end
  end

  defp relativize(path, _cwd), do: path

  defp attributed_paths(session_id, nil), do: FileEdits.get_edited_files(session_id)

  defp attributed_paths(session_id, agent_id) when is_binary(agent_id),
    do: FileEdits.get_edited_files_by_agent(session_id, agent_id)

  # A stop never starts, ingests or waits on an analyzer
  # (`.code_my_spec/rules/analysis_is_explicit.md`): runs come from
  # `start_analysis`, ready_for_qa certification and promotion. Only the
  # in-process validators run here.
  @nothing_enqueued %{enqueued: [], memoized: []}

  defp run_pipeline(scope, task, changed_files, config, opts) do
    if changed_files != [] do
      log_changed_files(changed_files)

      in_process =
        task
        |> StaticAnalysis.resolve_analyzers(changed_files, config)
        |> Enum.reject(&Map.has_key?(@subprocess_analyzers, &1))

      StaticAnalysis.run_analyzers(scope, in_process, changed_files, config, opts)
    end

    @nothing_enqueued
  end

  defp resolve_changed_files(scope, %{started_at: started_at}, _sync_result)
       when not is_nil(started_at) do
    Files.changed_since(scope, started_at)
  end

  defp resolve_changed_files(scope, _task, sync_result) do
    case sync_result.changed_paths do
      [] -> []
      paths -> Files.get_by_paths(scope, paths)
    end
  end

  defp log_changed_files(changed_files) do
    summary =
      changed_files
      |> Enum.group_by(& &1.role)
      |> Enum.map_join(", ", fn {role, files} -> "#{role}(#{length(files)})" end)

    Logger.info("[Validation] Changed files: #{summary}")
  end
end
