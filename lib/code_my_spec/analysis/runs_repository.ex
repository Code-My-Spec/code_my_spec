defmodule CodeMySpec.Analysis.RunsRepository do
  @moduledoc """
  Scoped data access for the analysis run ledger.

  All queries filter by the scope's active project. The ledger is append-heavy:
  runs are inserted `:running` at enqueue, then completed/failed exactly once.
  Old rows are pruned per `{project, source}` so the table stays small.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  # Keep this many finished runs per {project, source} — enough for the UI
  # gauge history and debugging without unbounded growth.
  @keep_per_source 20

  @doc "Insert a new `:running` run stamped with its enqueue-time fingerprint."
  @spec start_run(Scope.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def start_run(%Scope{active_project_id: project_id} = scope, attrs) do
    %Run{}
    |> Run.changeset(
      attrs
      |> Map.put(:project_id, project_id)
      |> Map.put(:harness_id, scope.active_harness_id)
      |> Map.put_new(:status, :running)
      |> Map.put_new(:started_at, DateTime.utc_now())
    )
    |> Repo.insert()
  end

  @doc "Mark a run finished (`:completed` or `:failed`) with output/stats."
  @spec finish_run(Run.t(), :completed | :failed, map()) ::
          {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def finish_run(%Run{} = run, status, attrs \\ %{}) do
    run
    |> Run.changeset(
      attrs
      |> Map.put(:status, status)
      |> Map.put_new(:finished_at, DateTime.utc_now())
    )
    |> Repo.update()
  end

  @doc """
  Latest finished `:full` run per source for the project.

  Returns a `%{source => Run.t()}` map — the freshness baseline for the
  memoization check and the UI gauge.
  """
  @spec latest_full_runs(Scope.t()) :: %{String.t() => Run.t()}
  def latest_full_runs(%Scope{active_project_id: project_id}) do
    Run
    |> where([r], r.project_id == ^project_id and r.kind == :full)
    |> where([r], r.status in [:completed, :failed])
    |> order_by([r], asc: r.started_at)
    |> Repo.all()
    |> Map.new(&{&1.source, &1})
  end

  @doc "Latest finished `:full` run for one source, or nil."
  @spec latest_full_run(Scope.t(), String.t()) :: Run.t() | nil
  def latest_full_run(%Scope{active_project_id: project_id}, source) do
    Run
    |> where([r], r.project_id == ^project_id and r.source == ^source and r.kind == :full)
    |> where([r], r.status in [:completed, :failed])
    |> order_by(desc: :started_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Sources with a `:running` run for the project."
  @spec running_sources(Scope.t()) :: [String.t()]
  def running_sources(%Scope{active_project_id: project_id}) do
    Run
    |> where([r], r.project_id == ^project_id and r.status == :running)
    |> select([r], r.source)
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  Fetch one still-`:running` run of this project by id.

  Scoped and status-checked together on purpose: a result arriving for a run
  that is already closed, or that belongs to another project, is not a late
  answer to apply — it is a harness talking about something this server is not
  tracking, and reconciling it would rewrite a source's Problems off a run
  nobody is waiting for.
  """
  @spec get_running_run(Scope.t(), integer()) :: Run.t() | nil
  def get_running_run(%Scope{active_project_id: project_id} = scope, run_id) do
    Run
    |> where([r], r.id == ^run_id and r.project_id == ^project_id and r.status == :running)
    |> where([r], r.harness_id == ^scope.active_harness_id)
    |> Repo.one()
  end

  @doc """
  Mark every `:running` run of this *working copy* `:failed`.

  For the moment its remote executor provably cannot answer them: its channel
  closed, or a new one joined and the old queue is gone.

  Scoped to the harness, because "provably cannot answer" is a claim about one
  working copy. Scoped to the project it also failed every other checkout's
  in-flight runs — and with a worktree per branch, a join from any harness
  killed everyone else's work. Their analyzers then answered rows that were no
  longer `:running` and were told `unknown_run`. 285 results sent, 0 accepted,
  and `bdd_specs_passing` unsatisfiable for every story, because the only
  evidence that can satisfy it is a result that could never be recorded.
  """
  @spec fail_running(Scope.t(), term()) :: {:ok, non_neg_integer()}
  def fail_running(%Scope{active_project_id: project_id} = scope, reason) do
    now = DateTime.utc_now()

    {count, _} =
      Run
      |> where([r], r.project_id == ^project_id and r.status == :running)
      |> where([r], r.harness_id == ^scope.active_harness_id)
      |> Repo.update_all(
        set: [
          status: :failed,
          finished_at: now,
          updated_at: now,
          stats: %{"error" => String.slice(inspect(reason), 0, 500)}
        ]
      )

    {:ok, count}
  end

  @doc """
  Mark stranded `:running` rows as `:failed`.

  Called at boot: a run left `:running` by a previous server process died with
  that process — its RunServer no longer exists, so nothing will ever finish it.
  """
  @spec fail_stranded_runs() :: {:ok, integer()}
  def fail_stranded_runs do
    now = DateTime.utc_now()

    {count, _} =
      Run
      |> where([r], r.status == :running)
      |> Repo.update_all(set: [status: :failed, finished_at: now, updated_at: now])

    {:ok, count}
  end

  @doc "Prune finished runs beyond the newest #{@keep_per_source} per source."
  @spec prune(Scope.t(), String.t()) :: {:ok, integer()}
  def prune(%Scope{active_project_id: project_id}, source) do
    keep_ids =
      Run
      |> where([r], r.project_id == ^project_id and r.source == ^source)
      |> where([r], r.status in [:completed, :failed])
      |> order_by(desc: :started_at)
      |> limit(@keep_per_source)
      |> select([r], r.id)
      |> Repo.all()

    {count, _} =
      Run
      |> where([r], r.project_id == ^project_id and r.source == ^source)
      |> where([r], r.status in [:completed, :failed])
      |> where([r], r.id not in ^keep_ids)
      |> Repo.delete_all()

    {:ok, count}
  end
end
