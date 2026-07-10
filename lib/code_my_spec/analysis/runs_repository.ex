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
  def start_run(%Scope{active_project_id: project_id}, attrs) do
    %Run{}
    |> Run.changeset(
      attrs
      |> Map.put(:project_id, project_id)
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
