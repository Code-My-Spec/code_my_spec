defmodule CodeMySpec.DevState do
  @moduledoc """
  What the database believes, what the runtime is doing, and where they disagree.

  The gaps it names: agents marked running on a copy no harness holds,
  `analysis_runs` claiming `:running` with no harness to finish them, and a
  project with agents in the loop but no graph writer. None is visible from a
  table or from LiveDashboard (processes, not whether *this* copy has an
  executor).

  `disagreements` is the point; the rest is evidence for it. An empty list is
  the answer worth having.

  Here rather than in the controller because `CodeMySpecWeb` may not reach
  `CodeMySpec.Repo`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Agents.Agent,
      CodeMySpec.Analysis,
      CodeMySpec.Analysis.HarnessRegistry,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ]

  import Ecto.Query

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Presence
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.IncrementalGraph
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
  Whether the agents on a project are actually working.

  `report/1` answers what the database and the runtime each believe; this
  answers whether a busy-looking fleet is *acting*:

    * `tool_calls` and `files_changed` — the only numbers that mean work;
      message counts do not.
    * `empty_turns` — turns that finished with nothing. A high ratio against
      `spoke` is an agent talking to itself.
    * `provider_errors` — failures that read as an agent choosing not to act:
      a rejected tool call, an expired credential, an exhausted quota.
    * `actionable` per agent — what the graph offers it at its own working
      copy; the project-wide number is a different, more optimistic one.
    * `gating_issues` — accepted medium-and-up issues, by scope, so "blocked on
      somebody else's repository" is visible.

  Windowed, so an agent that worked this morning is told apart from one
  working now.
  """
  @spec fleet(Ecto.UUID.t(), pos_integer()) :: map()
  def fleet(project_id, minutes \\ 15) when is_binary(project_id) do
    since = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.to_naive()

    project = Repo.get!(Project, project_id)

    agents =
      [project_id: project.id]
      |> AgentsRepository.list_every_agent()
      |> Enum.filter(&Agents.on_duty?/1)

    %{
      project: project.name,
      window_minutes: minutes,
      agents: Enum.map(agents, &agent_activity(&1, since)),
      gating_issues: gating_issues(project_id),
      files_changed: Enum.map(agents, & &1.working_copy) |> Enum.uniq() |> files_changed(minutes)
    }
  end

  defp agent_activity(agent, since) do
    counts = message_counts(agent.id, since)

    %{
      id: agent.id,
      role: agent.role,
      status: lifecycle(agent),
      provider: agent.provider,
      model: agent.model,
      continuous: agent.continuous,
      tool_calls: counts.tools,
      tool_results: counts.tool_results,
      spoke: counts.spoke,
      empty_turns: counts.empty,
      provider_errors: counts.errors,
      last_message: counts.last,
      active_task: active_task_name(agent),
      actionable: actionable_for(agent)
    }
  end

  @error_text ~r/(arguments|exec failed|usage limit|token .*expired|could not be refreshed)/i

  # One pass over the rows, cheap enough to call every few minutes.
  defp message_counts(agent_id, since) do
    rows =
      from(m in "conversation_messages",
        join: c in "conversations",
        on: c.id == m.conversation_id,
        where: c.agent_id == type(^agent_id, Ecto.UUID) and m.inserted_at > ^since,
        select: %{
          role: m.role,
          content: type(m.content, {:array, :map}),
          tool_calls: type(m.tool_calls, {:array, :map}),
          inserted_at: m.inserted_at
        }
      )
      |> Repo.all()

    # The `tool_calls` column, not `role == "tool"`: a call is stored as
    # `role: :assistant, content: [], tool_calls: [...]`, and `role == "tool"`
    # is a result row, written only for failures.
    %{
      tools: Enum.count(rows, &(&1.tool_calls not in [nil, []])),
      tool_results: Enum.count(rows, &(&1.role == "tool")),
      spoke: Enum.count(rows, &(&1.role == "assistant" and &1.content != [])),
      # Prose-less and call-less: a turn that genuinely produced nothing.
      empty:
        Enum.count(
          rows,
          &(&1.role == "assistant" and &1.content == [] and &1.tool_calls in [nil, []])
        ),
      errors: Enum.count(rows, &Regex.match?(@error_text, Jason.encode!(&1.content || []))),
      last: rows |> Enum.map(& &1.inserted_at) |> Enum.max(fn -> nil end)
    }
  end

  defp active_task_name(agent) do
    case CodeMySpec.Agents.Agent.active_task(agent) do
      nil -> nil
      task -> task.requirement_name
    end
  end

  # In the agent's own scope, and through `Work.actionable/3`, so it agrees
  # with what the agent's turn would be offered.
  defp actionable_for(%{role: role, working_copy_id: copy_id, project_id: project_id} = agent)
       when is_binary(copy_id) do
    project = Repo.get(Project, project_id)

    scope = %Scope{
      active_project: project,
      active_project_id: project_id,
      active_account_id: project && project.account_id,
      active_working_copy_id: copy_id
    }

    length(Work.actionable(scope, role, agent))
  rescue
    _ -> nil
  end

  defp actionable_for(_agent), do: nil

  # By scope, because "blocked" and "blocked on something this project is not
  # allowed to touch" are different answers and only one of them is the
  # project's problem.
  defp gating_issues(project_id) do
    from(i in "issues",
      where:
        i.project_id == type(^project_id, Ecto.UUID) and i.status == "accepted" and
          i.severity in ["medium", "high", "critical"],
      group_by: i.scope,
      select: {i.scope, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # What is on disk, which no transcript can fake.
  defp files_changed(roots, minutes) do
    roots
    |> Enum.filter(&(is_binary(&1) and File.dir?(&1)))
    |> Enum.map(fn root ->
      cutoff = System.os_time(:second) - minutes * 60

      count =
        root
        |> Path.join("{lib,test}/**/*.{ex,exs,heex}")
        |> Path.wildcard()
        |> Enum.count(&changed_since?(&1, cutoff))

      %{root: root, changed: count}
    end)
  end

  defp changed_since?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime > cutoff
      _ -> false
    end
  end

  @doc """
  Ask for analyzer runs on one checkout, and say what the queue decided.

  Through `Analysis.ensure_stale_runs/3`, which answers which sources it
  enqueued and which were already current — otherwise the same silence from
  outside.
  """
  @spec request_run(Ecto.UUID.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def request_run(working_copy_id, source) do
    with {:ok, copy} <- fetch_copy(working_copy_id),
         {:ok, sources} <- fetch_sources(source) do
      report =
        Analysis.ensure_stale_runs(scope_for(copy), sources,
          requested_by: %{kind: "manual", via: "dev_state"}
        )

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
    case HarnessRegistry.executor_holder(copy.id) do
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
    projector = IncrementalGraph.status(project.id)
    copy_reports = Enum.map(copies, &copy_report(&1, agents))

    %{
      project_id: project.id,
      name: project.name,
      graph_writer: writer_report(projector),
      graph_projector: watcher_report(projector),
      working_copies: copy_reports,
      disagreements: disagreements(project, projector, agents, copy_reports)
    }
  end

  defp watcher_report(nil), do: %{watching: false}

  defp watcher_report(%{pending: pending, last_recompute: last}),
    do: %{watching: true, recompute_pending: pending, last_recompute: last}

  defp writer_report(nil), do: %{active: false}

  defp writer_report(%{pending: pending, last_recompute: last} = status),
    do: %{
      active: true,
      recompute_pending: pending,
      last_recompute: last,
      last_error: Map.get(status, :last_error)
    }

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
    case HarnessRegistry.executor_holder(copy_id) do
      {:ok, pid, instance} -> %{held: true, pid: inspect(pid), instance: instance}
      :error -> %{held: false}
    end
  end

  # Derived, not stored (`Agents.lifecycle/2`): running while its process is
  # present.
  defp lifecycle(agent), do: Agents.lifecycle(agent, Presence.ids(agent.project_id))

  defp agent(agent) do
    %{
      id: agent.id,
      role: agent.role,
      status: lifecycle(agent),
      continuous: agent.continuous,
      engine: agent.engine
    }
  end

  # Straight off the ledger: the disagreement worth naming is between this list
  # and what is actually running.
  defp claiming_running(copy_id) do
    Run
    |> where([r], r.working_copy_id == ^copy_id and r.status == :running)
    |> select([r], %{id: r.id, source: r.source, started_at: r.started_at})
    |> Repo.all()
  end

  # Each names a gap otherwise found only by reading logs.
  defp disagreements(project, serving_writer, agents, copy_reports) do
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

    # Health follows the writer serving readers. The optional comparison
    # worker remains visible separately without being required for freshness.
    unwatched =
      if is_nil(serving_writer) and in_the_loop do
        [
          "project #{project.name} has agents in the loop and no graph writer — work " <>
            "appearing will not update the graph. Reading a graph that has rows does not " <>
            "start one; restart the server or toggle an agent's loop to start its graph worker."
        ]
      else
        []
      end

    unreachable ++ stale_runs ++ unwatched
  end
end
