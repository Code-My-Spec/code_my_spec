defmodule CodeMySpec.Analysis.Reconciler do
  @moduledoc """
  Persists a finished analyzer run — the single write path for run results.

  Atomically reconciles Problems (clear + insert in one transaction, scoped by
  run kind), stamps `component_id` on test problems, marks the run finished,
  prunes old ledger rows, then re-evaluates the project's active sessions so a
  task whose analyzers just passed completes without waiting for another stop.

  Runs inside the analysis Task — never inside a GenServer callback and never
  tied to an HTTP connection's lifetime, so an aborted hook request can no
  longer strand half-reconciled problems.
  """

  require Logger

  alias CodeMySpec.Analysis.{
    AgentReport,
    Coverage,
    Fingerprint,
    Run,
    RunsRepository,
    Signatures
  }

  alias CodeMySpec.Files
  alias CodeMySpec.Notifications.NotificationClient
  alias CodeMySpec.Problems
  alias CodeMySpec.Sessions
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation.TaskEvaluator

  @doc """
  Persist a successful runner result for `run`.

  Returns `{:ok, run}` with the finished Run row.
  """
  @spec reconcile(Scope.t(), Run.t(), map(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def reconcile(scope, run, result, opts \\ [])

  # A targeted run (`mix test test/foo_test.exs`, rewritten by the PreToolUse
  # hook) only covers the files it names, so its result is not the complete
  # picture for the source. The reconcile below is wholesale — clear the
  # source, insert what this run found — and applying that to a one-file run
  # deletes every Problem the run never looked at, then finishes `:completed`
  # at the current fingerprint. That combination reported the whole suite
  # fresh and passing off a single test file.
  #
  # So a partial finishes with output, exit status and stats — which is what
  # the model reads back from the analysis API — and leaves Problems alone.
  # `latest_full_run/2` filters `kind == :full`, so it never satisfies
  # freshness either. The stop hook's full run stays the authoritative sweep.
  def reconcile(%Scope{}, %Run{kind: :partial} = run, result, _opts) do
    Logger.info("[Analysis] #{run.source} targeted run — output only, Problems untouched")

    RunsRepository.finish_run(run, :completed, %{
      output: result.output,
      exit_status: result.exit_status,
      stats: result.stats
    })
  end

  def reconcile(%Scope{} = scope, %Run{} = run, result, opts) do
    problems =
      result.problems
      |> Enum.map(&(&1 |> stamp_project(scope) |> patch_file_path()))
      |> stamp_component_ids(scope, run.source)

    file_scope = clear_scope(scope, run)

    case Problems.reconcile_problems_for_source(scope, run.source, file_scope, problems) do
      {:ok, _inserted} ->
        # What this run read, per file, at the content it read.
        #
        # `problems` already says "this file had this finding at this content".
        # Nothing said "this file was clean at this content", so a file with no
        # findings and a file nobody analysed were the same shape — no rows —
        # and `count == 0` read *clean* out of an *absence*.
        #
        # Recorded here rather than at run start, because only this branch means
        # the run produced results. A run that fails or is superseded records no
        # coverage, so its files stay unread rather than claiming a verdict
        # nothing produced.
        record_coverage(scope, run)

        # Read before finishing: this run is still `:running`, so
        # `latest_completed_run/2` returns the sweep before it. After
        # `finish_run` it would return this one and the delta would be empty.
        previous = RunsRepository.latest_completed_run(scope, run.source)
        signatures = Signatures.of(problems)

        {:ok, finished} =
          RunsRepository.finish_run(run, :completed, %{
            output: result.output,
            exit_status: result.exit_status,
            stats: Signatures.put(result.stats, signatures),
            # The tree this answered about, as opposed to the one it was asked
            # about. `input_fingerprint` is stamped at enqueue, so the two differ
            # exactly when an edit landed while the run was in flight — which is
            # the difference between a result that waiting will refresh and one
            # that no amount of waiting can (7a7eed33).
            completed_fingerprint: Fingerprint.current(scope, run.source)
          })

        RunsRepository.prune(scope, run.source)
        evaluate_sessions(scope)
        maybe_notify(scope, finished, problems, opts)

        # The internal half of story 1042. `maybe_notify/4` above is the push to
        # the *person*; this is the push to the agents running in our own BEAM,
        # which have a process to reach and should not have to wait on one.
        #
        # A Claude Code session in the same copy is not told here — it collects
        # the digest on its next tool call through `Hooks.AnalysisAlert`. Two
        # consumers, two shapes, and telling both here would tell one of them
        # twice.
        AgentReport.deliver(scope, run.source, problems)

        Logger.info(
          "[Analysis] #{run.source} reconciled: #{length(problems)} problem(s) (#{run.kind})" <>
            Signatures.delta_suffix(previous, signatures)
        )

        {:ok, finished}

      {:error, reason} ->
        Logger.error("[Analysis] #{run.source} reconcile failed: #{inspect(reason)}")
        RunsRepository.finish_run(run, :failed, %{stats: %{"error" => inspect(reason)}})
        {:error, reason}
    end
  end

  @doc "Mark a run failed (tool crash, skip, or task death) — no problem changes."
  @spec fail(Run.t(), term()) :: {:ok, Run.t()} | {:error, term()}
  def fail(%Run{} = run, reason) do
    Logger.warning("[Analysis] #{run.source} failed: #{inspect(reason)}")

    RunsRepository.finish_run(run, :failed, %{
      stats: %{"error" => error_text(reason)}
    })
  end

  # A string reason is stored as itself; everything else is inspected.
  #
  # This was `inspect/1` unconditionally, which wrapped an already-readable
  # message in quotes and flattened its newlines into literal `\n`. That was
  # invisible while nothing read the column back. It stopped being invisible
  # when `Validation.failure_reason/1` started surfacing it in the stop response
  # (`639d0fc1`), where the reader is an agent being told why an analyzer could
  # not run:
  #
  #     "credo crashed: … has not been onboarded.\nRun: mix harness.onboard"
  #
  # — one quoted line instead of two, with the remedy buried in an escape.
  #
  # Non-binaries still go through `inspect/1`, and must: `skipped_for_compile_errors?/1`
  # matches on the inspected atom.
  defp error_text(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp error_text(reason), do: String.slice(inspect(reason), 0, 500)

  @doc """
  Close a run that never ran because one for the same source was already
  queued.

  At `:info`, not `:warning` — nothing is wrong. A duplicate enqueue is the
  ordinary result of a stop hook asking again while work is pending, and
  logging it as a failure taught readers to ignore a level that should mean
  something.
  """
  @spec supersede(Run.t(), term()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def supersede(%Run{} = run, reason) do
    Logger.info("[Analysis] #{run.source} superseded: #{inspect(reason)}")

    RunsRepository.finish_run(run, :superseded, %{
      stats: %{"superseded" => String.slice(inspect(reason), 0, 500)}
    })
  end

  # -- Problem preparation --

  defp stamp_project(problem, scope),
    do: %{problem | project_id: scope.active_project_id}

  # Compiler fallback errors recovered from raw output carry no file — the
  # Problem schema requires file_path, and one nil row would roll back the
  # whole reconcile.
  defp patch_file_path(%{file_path: nil} = problem), do: %{problem | file_path: "unknown"}

  # Every path in this table is relative to the working copy root, and until
  # `cc643bf3` nothing said so or checked. An absolute one is not merely
  # inconsistent: `clear_problems_for_missing_files/2` deletes any Problem whose
  # path is not in the current file list, that list is relative, so the row is
  # removed on the next sync as though its file had been deleted. Four spex
  # failures spent an unknown period appearing on one sweep and vanishing on the
  # next because of it.
  #
  # Warned rather than rejected, deliberately. A changeset that refused would
  # roll back `insert_all_problems/2` and take every other problem for that
  # source with it — losing a whole analyzer's findings to punish one bad path
  # is the wrong trade. This makes the next violation announce itself, which is
  # the property that was missing.
  defp patch_file_path(%{file_path: "/" <> _rest = path} = problem) do
    Logger.warning(
      "[Analysis] problem recorded with an absolute file_path: #{path}. Paths are relative " <>
        "to the working copy root — this row will be deleted by the next file sync, because " <>
        "no relative path can match it (cc643bf3)."
    )

    problem
  end

  defp patch_file_path(problem), do: problem

  # Test failures land on the test file's path; join to Files to stamp the
  # owning component. Without this, per-component `tests_passing` counts zero
  # failures (Preloader filters `not is_nil(component_id)`) and reports
  # satisfied while tests fail.
  defp stamp_component_ids(problems, scope, source) when source in ["exunit", "spex"] do
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

  # No rescue. The first version had one — "best effort, a coverage failure must
  # not fail a reconcile that already landed its Problems" — and it earned its
  # keep immediately, in the worst way: a missing alias made this raise
  # `module Coverage is not available`, and the rescue turned that into a
  # warning in a log nobody reads while the tests failed for no stated reason.
  #
  # A coverage write that cannot happen is a defect. A reconcile that silently
  # records nothing is the absence-reading-as-success this table exists to end,
  # arriving through the door built to protect it.
  #
  # No working copy records nothing, and that is an answer rather than a
  # swallowed failure: coverage is keyed per checkout, so there is no row to
  # write and nothing being claimed.
  defp record_coverage(%Scope{active_working_copy_id: nil}, _run), do: :ok

  defp record_coverage(%Scope{} = scope, %Run{started_at: %DateTime{} = started_at} = run) do
    entries = Coverage.seen_entries(scope, run.source, started_at)
    Coverage.record(scope, run.source, entries, run_id: run.id, analyzed_at: started_at)
    :ok
  end

  # -- Clear scope --

  # Every run sweeps the whole project, so every run replaces its source's
  # Problems wholesale: clear all, then insert what this run found — one
  # transaction, so the old set stays readable until the new one lands.
  #
  # This deliberately replaced a scoped variant that derived the clear set by
  # parsing paths back out of `run.args`. It could only ever clear part of the
  # table, so a problem fixed by an edit elsewhere never went away, and the
  # arg parsing was fragile besides (an extension-less token was treated as a
  # directory and expanded to every file beneath it).
  defp clear_scope(_scope, %Run{}), do: :all

  # -- Post-persist hooks --

  # Complete tasks whose analyzers just passed. Feedback recording is
  # suppressed: a background re-evaluation repeating the same failure text
  # must not advance the R8 stuck counter — only agent-facing stops do that.
  # `sync: false` — the triggering stop already synced, and a second full
  # sync's missing-files sweep would race the problems just reconciled.
  defp evaluate_sessions(scope) do
    scope
    |> Sessions.list_active_sessions()
    |> Enum.each(fn session ->
      TaskEvaluator.evaluate_session(scope, session, record_feedback: false, sync: false)
    end)
  rescue
    e ->
      Logger.warning("[Analysis] session evaluation failed: #{Exception.message(e)}")
  end

  # Background runs (stop-hook enqueued) push the outcome to the user's
  # phone when they land blocking-severity problems — the agent may already
  # have stopped, and this is how the result reaches a user who walked away.
  # Model-invoked API runs skip this: the caller sees the output directly.
  defp maybe_notify(scope, run, problems, opts) do
    errors = Enum.count(problems, &(&1.severity == :error))

    if Keyword.get(opts, :notify, false) and errors > 0 do
      NotificationClient.notify(%{
        title: "Analysis: #{run.source} found #{errors} problem(s)",
        body: notification_body(scope, problems)
      })
    end
  end

  defp notification_body(scope, problems) do
    first = problems |> Enum.filter(&(&1.severity == :error)) |> List.first()
    project = (scope.active_project && scope.active_project.name) || "project"

    case first do
      nil -> project
      p -> "#{project} — #{p.file_path}:#{p.line || "?"}"
    end
  end
end
