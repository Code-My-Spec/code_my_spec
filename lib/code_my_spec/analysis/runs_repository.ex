defmodule CodeMySpec.Analysis.RunsRepository do
  @moduledoc """
  Scoped data access for the analysis run ledger.

  All queries filter by the scope's active project. The ledger is append-heavy:
  runs are inserted `:running` at enqueue, then completed/failed exactly once.
  Old rows are pruned per `{project, source}` so the table stays small.
  """

  import Ecto.Query, warn: false

  require Logger

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
  def latest_full_runs(%Scope{active_project_id: project_id} = scope) do
    Run
    |> where([r], r.project_id == ^project_id and r.kind == :full)
    |> where([r], r.status in [:completed, :failed])
    |> scope_to_harness(scope)
    |> order_by([r], asc: r.started_at)
    |> Repo.all()
    |> Map.new(&{&1.source, &1})
  end

  @doc "Latest finished `:full` run for one source, or nil."
  @spec latest_full_run(Scope.t(), String.t()) :: Run.t() | nil
  def latest_full_run(%Scope{active_project_id: project_id} = scope, source) do
    Run
    |> where([r], r.project_id == ^project_id and r.source == ^source and r.kind == :full)
    |> where([r], r.status in [:completed, :failed])
    |> scope_to_harness(scope)
    |> order_by(desc: :started_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Latest run of one source that actually produced an answer, for this working
  copy.

  `latest_full_run/2` includes failures, which is right for reporting *state* —
  an analyzer that keeps dying should say so. It is wrong for deciding
  freshness, because `fresh?/2` and `stale?/3` both require `:completed` and
  read anything else as stale. So a run that never ran makes a source stale
  even when a good result sits behind it, and a duplicate enqueue refused as
  "already queued" is exactly that: 14 such rows in half an hour on this
  machine, each one marking its source stale.

  A refusal is a scheduling fact. It should not be able to invalidate an
  answer.
  """
  @spec latest_completed_run(Scope.t(), String.t()) :: Run.t() | nil
  def latest_completed_run(%Scope{active_project_id: project_id} = scope, source) do
    Run
    |> where([r], r.project_id == ^project_id and r.source == ^source and r.kind == :full)
    |> where([r], r.status == :completed)
    |> scope_to_harness(scope)
    |> order_by(desc: :started_at)
    |> limit(1)
    |> Repo.one()
  end

  # Freshness is a question about one working copy's tree. Unscoped, the latest
  # run of *any* checkout answered it, and its fingerprint is computed over
  # different files — so a source could never be fresh while another agent
  # worked. `acde83fd` scoped the lookup on submit and the sweep on join and
  # missed these two.
  defp scope_to_harness(query, %Scope{active_harness_id: nil}), do: query

  defp scope_to_harness(query, %Scope{active_harness_id: harness_id}),
    do: where(query, [r], r.harness_id == ^harness_id)

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
  Any run of this project by id, whatever its status or owner.

  For explaining a refusal, never for deciding one — `get_running_run/2` is
  what a result is matched against.
  """
  @spec get_run_in_project(Scope.t(), integer()) :: Run.t() | nil
  def get_run_in_project(%Scope{active_project_id: project_id}, run_id) do
    Run
    |> where([r], r.id == ^run_id and r.project_id == ^project_id)
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
  def fail_running(%Scope{} = scope, reason), do: fail_running(scope, reason, [])

  @doc """
  Close this working copy's `:running` runs, except the ones the harness says it
  is still working on.

  A harness that restarted took its queue with it and those runs will never
  finish, so closing them is what stops every later stop reporting "analysis
  pending" on a next time that never arrives. A harness whose *socket* dropped
  took nothing with it: the analyzers are OS processes on its machine, and they
  finish, report, and are refused because the row is no longer `:running`.

  The two are indistinguishable from here, which is why the harness declares
  what it still holds on join. Anything it does not claim is closed, so a
  genuinely dead harness is handled exactly as before — an empty declaration is
  the old behaviour.
  """
  @spec fail_running(Scope.t(), term(), [integer()]) :: {:ok, non_neg_integer()}
  def fail_running(%Scope{active_project_id: project_id} = scope, reason, claimed) do
    now = DateTime.utc_now()

    {count, _} =
      Run
      |> where([r], r.project_id == ^project_id and r.status == :running)
      |> where([r], r.harness_id == ^scope.active_harness_id)
      |> exclude_claimed(claimed)
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

  # An empty claim sweeps everything, which is what this did before harnesses
  # declared anything — so an older harness, or one with nothing running, is
  # unchanged.
  defp exclude_claimed(query, []), do: query
  defp exclude_claimed(query, claimed), do: where(query, [r], r.id not in ^claimed)

  @doc """
  Mark stranded `:running` rows as `:failed`.

  Called at boot: a run left `:running` by a previous server process died with
  that process — its RunServer no longer exists, so nothing will ever finish it.

  That premise holds for runs this server executed. It does not hold for runs
  dispatched to a light harness: those are OS processes on another machine and a
  server restart does not touch them. One caught mid-flight finishes, reports,
  and is refused — the row is no longer `:running`. Restarting the server during
  a 200-second `mix test` is enough to do it.

  Left as it is deliberately, and logged instead. The join sweep is where a
  harness can say what it still holds (`fail_running/3`); nothing can claim at
  boot, because nothing has joined yet. Making this one smarter means either
  keeping rows open for a harness that may never return, or a timer — and a
  timer compensating for a deadline is what the channel exists to avoid.

  So it stays blunt and says what it did.
  """
  @spec fail_stranded_runs() :: {:ok, integer()}
  def fail_stranded_runs do
    now = DateTime.utc_now()

    stranded =
      Run
      |> where([r], r.status == :running)
      |> select([r], {r.id, r.source, r.harness_id})
      |> Repo.all()

    {count, _} =
      Run
      |> where([r], r.status == :running)
      |> Repo.update_all(set: [status: :failed, finished_at: now, updated_at: now])

    log_stranded(stranded)

    {:ok, count}
  end

  defp log_stranded([]), do: :ok

  defp log_stranded(stranded) do
    {remote, local} = Enum.split_with(stranded, fn {_id, _source, harness_id} -> harness_id end)

    Logger.warning(
      "[Analysis] boot closed #{length(stranded)} run(s) left open by the previous server: " <>
        "#{inspect(Enum.map(stranded, fn {id, source, _} -> {id, source} end))}"
    )

    if remote != [] do
      Logger.warning(
        "[Analysis] #{length(remote)} of those were dispatched to a harness and may still be " <>
          "executing there — their results will be refused as unknown_run. " <>
          "#{length(local)} ran on this server and are genuinely dead."
      )
    end
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
