defmodule CodeMySpec.Analysis.Reconciler do
  @moduledoc """
  Persists a finished analyzer run — the single write path for run results.

  Replaces a full run's Problems for its source in one transaction, stamps
  `component_id` from Files, marks the run finished, prunes old ledger rows,
  and emits `[:code_my_spec, :analysis, :run_reconciled]` (re-evaluating tasks
  and the phone push answer it) and, when warranted, `:run_reported` (the
  report to agents).

  Runs inside the analysis Task, never a GenServer callback or an HTTP
  request, so an aborted hook request cannot strand a half-written reconcile.
  """

  require Logger

  alias CodeMySpec.Analysis.{
    Run,
    RunsRepository,
    Signatures
  }

  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Users.Scope

  @doc """
  Persist a successful runner result for `run`.

  Returns `{:ok, run}` with the finished Run row.
  """
  @spec reconcile(Scope.t(), Run.t(), map(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def reconcile(scope, run, result, opts \\ [])

  # A partial run covers only the files it names, so it finishes with output
  # and stats and leaves Problems alone; the wholesale replace below would
  # delete everything it never looked at. `latest_full_run/2` ignores it.
  # Its asker is still answered: team 4's QA waited on targeted runs 59901 and
  # 59902, both clean, that told nobody (2026-10-15).
  def reconcile(%Scope{} = scope, %Run{kind: :partial} = run, result, _opts) do
    Logger.info(
      "[Analysis] run #{run.id} (#{run.source}) targeted run — output only, Problems untouched"
    )

    with {:ok, finished} <-
           RunsRepository.finish_run(run, :completed, %{
             output: result.output,
             exit_status: result.exit_status,
             stats: result.stats
           }) do
      report_tied(scope, run, result)
      {:ok, finished}
    end
  end

  def reconcile(%Scope{} = scope, %Run{} = run, result, opts) do
    problems =
      result.problems
      |> Enum.map(&(&1 |> stamp_project(scope) |> patch_file_path()))
      |> stamp_component_ids(scope, run.source)

    file_scope = clear_scope(scope, run)

    case Problems.reconcile_problems_for_source(scope, run.source, file_scope, problems) do
      {:ok, _inserted} ->
        # Read before finishing: this run is still `:running`, so
        # `latest_completed_run/2` returns the sweep before it. After
        # `finish_run` it would return this one and the delta would be empty.
        previous = RunsRepository.latest_completed_run(scope, run.source)
        signatures = Signatures.of(problems)

        {:ok, finished} =
          RunsRepository.finish_run(run, :completed, %{
            output: result.output,
            exit_status: result.exit_status,
            stats: Signatures.put(result.stats, signatures)
          })

        RunsRepository.prune(scope, run.source)
        # Events, because Analysis sits below `AgentTasks` and `Notifications`.
        :telemetry.execute(
          [:code_my_spec, :analysis, :run_reconciled],
          %{},
          %{
            scope: scope,
            source: finished.source,
            problems: problems,
            notify: Keyword.get(opts, :notify, false)
          }
        )

        # The push to agents in this BEAM. A Claude Code session is not told
        # here; it picks the alert up on its next tool call.
        announce_if_new(scope, run, problems, previous, signatures)

        Logger.info(
          "[Analysis] run #{run.id} (#{run.source}) reconciled: #{length(problems)} problem(s) " <>
            "(#{run.kind})" <>
            Signatures.delta_suffix(previous, signatures) <>
            requested_by_suffix(run)
        )

        {:ok, finished}

      {:error, reason} ->
        Logger.error(
          "[Analysis] run #{run.id} (#{run.source}) reconcile failed: #{inspect(reason)}"
        )

        finish_failed(run, inspect(reason), %{})
        {:error, reason}
    end
  end

  @doc """
  Finish a run whose analyzer output was already reconciled under a
  different run_id.

  The harness ties a request for a busy source onto the one already queued,
  and every tied run_id gets the primary's result. The primary's `reconcile/4`
  already wrote the Problems; writing again would double every row. This
  closes the tied run's ledger entry and answers whoever asked for it.
  """
  @spec finish_tied(Scope.t(), Run.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def finish_tied(%Scope{} = scope, %Run{} = run, result) do
    Logger.info(
      "[Analysis] run #{run.id} (#{run.source}) tied — output only, Problems untouched" <>
        requested_by_suffix(run)
    )

    with {:ok, finished} <-
           RunsRepository.finish_run(run, :completed, %{
             output: result.output,
             exit_status: result.exit_status,
             stats: result.stats
           }) do
      report_tied(scope, run, result)
      {:ok, finished}
    end
  end

  # The agent that asked for a tied or partial run waits on its own run's answer. The
  # primary's report goes only to the primary's askers, so a tied requester
  # heard nothing and waited on a finished run: team 2's coder sat 40 minutes
  # on run 59471, which had completed clean (2026-10-15).
  defp report_tied(scope, run, result) do
    requester = requesting_agent_id(run)
    waiters = waiters(run)

    if requester || waiters != [] do
      problems =
        result
        |> Map.get(:problems, [])
        |> Enum.map(&(&1 |> stamp_project(scope) |> patch_file_path()))
        |> stamp_component_ids(scope, run.source)

      :telemetry.execute(
        [:code_my_spec, :analysis, :run_reported],
        %{},
        %{
          scope: scope,
          source: run.source,
          problems: problems,
          requester: requester,
          waiters: waiters
        }
      )
    end

    :ok
  end

  @doc "Mark a run failed (tool crash, skip, or task death) — no problem changes."
  @spec fail(Run.t(), term(), map()) :: {:ok, Run.t()} | {:error, term()}
  def fail(%Run{} = run, reason, kept \\ %{}) do
    Logger.warning(
      "[Analysis] run #{run.id} (#{run.source}) failed: #{inspect(reason)}" <>
        requested_by_suffix(run)
    )

    finish_failed(run, reason, kept)
  end

  # `kept` is what the analyzer said — its output and exit status — kept on the
  # failed run so the reason can be read past its one-line excerpt.
  defp failure_stats(:skipped_compile_errors = reason),
    do: %{"error" => error_text(reason), "execution_terminal" => true}

  defp failure_stats(reason), do: %{"error" => error_text(reason)}

  defp finish_failed(run, reason, kept) do
    attrs =
      Map.merge(Map.take(kept, [:output, :exit_status]), %{
        stats: failure_stats(reason)
      })

    with {:ok, failed} <- RunsRepository.finish_run(run, :failed, attrs) do
      announce_failed(failed, reason)
      {:ok, failed}
    end
  end

  @doc """
  Tell the agents that requested or wait on a failed run that it failed, and
  why.

  Every path that marks a run `:failed` ends here — `fail/3`, and
  `Analysis.resume_orphaned/2` for a run stranded by a disconnect or restart.
  A requested run always answers; a run nobody requested fails silently.
  """
  @spec announce_failed(Run.t(), term()) :: :ok
  def announce_failed(%Run{} = run, reason) do
    case {requesting_agent_id(run), waiters(run)} do
      {nil, []} ->
        :ok

      {requester, waiters} ->
        :telemetry.execute(
          [:code_my_spec, :analysis, :run_reported],
          %{},
          %{
            scope: %Scope{
              active_project_id: run.project_id,
              active_working_copy_id: run.working_copy_id
            },
            source: run.source,
            problems: [],
            requester: requester,
            waiters: waiters,
            failure: error_text(reason)
          }
        )
    end
  end

  # A string reason is stored as itself (agents read it in the stop response,
  # so no quoting or escaped newlines); anything else is inspected.
  defp error_text(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp error_text(reason), do: String.slice(inspect(reason), 0, 500)

  # Reports only when this run found something the last one did not, or when
  # an agent requested or waits on it. See knowledge/analysis, "Reporting runs".
  defp announce_if_new(scope, run, problems, previous, signatures) do
    requester = requesting_agent_id(run)
    waiters = waiters(run)

    if requester || waiters != [] || new_findings?(previous, signatures) do
      # An event because Analysis does not depend on Agents; handled
      # synchronously in this process.
      :telemetry.execute(
        [:code_my_spec, :analysis, :run_reported],
        %{},
        %{
          scope: scope,
          source: run.source,
          problems: problems,
          requester: requester,
          waiters: waiters
        }
      )
    else
      :ok
    end
  end

  # Threaded through so `AnalysisReport.deliver/4` answers the asker even on
  # a clean run, which everyone else is not told about.
  defp requesting_agent_id(%{requested_by: %{"agent_id" => id}}) when is_binary(id), do: id
  defp requesting_agent_id(_run), do: nil

  # Agents waiting on a run somebody else started (e.g. a promotion that found
  # one already running at its commit). Answered as the requester is.
  defp waiters(%{requested_by: %{"waiters" => waiters}}) when is_list(waiters),
    do: Enum.filter(waiters, &is_binary/1)

  defp waiters(_run), do: []

  defp new_findings?(previous, signatures) do
    Signatures.delta(previous, signatures).new != []
  end

  defp requested_by_suffix(%Run{requested_by: nil}), do: ""
  defp requested_by_suffix(%Run{requested_by: by}) when by == %{}, do: ""
  defp requested_by_suffix(%Run{requested_by: by}), do: " — requested by #{inspect(by)}"

  @doc """
  Close a run that never ran because one for the same source was already
  queued.

  Logged at `:info`: a duplicate enqueue is ordinary, not a failure.
  """
  @spec supersede(Run.t(), term()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def supersede(%Run{} = run, reason) do
    Logger.info(
      "[Analysis] run #{run.id} (#{run.source}) superseded: #{inspect(reason)}" <>
        requested_by_suffix(run)
    )

    RunsRepository.finish_run(run, :superseded, %{
      stats: %{"superseded" => String.slice(inspect(reason), 0, 500)}
    })
  end

  # -- Problem preparation --

  defp stamp_project(problem, scope),
    do: %{problem | project_id: scope.active_project_id}

  # Compiler fallback errors carry no file; one nil `file_path` would roll back
  # the whole reconcile.
  defp patch_file_path(%{file_path: nil} = problem), do: %{problem | file_path: "unknown"}

  # Paths are relative to the working copy root; an absolute one is deleted by
  # the next file sync. Warned, not rejected: rejecting would roll back the
  # source's other findings. See knowledge/analysis, "Problem file paths are relative".
  defp patch_file_path(%{file_path: "/" <> _rest = path} = problem) do
    Logger.warning(
      "[Analysis] problem recorded with an absolute file_path: #{path}. Paths are relative " <>
        "to the working copy root — this row will be deleted by the next file sync, because " <>
        "no relative path can match it (cc643bf3)."
    )

    problem
  end

  defp patch_file_path(problem), do: problem

  # Join to Files to stamp the owning component, so per-component rollups
  # count these problems.
  defp stamp_component_ids(problems, scope, source)
       when source in ["exunit", "spex", "credo", "compiler"] do
    paths = problems |> Enum.map(& &1.file_path) |> Enum.uniq()

    component_map =
      scope
      |> Files.get_by_paths(paths)
      |> Enum.filter(& &1.component_id)
      |> Map.new(&{&1.path, &1.component_id})

    Enum.map(problems, fn p ->
      case Map.get(component_map, p.file_path) do
        nil -> p
        component_id -> %{p | component_id: component_id}
      end
    end)
  end

  defp stamp_component_ids(problems, _scope, _source), do: problems

  # -- Clear scope --

  # A full run replaces its source's Problems wholesale, in one transaction, so
  # the old set stays readable until the new one lands.
  defp clear_scope(_scope, %Run{}), do: :all
end
