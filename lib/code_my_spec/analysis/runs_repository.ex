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
  alias CodeMySpec.Analysis.RunWaiter
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  # Keep this many finished runs per {project, source} — enough for the UI
  # gauge history and debugging without unbounded growth.
  @keep_per_source 20

  # How long a requested run its harness's departure killed still counts as
  # awaited by its agent. See `awaiting_runs?/3`.
  @orphan_awaited_s 15 * 60

  @doc "Insert a new `:running` run."
  @spec start_run(Scope.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def start_run(%Scope{active_project_id: project_id} = scope, attrs) do
    Repo.transaction(fn ->
      CodeMySpec.Analysis.ValidationHolds.lock(project_id)
      hold = CodeMySpec.Analysis.ValidationHolds.admit!(scope, attrs)

      changeset =
        %Run{}
        |> Run.changeset(
          attrs
          |> Map.put(:project_id, project_id)
          |> Map.put(:working_copy_id, scope.active_working_copy_id)
          |> Map.put_new(:status, :running)
          |> Map.put_new(:started_at, DateTime.utc_now())
        )

      case Repo.insert(changeset) do
        {:ok, run} ->
          CodeMySpec.Analysis.ValidationHolds.bind!(hold, run)
          run

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
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
    |> report_terminal_hold()
  end

  defp report_terminal_hold({:ok, run} = result) do
    CodeMySpec.Analysis.ValidationHolds.terminal(run)
    result
  end

  defp report_terminal_hold(error), do: error

  @doc """
  Record the git state a harness reported for `run` (`Run.tree_changeset/2`).
  A malformed commit is logged and the run returned unchanged: it describes
  the run, it does not decide whether the run's answer is recorded.
  """
  @spec record_tree(Run.t(), map()) :: Run.t()
  def record_tree(%Run{} = run, attrs) when map_size(attrs) == 0, do: run

  def record_tree(%Run{} = run, attrs) do
    case run |> Run.tree_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning(
          "[Analysis] run #{run.id} (#{run.source}) git state not recorded: " <>
            inspect(changeset.errors)
        )

        run
    end
  end

  @doc """
  Record on `run` what the harness actually ran, from the result's `"args"`
  (issue cae115ed).

  The harness ties a request for a source onto the entry already queued and
  merges their arguments, so a scoped request can execute the whole suite, or
  another request's files too, while its row still says what it asked for.
  The row keeps the request in `args["args"]` and gains `args["executed"]` when
  the two differ; its kind follows what ran, `:full` when the whole suite did.
  A result that names no arguments, or ran what was asked, leaves the row alone.
  """
  @spec record_executed(Run.t(), map()) :: Run.t()
  def record_executed(%Run{} = run, %{"args" => executed}) when is_list(executed) do
    requested = get_in(run.args || %{}, ["args"]) || []
    kind = if executed == [], do: :full, else: run.kind

    if executed == requested and kind == run.kind do
      run
    else
      attrs = %{kind: kind, args: Map.put(run.args || %{}, "executed", executed)}

      case run |> Run.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          updated

        {:error, changeset} ->
          Logger.warning(
            "[Analysis] run #{run.id} (#{run.source}) executed args not recorded: " <>
              inspect(changeset.errors)
          )

          run
      end
    end
  end

  def record_executed(%Run{} = run, _payload), do: run

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

  @doc """
  Latest completed `:full` run per source — the run that answers for each,
  however old. A newer failed run cannot displace a good result.
  """
  @spec latest_completed_runs(Scope.t()) :: %{String.t() => Run.t()}
  def latest_completed_runs(%Scope{active_project_id: project_id} = scope) do
    Run
    |> where([r], r.project_id == ^project_id and r.kind == :full and r.status == :completed)
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

  `latest_full_run/2` includes failures, which is right for reporting state.
  This is for deciding a source's findings: a failed run (e.g. a duplicate
  enqueue refused as already queued) cannot displace a good result.
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

  @doc """
  How many full runs of `source` on this working copy failed to run at
  `commit` during the attempt beginning at `since`: started there, or failed
  before they could say where they started (an analyzer that would not boot).
  Earlier attempts do not count, so a fresh promotion can retry. Orphaned runs
  (`stats.orphaned`) are not counted: they say nothing about the analyzer.
  """
  @spec failed_at_commit(Scope.t(), String.t(), String.t(), DateTime.t()) :: non_neg_integer()
  def failed_at_commit(%Scope{active_project_id: project_id} = scope, source, commit, since) do
    since = DateTime.to_naive(since)

    Run
    |> where([r], r.project_id == ^project_id and r.source == ^source and r.kind == :full)
    |> where([r], r.status == :failed)
    |> where([r], r.inserted_at >= ^since)
    |> where(
      [r],
      r.start_commit == ^commit or is_nil(r.start_commit)
    )
    |> where(
      [r],
      not r.orphaned
    )
    |> scope_to_harness(scope)
    |> Repo.aggregate(:count)
  end

  @doc """
  Whether `source` has a completed full run on this working copy — whether
  anything answers for it at all. An `exists` query: no row, no output column.
  """
  @spec answered?(Scope.t(), String.t()) :: boolean()
  def answered?(%Scope{active_project_id: project_id} = scope, source) do
    Run
    |> where([r], r.project_id == ^project_id and r.source == ^source and r.kind == :full)
    |> where([r], r.status == :completed)
    |> scope_to_harness(scope)
    |> Repo.exists?()
  end

  # Runs answer about one working copy's tree. A nil id means "no filter",
  # which suits reporting queries only; writers handle nil themselves
  # (`fail_running/3`). Ecto raises on `== ^nil`, hence the clause.
  # See knowledge/analysis, "Run ledger".
  defp scope_to_harness(query, %Scope{active_working_copy_id: nil}), do: query

  defp scope_to_harness(query, %Scope{active_working_copy_id: working_copy_id}),
    do: where(query, [r], r.working_copy_id == ^working_copy_id)

  @doc "Sources with a `:running` run for the project."
  @spec running_sources(Scope.t()) :: [String.t()]
  def running_sources(%Scope{} = scope), do: scope |> running_since() |> Map.keys()

  @doc """
  When each still-`:running` source started, for this working copy.

  The start time, not only the source, so repeated "a rerun is in flight"
  stops can be told apart from a livelock. Earliest start per source wins.
  """
  @spec running_since(Scope.t()) :: %{String.t() => DateTime.t()}
  def running_since(%Scope{active_project_id: project_id} = scope) do
    Run
    |> where([r], r.project_id == ^project_id and r.status == :running)
    # Scoped: another checkout's sweep never answers for this one, and the stop
    # hook tells the agent to wait on what this returns.
    |> scope_to_harness(scope)
    |> select([r], {r.source, r.started_at})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {source, started_at}, acc ->
      Map.update(acc, source, started_at, &earliest(&1, started_at))
    end)
  end

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  @doc """
  Whether `agent_id` has a run it requested or waits on still `:running`
  (queued runs included) on `working_copy_id`, or one its harness's departure
  killed that the rejoin has not settled yet.

  The killed one counts for 15 minutes. A harness rejoins in seconds and
  settles it (`Analysis.resume_orphaned/2`); one that never returns must not
  leave its agent silenced for good.
  """
  @spec awaiting_runs?(Scope.t(), Ecto.UUID.t() | nil, String.t()) :: boolean()
  def awaiting_runs?(%Scope{}, nil, _agent_id), do: false

  def awaiting_runs?(%Scope{active_project_id: project_id}, working_copy_id, agent_id) do
    since = DateTime.add(DateTime.utc_now(), -@orphan_awaited_s, :second)
    waiting = from(w in RunWaiter, where: w.agent_id == ^agent_id, select: w.run_id)

    Run
    |> where([r], r.project_id == ^project_id and r.working_copy_id == ^working_copy_id)
    |> where([r], r.requester_agent_id == ^agent_id or r.id in subquery(waiting))
    |> where(
      [r],
      r.status == :running or
        (r.status == :failed and r.finished_at > ^since and r.orphaned and is_nil(r.settled))
    )
    |> Repo.exists?()
  end

  @doc "The agents waiting on this run besides its requester."
  @spec waiter_ids(Run.t() | integer()) :: [String.t()]
  def waiter_ids(%Run{id: id}), do: waiter_ids(id)

  def waiter_ids(run_id),
    do: Repo.all(from(w in RunWaiter, where: w.run_id == ^run_id, select: w.agent_id))

  @doc "Carry `from_id`'s waiters onto the run that answers in its place."
  @spec copy_waiters(integer(), integer()) :: :ok
  def copy_waiters(from_id, to_id), do: add_waiters([to_id], waiter_ids(from_id))

  defp add_waiters(run_ids, agent_ids) do
    now = DateTime.utc_now()

    rows =
      for run_id <- run_ids,
          agent_id <- agent_ids,
          do: %{run_id: run_id, agent_id: agent_id, inserted_at: now}

    Repo.insert_all(RunWaiter, rows, on_conflict: :nothing)
    :ok
  end

  @doc """
  This working copy's runs its harness's departure killed that nothing has
  settled yet — not reopened, run again, or given up on. Oldest first.
  """
  @spec unsettled_orphans(Scope.t()) :: [Run.t()]
  def unsettled_orphans(%Scope{active_working_copy_id: nil}), do: []

  def unsettled_orphans(%Scope{active_project_id: project_id} = scope) do
    Run
    |> where([r], r.project_id == ^project_id and r.status == :failed)
    |> where([r], r.orphaned and is_nil(r.settled))
    |> scope_to_harness(scope)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  @doc """
  Record how an orphan was settled, once. `:already` when something else got
  there first, so a run is never re-dispatched twice.
  """
  @spec settle_orphan(Run.t(), String.t()) :: :ok | :already
  def settle_orphan(%Run{id: id}, how) do
    {count, _} =
      Run
      |> where([r], r.id == ^id and r.status == :failed and is_nil(r.settled))
      |> Repo.update_all(set: [settled: how])

    if count == 1, do: :ok, else: :already
  end

  @doc """
  Put an orphan back to `:running`, because the harness that rejoined says it
  is still executing it. Left failed, its result is refused as `unknown_run`
  and the same run is started a second time.
  """
  @spec reopen_orphan(Run.t()) :: :ok | :already
  def reopen_orphan(%Run{id: id}) do
    {count, _} =
      Run
      |> where([r], r.id == ^id and r.status == :failed and is_nil(r.settled))
      |> Repo.update_all(
        set: [
          status: :running,
          finished_at: nil,
          stats: nil,
          orphaned: false,
          updated_at: DateTime.utc_now()
        ]
      )

    if count == 1, do: :ok, else: :already
  end

  @doc "Whether the scope's working copy has a run still `:running`."
  @spec running_on?(Scope.t()) :: boolean()
  def running_on?(%Scope{active_working_copy_id: nil}), do: false

  def running_on?(%Scope{active_project_id: project_id, active_working_copy_id: copy_id}) do
    Run
    |> where([r], r.project_id == ^project_id and r.working_copy_id == ^copy_id)
    |> where([r], r.status == :running)
    |> Repo.exists?()
  end

  @doc """
  This working copy's still-`:running` full runs of `source`, newest first.

  Nil working copy answers nothing: the caller joins onto one of these, and a
  run from another checkout would answer about the wrong tree.
  """
  @spec running_full_runs(Scope.t(), String.t()) :: [Run.t()]
  def running_full_runs(%Scope{active_working_copy_id: nil}, _source), do: []

  def running_full_runs(%Scope{active_project_id: project_id} = scope, source) do
    Run
    |> where([r], r.project_id == ^project_id and r.source == ^source)
    |> where([r], r.kind == :full and r.status == :running)
    |> scope_to_harness(scope)
    |> order_by(desc: :id)
    |> Repo.all()
  end

  @doc """
  Add `agent_id` to the waiters of this copy's full runs of `source` still
  running that will answer for `commit`: started there on a clean tree, or
  queued and not started yet. Answers whether any such run exists, so a run
  somebody else started counts as the agent's own: it is told when it lands,
  and `awaiting_runs?/3` holds its nudges meanwhile. A run already requested
  by the agent is left as it is.
  """
  @spec wait_on_running_at_commit(Scope.t(), String.t(), String.t(), String.t()) :: boolean()
  def wait_on_running_at_commit(scope, source, commit, agent_id),
    do: join_running_at_commit(scope, source, commit, agent_id) != []

  @doc """
  `wait_on_running_at_commit/4`, answering the ids of the runs joined, newest
  first.
  """
  @spec join_running_at_commit(Scope.t(), String.t(), String.t(), String.t()) :: [integer()]
  def join_running_at_commit(%Scope{active_working_copy_id: nil}, _source, _commit, _agent),
    do: []

  def join_running_at_commit(%Scope{} = scope, source, commit, agent_id) do
    ids =
      scope
      |> running_full_runs(source)
      |> Enum.filter(&(is_nil(&1.start_commit) or at_clean_commit?(&1, commit)))
      |> Enum.map(& &1.id)

    Run
    |> where([r], r.id in ^ids and r.status == :running)
    |> where([r], is_nil(r.requester_agent_id) or r.requester_agent_id != ^agent_id)
    |> select([r], r.id)
    |> Repo.all()
    |> add_waiters([agent_id])

    ids
  end

  defp at_clean_commit?(%Run{start_commit: commit, start_tree_dirty: false}, commit), do: true
  defp at_clean_commit?(_run, _commit), do: false

  @doc """
  Fetch one still-`:running` run of this project by id.

  Scoped to this working copy and status-checked: a result for a closed run,
  or another copy's, is not applied (it would rewrite Problems off a run
  nobody is waiting for).
  """
  @spec get_running_run(Scope.t(), integer()) :: Run.t() | nil
  def get_running_run(%Scope{active_project_id: project_id} = scope, run_id) do
    Run
    |> where([r], r.id == ^run_id and r.project_id == ^project_id and r.status == :running)
    |> where([r], r.working_copy_id == ^scope.active_working_copy_id)
    |> Repo.one()
  end

  @doc "Find a retained run by id or latest source within the selected working copy."
  @spec output_run(Scope.t(), {:id, integer()} | {:source, String.t()}) :: Run.t() | nil
  def output_run(%Scope{active_working_copy_id: nil}, _selector), do: nil

  def output_run(%Scope{} = scope, selector) do
    query =
      Run
      |> where([r], r.project_id == ^scope.active_project_id)
      |> where([r], r.working_copy_id == ^scope.active_working_copy_id)
      |> select_output_run(selector)

    # d7a8122f: a superseded run never ran, so it has nothing to read. Picking
    # the newest row of any status let a later, empty superseded placeholder
    # shadow an earlier run that actually ran and recorded the failure a
    # promotion was rejected over. An explicit id is an exact lookup and skips
    # this; a source lookup falls back to the superseded row only when that is
    # the only run that ever happened.
    informative(query, selector) || latest_one(query)
  end

  defp informative(_query, {:id, _id}), do: nil

  defp informative(query, {:source, _source}) do
    query |> where([r], r.status != :superseded) |> latest_one()
  end

  defp latest_one(query),
    do: query |> order_by([r], desc: r.started_at, desc: r.id) |> limit(1) |> Repo.one()

  defp select_output_run(query, {:id, id}), do: where(query, [r], r.id == ^id)
  defp select_output_run(query, {:source, source}), do: where(query, [r], r.source == ^source)

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

  Scoped to the working copy: failing other checkouts' runs makes their
  results arrive as `unknown_run` and never be recorded.
  """
  @spec fail_running(Scope.t(), term()) :: {:ok, [Run.t()]}
  def fail_running(%Scope{} = scope, reason), do: fail_running(scope, reason, [])

  @doc """
  Close this working copy's `:running` runs, except the ones the harness says it
  is still working on.

  A restarted harness lost its queue, so those runs never finish; one whose
  socket merely dropped is still running them. The two look alike from here,
  so the harness declares on join what it still holds, and anything unclaimed
  is closed. An empty claim closes everything.
  """
  @spec fail_running(Scope.t(), term(), [integer()]) :: {:ok, [Run.t()]}
  # No working copy, nothing to close: `scope_to_harness/2`'s nil clause would
  # close every other checkout's runs.
  def fail_running(%Scope{active_working_copy_id: nil}, _reason, _claimed), do: {:ok, []}

  def fail_running(%Scope{active_project_id: project_id} = scope, reason, claimed) do
    now = DateTime.utc_now()

    # The closed rows come back so their requesters can be told.
    {_count, failed} =
      Run
      |> where([r], r.project_id == ^project_id and r.status == :running)
      |> scope_to_harness(scope)
      |> exclude_claimed(claimed)
      |> select([r], r)
      |> Repo.update_all(
        set: [
          status: :failed,
          finished_at: now,
          updated_at: now,
          stats: orphan_stats(reason),
          orphaned: true
        ]
      )

    Enum.each(failed, &CodeMySpec.Analysis.ValidationHolds.terminal/1)
    {:ok, failed}
  end

  # `orphaned` is what tells "its harness went away" from "the analyzer failed":
  # only these two sweeps set it, and only its runs are run again on rejoin
  # (`Analysis.resume_orphaned/2`). The reason string cannot carry that.
  defp orphan_stats(reason) do
    %{"error" => String.slice(inspect(reason), 0, 500)}
  end

  # An empty claim sweeps everything (an older harness, or nothing running).
  defp exclude_claimed(query, []), do: query
  defp exclude_claimed(query, claimed), do: where(query, [r], r.id not in ^claimed)

  @doc """
  Mark stranded `:running` rows as `:failed`.

  Called at boot, marking each `orphaned`. Runs this server executed died with
  it; runs dispatched to a harness may still be executing and will be refused
  as `unknown_run` when they report (the rejoin's `resume_orphaned` can reopen
  or rerun them). Deliberately blunt and logged: nothing can claim a run at
  boot because no harness has joined yet, and the alternative is a timer.
  """
  @spec fail_stranded_runs() :: {:ok, [Run.t()]}
  def fail_stranded_runs do
    now = DateTime.utc_now()

    {_count, failed} =
      Run
      |> where([r], r.status == :running)
      |> select([r], r)
      |> Repo.update_all(
        set: [
          status: :failed,
          finished_at: now,
          updated_at: now,
          stats: orphan_stats(:server_restarted),
          orphaned: true
        ]
      )

    Enum.each(failed, &CodeMySpec.Analysis.ValidationHolds.terminal/1)

    failed
    |> Enum.map(&{&1.id, &1.source, &1.working_copy_id})
    |> log_stranded()

    {:ok, failed}
  end

  defp log_stranded([]), do: :ok

  defp log_stranded(stranded) do
    {remote, local} =
      Enum.split_with(stranded, fn {_id, _source, working_copy_id} -> working_copy_id end)

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
