defmodule CodeMySpec.DevState do
  @moduledoc """
  What the database believes, what the runtime is doing, and where they disagree.

  Every hard failure on 2026-09-07 was that gap, and every one was diagnosed by
  inferring runtime state from log lines:

    * the harness took a `SIGTERM` from a deploy and stayed down for 55 minutes
      while every agent row still read `continuous: true, status: starting`. The
      only symptom was one undelivered message in one conversation.
    * `GraphWatcher`s live in memory, so a deploy took them all, and a project
      with nothing watching it looks exactly like a project whose graph has not
      moved.
    * four `analysis_runs` rows said `:running` for one checkout with a single
      `mix spex` process behind them.
    * agents orphaned by a restart: the ledger says running, the machine holds
      nothing, and the two are only comparable by hand.

  None of that is visible from a table, and LiveDashboard does not answer it
  either — it shows processes, not whether *this* project has a watcher or
  *this* checkout has an executor.

  John: "I'm just having to click through this and find every little thing...
  How can we get you the QA tools so that you can go QA this thing for me?"

  `disagreements` is the point of the whole thing. The rest is evidence for it —
  a reader who looks only at that list and finds it empty has learned the thing
  worth knowing.

  Here rather than in the controller because `CodeMySpecWeb` may not reach
  `CodeMySpec.Repo`, and because a reconcile between two sources of truth is a
  domain question that happens to have a JSON view today.
  """

  import Ecto.Query

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @known_sources ~w(compiler credo exunit spex)

  @doc "Every project, or one, reconciled against the runtime."
  @spec report(Ecto.UUID.t() | nil) :: map()
  def report(project_id \\ nil) do
    reports = project_id |> projects() |> Enum.map(&project_report/1)

    %{
      checked_at: DateTime.utc_now(),
      disagreements: Enum.flat_map(reports, & &1.disagreements),
      projects: reports
    }
  end

  @doc """
  Ask for analyzer runs on one checkout, and say what the queue decided.

  `ensure_stale_runs/3` is the same call the stop hook makes, and it answers
  which sources it enqueued and which were already current. That distinction is
  the thing worth having: "nothing happened" and "it was already fresh so
  nothing needed to" are the same silence from outside.
  """
  @spec request_run(Ecto.UUID.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def request_run(working_copy_id, source) do
    with {:ok, copy} <- fetch_copy(working_copy_id),
         {:ok, sources} <- fetch_sources(source) do
      report = Analysis.ensure_stale_runs(scope_for(copy), sources)

      {:ok,
       %{
         working_copy_id: copy.id,
         root: copy.root,
         requested: sources,
         enqueued: report.enqueued,
         already_current: report.memoized,
         executor: executor(copy.id),
         note: note(report, copy)
       }}
    end
  end

  # An enqueue against a checkout nobody is holding goes nowhere, and the ledger
  # then carries a `:running` row that never finishes — the exact shape
  # `disagreements/4` reports. Said when asked rather than left to be found.
  defp note(%{enqueued: []}, _copy), do: "nothing enqueued — every source was already current"

  defp note(_report, copy) do
    case Analysis.executor_holder(copy.id) do
      {:ok, _pid, _instance} -> "enqueued; poll /dev/state for it to finish"
      :error -> "enqueued, but nothing is holding this working copy — it will not run"
    end
  end

  defp fetch_copy(id) when is_binary(id) and id != "" do
    case Repo.get(WorkingCopy, id) do
      nil -> {:error, "no working copy with id #{id}"}
      copy -> {:ok, copy}
    end
  end

  defp fetch_copy(_), do: {:error, "working_copy_id is required"}

  defp fetch_sources(blank) when blank in [nil, ""], do: {:ok, @known_sources}

  defp fetch_sources(source) do
    asked = String.split(source, ",", trim: true)

    case Enum.reject(asked, &(&1 in @known_sources)) do
      [] -> {:ok, asked}
      unknown -> {:error, "unknown source(s): #{Enum.join(unknown, ", ")}"}
    end
  end

  # Enough scope for the analysis path, built from the checkout rather than from
  # a session: this caller has no account and is asking about somebody else's
  # project on purpose.
  defp scope_for(%WorkingCopy{} = copy) do
    project = Repo.get!(Project, copy.project_id)

    %Scope{
      active_project: project,
      active_project_id: project.id,
      active_account_id: project.account_id,
      active_working_copy_id: copy.id
    }
  end

  defp projects(id) when is_binary(id) and id != "",
    do: Project |> where([p], p.id == ^id) |> Repo.all()

  defp projects(_), do: Repo.all(from(p in Project, order_by: p.name))

  defp project_report(%Project{} = project) do
    copies = Repo.all(from(w in WorkingCopy, where: w.project_id == ^project.id))
    agents = AgentsRepository.list_every_agent(project_id: project.id)
    watcher = GraphWatcher.status(project.id)
    copy_reports = Enum.map(copies, &copy_report(&1, agents))

    %{
      project_id: project.id,
      name: project.name,
      graph_watcher: watcher_report(watcher),
      working_copies: copy_reports,
      disagreements: disagreements(project, watcher, agents, copy_reports)
    }
  end

  defp watcher_report(nil), do: %{watching: false}

  defp watcher_report(%{pending: pending, last_recompute: last}),
    do: %{watching: true, recompute_pending: pending, last_recompute: last}

  defp copy_report(%WorkingCopy{} = copy, agents) do
    %{
      id: copy.id,
      root: copy.root,
      main: copy.main,
      executor: executor(copy.id),
      agents: agents |> Enum.filter(&(&1.working_copy_id == copy.id)) |> Enum.map(&agent/1),
      runs_claiming_running: claiming_running(copy.id)
    }
  end

  defp executor(copy_id) do
    case Analysis.executor_holder(copy_id) do
      {:ok, pid, instance} -> %{held: true, pid: inspect(pid), instance: instance}
      :error -> %{held: false}
    end
  end

  defp agent(agent) do
    %{
      id: agent.id,
      role: agent.role,
      status: agent.status,
      continuous: agent.continuous,
      engine: agent.engine
    }
  end

  # Straight off the ledger, because the disagreement worth naming is between
  # this list and the OS. One `mix spex` behind four `:running` rows reads as
  # "the analyzers are busy" and is really "three of these will never finish".
  defp claiming_running(copy_id) do
    Run
    |> where([r], r.working_copy_id == ^copy_id and r.status == :running)
    |> select([r], %{id: r.id, source: r.source, started_at: r.started_at})
    |> Repo.all()
  end

  # Each of these was a real incident, and each was found by reading logs rather
  # than by asking.
  defp disagreements(project, watcher, agents, copy_reports) do
    unreachable =
      for copy <- copy_reports,
          not copy.executor.held,
          agent <- copy.agents,
          agent.status in [:starting, :running] do
        "agent #{agent.id} (#{agent.role}) is #{agent.status} on #{copy.root}, but nothing is " <>
          "holding that working copy — messages to it fail as harness_not_connected"
      end

    stale_runs =
      for copy <- copy_reports,
          not copy.executor.held,
          run <- copy.runs_claiming_running do
        "analysis run #{run.id} (#{run.source}) says :running on #{copy.root}, whose harness is " <>
          "not connected — nothing will ever finish it"
      end

    in_the_loop = Enum.any?(agents, &(&1.continuous and &1.status in [:starting, :running]))

    unwatched =
      if is_nil(watcher) and in_the_loop do
        [
          "project #{project.name} has agents in the loop and no GraphWatcher — work appearing " <>
            "will not wake anybody until something reads the graph"
        ]
      else
        []
      end

    unreachable ++ stale_runs ++ unwatched
  end
end
