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

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Users,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

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
  Whether the agents on a project are actually working.

  `report/1` answers what the database and the runtime each believe. This
  answers a different question and it is the one that matters when a fleet looks
  busy and is not: are they *acting*.

  Six things, because these are the six I reached for by hand every ten minutes
  for a day and got wrong twice by reading the easy one:

    * `tool_calls` and `files_changed` — the only two numbers that mean work.
      Message counts do not: on 2026-09-08 a fleet produced 1,847 messages and 4
      tool calls in six hours, and I reported it as healthy more than once
      because the transcripts were moving.
    * `empty_turns` — turns that finished with nothing. A high ratio against
      `spoke` is an agent talking to itself.
    * `provider_errors` — the failures that look like an agent choosing not to
      act: a rejected tool call, an expired credential, an exhausted quota.
      Every one of those cost hours to find because it read as reticence.
    * `actionable` per role — what the graph offers *this* agent where it
      stands. Harness-scoped, because that is the scope an agent computes in and
      the unscoped answer is a different, more optimistic number.
    * `gating_issues` — what holds `issues_resolved`, by scope, so "blocked on
      somebody else's repository" is visible rather than inferred.

  Windowed, because a cumulative count cannot distinguish an agent that worked
  this morning from one working now.
  """
  @spec fleet(Ecto.UUID.t(), pos_integer()) :: map()
  def fleet(project_id, minutes \\ 15) when is_binary(project_id) do
    since = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.to_naive()

    project = Repo.get!(Project, project_id)

    agents =
      [project_id: project.id]
      |> AgentsRepository.list_every_agent()
      |> Enum.reject(&(&1.status == :stopped))

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
      status: agent.status,
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

  # One pass. Four separate counts was four table scans of the same rows, and
  # the point of this is to be cheap enough to call every ten minutes.
  defp message_counts(agent_id, since) do
    query =
      from(m in "conversation_messages",
        join: c in "conversations",
        on: c.id == m.conversation_id,
        where: c.agent_id == type(^agent_id, Ecto.UUID) and m.inserted_at > ^since,
        select: %{
          # The `tool_calls` column, not `role == "tool"`.
          #
          # `add_tool_call/5` stores a call as `role: :assistant, content: [],
          # tool_calls: [...]` — `content: []` is right there, because a tool
          # call has no prose. `role == "tool"` is the tool *result*, and only
          # a failed one gets a row at all.
          #
          # So this counted a working agent's calls as zero and its `content:
          # []` rows as empty turns. Measured 2026-09-09: 96 tool calls in
          # twenty minutes reported as `tools=0 empty=96`, and I read the agent
          # as idle for most of a night on the strength of it. I built this view
          # so message counts could not mislead me and then wrote two counters
          # that misled me the same way.
          tools:
            filter(
              count(m.id),
              not is_nil(m.tool_calls) and fragment("? <> '[]'::jsonb", m.tool_calls)
            ),
          tool_results: filter(count(m.id), m.role == "tool"),
          spoke:
            filter(count(m.id), m.role == "assistant" and fragment("?::text <> '[]'", m.content)),
          # Prose-less and call-less: a turn that genuinely produced nothing.
          empty:
            filter(
              count(m.id),
              m.role == "assistant" and fragment("?::text = '[]'", m.content) and
                (is_nil(m.tool_calls) or fragment("? = '[]'::jsonb", m.tool_calls))
            ),
          errors:
            filter(
              count(m.id),
              fragment(
                "?::text ~* '(arguments|exec failed|usage limit|token .*expired|could not be refreshed)'",
                m.content
              )
            ),
          last: max(m.inserted_at)
        }
      )

    Repo.one(query) ||
      %{tools: 0, tool_results: 0, spoke: 0, empty: 0, errors: 0, last: nil}
  end

  defp active_task_name(agent) do
    case CodeMySpec.Agents.Agent.active_task(agent) do
      nil -> nil
      task -> task.requirement_name
    end
  end

  # In the agent's own scope. An agent computes the graph where it stands, and
  # the project-wide answer is a different number — 12 against 0 on Broken
  # Oaths, because the unfinished stories were parked on another working copy.
  defp actionable_for(%{role: role, working_copy_id: copy_id, project_id: project_id})
       when is_binary(copy_id) do
    project = Repo.get(Project, project_id)

    scope = %Scope{
      active_project: project,
      active_project_id: project_id,
      active_account_id: project && project.account_id,
      active_working_copy_id: copy_id
    }

    CodeMySpec.Requirements.actionable_count(scope, role)
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

  `ensure_stale_runs/3` is the same call the stop hook makes, and it answers
  which sources it enqueued and which were already current. That distinction is
  the thing worth having: "nothing happened" and "it was already fresh so
  nothing needed to" are the same silence from outside.
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

    # The remedy, and only a remedy that works.
    #
    # This used to end "until something reads the graph", which is false and was
    # followed. A QA agent read the graph page twice, checked here after each,
    # got `watching: false` both times, then grepped `ensure_watching/1` to be
    # sure rather than shrugging — which is the only reason it became a report
    # (07f42ebf). A cycle went to it, and the same claim had been copied into a
    # seed's documentation from this sentence.
    #
    # Nothing on the read path starts one. `RequirementsLive.provenance/2` calls
    # `status/1`, which is read-only, and `Requirements.cached_all/1` does not
    # ensure one either. The only callers are `watch_active_projects/0` at boot
    # and the two continuous toggles in `agents.ex`.
    #
    # Not fixed by having the read start one, though that was the other option
    # and the reporter leaned toward it. This module is the place that says what
    # the runtime is doing; a diagnostic that changes what it is diagnosing
    # cannot be trusted to describe it. And the supervisor's own reasoning runs
    # the other way — watchers are started on demand "rather than one per project
    # at boot: a project nobody is working on needs no watcher", and somebody
    # reading a page is not the project being worked.
    unwatched =
      if is_nil(watcher) and in_the_loop do
        [
          "project #{project.name} has agents in the loop and no GraphWatcher — work " <>
            "appearing will not wake anybody. Reading the graph does not start one and " <>
            "neither does this page: toggle an agent's loop off and on, or restart the " <>
            "server, which seeds a watcher for every project with agents in it."
        ]
      else
        []
      end

    unreachable ++ stale_runs ++ unwatched
  end
end
