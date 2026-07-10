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

  alias CodeMySpec.Analysis.{Run, RunsRepository}
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
  def reconcile(%Scope{} = scope, %Run{} = run, result, opts \\ []) do
    problems =
      result.problems
      |> Enum.map(&stamp_project(&1, scope))
      |> Enum.map(&patch_file_path/1)
      |> stamp_component_ids(scope, run.source)

    file_scope = clear_scope(scope, run)

    case Problems.reconcile_problems_for_source(scope, run.source, file_scope, problems) do
      {:ok, _inserted} ->
        {:ok, finished} =
          RunsRepository.finish_run(run, :completed, %{
            output: result.output,
            exit_status: result.exit_status,
            stats: result.stats
          })

        RunsRepository.prune(scope, run.source)
        evaluate_sessions(scope)
        maybe_notify(scope, finished, problems, opts)

        Logger.info(
          "[Analysis] #{run.source} reconciled: #{length(problems)} problem(s) (#{run.kind})"
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
      stats: %{"error" => String.slice(inspect(reason), 0, 500)}
    })
  end

  # -- Problem preparation --

  defp stamp_project(problem, scope),
    do: %{problem | project_id: scope.active_project_id}

  # Compiler fallback errors recovered from raw output carry no file — the
  # Problem schema requires file_path, and one nil row would roll back the
  # whole reconcile.
  defp patch_file_path(%{file_path: nil} = problem), do: %{problem | file_path: "unknown"}
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

  # -- Clear scope --

  # Full runs produce the complete picture for their source → clear all.
  # Partial (targeted) runs only refresh the files they actually covered.
  defp clear_scope(_scope, %Run{kind: :full}), do: :all

  defp clear_scope(scope, %Run{kind: :partial} = run) do
    run.args
    |> args_list()
    |> Enum.filter(&path_like?/1)
    |> Enum.map(&strip_line/1)
    |> Enum.flat_map(&expand_path(scope, &1))
    |> Enum.uniq()
    |> case do
      # No recognizable paths — don't wipe anything beyond what we insert over.
      [] -> []
      paths -> paths
    end
  end

  defp args_list(%{"args" => args}) when is_list(args), do: args
  defp args_list(args) when is_list(args), do: args
  defp args_list(_), do: []

  defp path_like?(arg), do: not String.starts_with?(arg, "-")

  defp strip_line(arg), do: arg |> String.split(":") |> hd()

  # A directory arg covers every tracked file under it.
  defp expand_path(scope, path) do
    trimmed = String.trim_trailing(path, "/")

    if String.ends_with?(path, "/") or Path.extname(trimmed) == "" do
      scope
      |> Files.list_files()
      |> Enum.filter(&String.starts_with?(&1.path, trimmed <> "/"))
      |> Enum.map(& &1.path)
    else
      [trimmed]
    end
  end

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
