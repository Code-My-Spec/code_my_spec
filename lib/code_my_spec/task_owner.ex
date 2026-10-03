defmodule CodeMySpec.TaskOwner do
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Configurations,
      CodeMySpec.Issues,
      CodeMySpec.Repo,
      CodeMySpec.Sessions,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  # credo:disable-for-next-line ExSlop.Check.Readability.NarratorDoc
  @moduledoc """
  The two things that can hold a task, behind one set of calls.

  A task used to be `embeds_many` on `Session` and nothing else, so it could not
  exist without one — and an agent we run has no session and no way to get one.
  It fires no hooks, so nothing injects a `session_id`; `register_session` is
  not a tool it carries; and its own id was not in its prompt. So it could take
  turns, call tools, and never claim a piece of work. It said so itself: *"this
  session must be registered before a task can start, but `register_session` is
  not available in the provided tools."*

  John: *"we shouldn't need a session to create tasks, dude. You should be
  keying the tasks to the agent."*

  So an `Agent` holds its own, and this is the seam that keeps that from
  becoming two of everything. `Hooks.Stop` serves external agents and passes a
  `Session`; `Agents.StopDecision` serves the ones we run and passes an `Agent`;
  neither knows about the other's storage.

  ## Ownership is the list, not a field

  A task is in exactly one of them because it is stored in one row, so nothing
  needs a constraint to say who owns it, and `Task.agent_id` stays what it
  always was — the Claude Code sub-agent a *session's* task was assigned to,
  a question that does not arise for an agent we run because we do not spawn
  sub-agents.

  ## Why not a table yet

  Because nothing yet asks a question that names no owner. "What is every agent
  doing" names them — ten agents, ten short lists. What the embedded form cannot
  do is *cross-owner* work: every active task on a requirement, or what
  completed this week, both of which mean scanning jsonb across every row. That
  is the trigger to promote it, and when it comes this module is where the
  change lands rather than in fifteen call sites.
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Sessions.Task
  alias CodeMySpec.Users.Scope
  alias Ecto.Adapters.SQL

  import Ecto.Query, only: [from: 2]

  @type t :: Session.t() | Agent.t()
  @type blocker_type :: :issue | :question | :tap_out
  @type outcome ::
          :resolved | :dismissed | :answered | :denied | :approved | :withdrawn | :below_threshold

  @resolvable [:issue, :question, :tap_out]
  @outcomes [:resolved, :dismissed, :answered, :denied, :approved, :withdrawn, :below_threshold]

  @doc "Every task this owner holds."
  @spec tasks(t()) :: [Task.t()]
  def tasks(%Session{tasks: tasks}), do: tasks || []
  def tasks(%Agent{tasks: tasks}), do: tasks || []

  @doc "The task this owner is working, if any."
  @spec active_task(t()) :: Task.t() | nil
  def active_task(owner), do: Enum.find(tasks(owner), &(&1.status == :active))

  @doc "One task by id."
  @spec find_task(t(), String.t()) :: Task.t() | nil
  def find_task(owner, task_id), do: Enum.find(tasks(owner), &(&1.id == task_id))

  @doc "Blocked attempts, including resolved blockers awaiting explicit resumption."
  @spec blocked_tasks(t()) :: [Task.t()]
  def blocked_tasks(owner), do: Enum.filter(tasks(owner), &(&1.status == :blocked))

  # Consecutive *identical* feedback is what the count means — a different
  # message is a different failure and starts over. See criterion 1502.
  defp feedback_count(%Task{evaluation_feedback: same} = task, same),
    do: task.evaluation_feedback_count + 1

  defp feedback_count(%Task{}, _different), do: 1

  @doc "Record feedback on one attempt, counting consecutive identical failures."
  def record_task_feedback(scope, owner, task_id, feedback) when is_binary(feedback) do
    locked_update(scope, owner, fn current ->
      case find_task(current, task_id) do
        %Task{status: :active} = task ->
          update_embedded_task(current, task_id, %{
            evaluation_feedback: feedback,
            evaluation_feedback_count: feedback_count(task, feedback)
          })

        nil ->
          {:error, :task_not_found}

        _ ->
          {:error, :task_not_active}
      end
    end)
  end

  @doc "Clear evaluation feedback for only the named attempt."
  def clear_task_feedback(scope, owner, task_id) do
    locked_update(scope, owner, fn current ->
      case find_task(current, task_id) do
        nil ->
          {:error, :task_not_found}

        _ ->
          update_embedded_task(current, task_id, %{
            evaluation_feedback: nil,
            evaluation_feedback_count: 0
          })
      end
    end)
  end

  @doc "Block an active task while retaining its identity, ownership and continuous policy."
  @spec block_task(Scope.t(), t(), String.t(), atom(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def block_task(scope, owner, task_id, type, blocker_id, opts \\ [])
      when type in [:question, :tap_out, :manual, :issue] and is_binary(blocker_id) and
             blocker_id != "" do
    locked_update(scope, owner, fn current ->
      case find_task(current, task_id) do
        %Task{status: :active} ->
          update_embedded_task(current, task_id, %{
            status: :blocked,
            blocked_at: now(),
            blocker_type: type,
            blocker_id: blocker_id,
            blocker_resolved_at: nil,
            blocked_reason: Keyword.get(opts, :reason)
          })

        nil ->
          {:error, :task_not_found}

        _ ->
          {:error, :task_not_active}
      end
    end)
  end

  @doc """
  Release every task waiting on a blocker that has just been resolved, and wake
  each agent holding one to resume it.

  The one path for every blocker a person or another role clears: an issue
  resolved or dismissed, a question answered, a tap-out denied, dismissed or
  approved. It was issues only (545653ad). An answered question or a denied
  tap-out released one task on the asking agent and woke it with the generic
  work prompt, which named nothing to resume — metric_flow's coder 965c52a9
  answered "Same nudge, no new information" and went idle holding eight
  resolved blocks (2200f9e4).

  Released means `blocker_resolved_at` is set. The task stays `:blocked` until
  its holder resumes it with `start_task`, so nothing is reactivated or
  cancelled here. Waiters are found by the blocker's id on every owner, agents
  and sessions alike, not by the resolver's scope: whoever answered (a person,
  the main agent, another project's issue page) need not hold the task. Only
  an agent can be woken, and an approved tap-out wakes nobody — its holder
  asked to leave and was told yes.

  `:detail` is appended to the wake notice, for what the resolver said.
  Answers the count released, so a caller can tell whether anything waited.
  """
  @spec blocker_resolved(blocker_type(), String.t(), outcome(), keyword()) ::
          {:ok, non_neg_integer()}
  def blocker_resolved(type, blocker_id, outcome, opts \\ [])
      when type in @resolvable and is_binary(blocker_id) and outcome in @outcomes do
    released =
      [Agent, Session]
      |> Enum.flat_map(&Repo.all(waiting_on(&1, type, blocker_id)))
      |> Enum.map(&release_waiters(&1, {type, blocker_id, outcome}, opts))
      |> Enum.sum()

    {:ok, released}
  end

  @doc """
  Release what waited on an issue that has just been resolved or dismissed.

  Every door that closes an issue calls this — the tools, the issue page and
  the REST API — so a block clears however its issue was closed. It is how QA
  waits on the bug it filed instead of tapping out to a person (story 1053).
  """
  @spec issue_closed(Scope.t(), %{id: String.t(), status: atom()}) :: {:ok, non_neg_integer()}
  def issue_closed(%Scope{}, %{id: id, status: status})
      when status in [:resolved, :dismissed],
      do: blocker_resolved(:issue, id, status)

  @doc """
  Release what waited on an issue now below the project's fix threshold.

  Nothing offers a fix below it, so the wait could never end. Finishing on its
  own findings is the holder's call; this only frees it to.
  """
  @spec issue_below_threshold(String.t(), atom()) :: {:ok, non_neg_integer()}
  def issue_below_threshold(id, threshold) when is_binary(id) do
    blocker_resolved(:issue, id, :below_threshold,
      detail:
        "No fix will be offered below #{threshold}; the issue stays recorded. " <>
          "Finish the attempt on your own findings."
    )
  end

  @doc """
  Update the project's configuration, freeing what waited on an issue the new
  fix threshold leaves below it.

  Here rather than in `Configurations.update/2`: Configurations is a leaf that
  `Agents` reaches through `Requirements` and `MainAgent`, so it cannot call
  back into this module without a cycle. Any write that can change
  `fix_issues_min_severity` goes through this.
  """
  @spec update_configuration(Scope.t(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def update_configuration(%Scope{} = scope, attrs) do
    before = Configurations.fix_issues_min_severity(scope)

    with {:ok, config} <- Configurations.update(scope, attrs) do
      if config.fix_issues_min_severity != before,
        do: release_below_threshold(scope, config.fix_issues_min_severity)

      {:ok, config}
    end
  end

  # Open issues only: a closed one already released its waiters, and calling
  # it "below threshold" would be wrong.
  defp release_below_threshold(scope, threshold) do
    scope
    |> waited_issue_ids()
    |> Enum.map(&Issues.get_issue(scope, &1))
    |> Enum.filter(fn issue ->
      (issue && issue.status in [:incoming, :accepted]) and not Issue.blocking?(issue, threshold)
    end)
    |> Enum.each(&issue_below_threshold(&1.id, threshold))
  end

  defp waited_issue_ids(%Scope{active_project_id: project_id}) do
    [Agent, Session]
    |> Enum.flat_map(fn module ->
      Repo.all(
        from row in module,
          where: row.project_id == ^project_id,
          select:
            fragment(
              "(select array_agg(t->>'blocker_id') from unnest(?) t where t->>'blocker_type' = 'issue' and t->>'status' = 'blocked' and t->>'blocker_resolved_at' is null)",
              row.tasks
            )
      )
    end)
    |> Enum.flat_map(&(&1 || []))
    |> Enum.uniq()
  end

  defp waiting_on(module, type, blocker_id) do
    from row in module,
      where:
        fragment(
          "exists (select 1 from unnest(?) t where t->>'blocker_id' = ? and t->>'blocker_type' = ? and t->>'status' = 'blocked' and t->>'blocker_resolved_at' is null)",
          row.tasks,
          ^blocker_id,
          ^Atom.to_string(type)
        )
  end

  defp release_waiters(owner, {type, id, _outcome} = blocker, opts) do
    scope = owner_scope(owner)

    with {:ok, updated} <- locked_update(scope, owner, &release_waiting(&1, type, id)),
         [_ | _] = released <- released_on(owner, updated, type, id) do
      wake_holder(scope, updated, released, blocker, opts)
      length(released)
    else
      _ -> 0
    end
  end

  defp owner_scope(owner) do
    %Scope{
      active_account_id: owner.account_id,
      active_project_id: owner.project_id,
      active_working_copy_id: owner.working_copy_id
    }
  end

  defp release_waiting(owner, type, blocker_id) do
    owner
    |> waiting_tasks(type, blocker_id)
    |> Enum.reduce_while({:ok, owner}, fn task, {:ok, current} ->
      case update_embedded_task(current, task.id, %{blocker_resolved_at: now()}) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp waiting_tasks(owner, type, blocker_id) do
    Enum.filter(tasks(owner), fn task ->
      task.status == :blocked and task.blocker_type == type and
        task.blocker_id == blocker_id and is_nil(task.blocker_resolved_at)
    end)
  end

  # Waiting before this call, released after it.
  defp released_on(before, updated, type, blocker_id) do
    ids = before |> waiting_tasks(type, blocker_id) |> MapSet.new(& &1.id)
    Enum.filter(tasks(updated), &(MapSet.member?(ids, &1.id) and &1.blocker_resolved_at != nil))
  end

  # Clearing the block alone leaves the agent eligible and asleep: `Work` wakes
  # on edges, and a blocker resolving elsewhere is not one of them. The notice
  # goes in the turn so the agent answers it rather than reading past it, and
  # names the task because the generic work prompt is one it has already
  # declined. Off this process because the caller may be the channel the wake
  # dispatches through.
  defp wake_holder(_scope, _owner, _released, {:tap_out, _id, :approved}, _opts), do: :ok

  # The asker withdrew it in its own turn, and `withdraw_question` already told
  # it which task to resume.
  defp wake_holder(_scope, _owner, _released, {:question, _id, :withdrawn}, _opts), do: :ok

  # Mid-turn, the answer itself says what to do with the task (`Notifications`):
  # one message, not two.
  defp wake_holder(
         _scope,
         %Agent{turn_started_at: %DateTime{}},
         _released,
         {:question, _id, :answered},
         _opts
       ),
       do: :ok

  # Busy on another task: resuming now would make it a second active one
  # (story 1080). Told, not offered; `Work` offers it back once that task is
  # done.
  defp wake_holder(scope, %Agent{} = agent, released, blocker, opts) do
    detail = Keyword.get(opts, :detail)

    case active_task(agent) do
      nil ->
        Elixir.Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
          Work.wake_released(scope, agent, released, resolved_header(blocker), detail,
            subject: offer_subject(blocker)
          )
        end)

      _active ->
        Work.note_released(agent, deferred_notice(released, blocker, detail))
    end

    :ok
  end

  defp wake_holder(_scope, %Session{}, _released, _blocker, _opts), do: :ok

  # A denied tap-out is its own kind of offer (criterion 1672); anything else
  # releasing a task is an unblocked offer on the task.
  defp offer_subject({:tap_out, id, _outcome}), do: {"tap_out", id}
  defp offer_subject(_blocker), do: nil

  defp resolved_header({type, id, outcome}),
    do: "Your blocker #{type} #{id} #{outcome_phrase(outcome)}"

  defp deferred_notice(released, {type, id, outcome}, detail) do
    with_detail(
      "Your blocker #{type} #{id} #{outcome_phrase(outcome)}. Finish your active task " <>
        "first; #{task_list(released)} is offered back to you once it is done.",
      detail
    )
  end

  defp task_list(released),
    do: Enum.map_join(released, "; ", &"task #{&1.id} (`#{&1.requirement_name}`)")

  defp with_detail(notice, detail) when is_binary(detail) and detail != "",
    do: notice <> "\n\n" <> detail

  defp with_detail(notice, _detail), do: notice

  defp outcome_phrase(:below_threshold), do: "is below the project's fix threshold"
  defp outcome_phrase(outcome), do: "was #{outcome}"

  @doc "Resolve only a matching blocker; never reactivate its task. Replays are no-ops."
  @spec release_block(Scope.t(), t(), String.t()) :: {:ok, t()} | {:error, term()}
  def release_block(scope, owner, blocker_id) when is_binary(blocker_id) do
    locked_update(scope, owner, fn current ->
      case Enum.find(blocked_tasks(current), &(&1.blocker_id == blocker_id)) do
        nil -> {:ok, current}
        task -> resolve_task_block(current, task, blocker_id)
      end
    end)
  end

  @doc "Resolve a request linked to a particular task, ignoring superseded blockers."
  @spec release_block(Scope.t(), t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def release_block(scope, owner, task_id, blocker_id) when is_binary(blocker_id) do
    locked_update(scope, owner, fn current ->
      resolve_task_block(current, find_task(current, task_id), blocker_id)
    end)
  end

  @doc "Resume a resolved blocked attempt after the caller revalidates its graph eligibility."
  @spec resume_task(Scope.t(), t(), String.t()) :: {:ok, t()} | {:error, term()}
  def resume_task(scope, owner, task_id) do
    locked_update(scope, owner, fn current ->
      resume_resolved_task(current, find_task(current, task_id), active_task(current))
    end)
  end

  @doc "Cancel only the attempt still held by the matching tap-out request."
  def cancel_blocked_task(scope, owner, task_id, blocker_id) do
    locked_update(scope, owner, fn current ->
      case find_task(current, task_id) do
        %Task{status: :blocked, blocker_type: :tap_out, blocker_id: ^blocker_id} ->
          update_embedded_task(current, task_id, %{
            status: :cancelled,
            completed_at: now(),
            blocker_resolved_at: now()
          })

        _ ->
          {:ok, current}
      end
    end)
  end

  defp resolve_task_block(
         owner,
         %Task{status: :blocked, blocker_id: id, blocker_resolved_at: nil} = task,
         id
       ) do
    update_embedded_task(owner, task.id, %{blocker_resolved_at: now()})
  end

  defp resolve_task_block(owner, _task, _blocker_id), do: {:ok, owner}

  defp resume_resolved_task(_owner, _task, %Task{}), do: {:error, :active_task_exists}
  defp resume_resolved_task(_owner, nil, nil), do: {:error, :task_not_found}

  defp resume_resolved_task(
         owner,
         %Task{status: :blocked, blocker_resolved_at: %DateTime{}} = task,
         nil
       ) do
    update_embedded_task(owner, task.id, %{
      status: :active,
      blocked_at: nil,
      blocker_type: nil,
      blocker_id: nil,
      blocker_resolved_at: nil,
      blocked_reason: nil
    })
  end

  defp resume_resolved_task(_owner, %Task{status: :blocked}, nil),
    do: {:error, :blocker_unresolved}

  defp resume_resolved_task(_owner, _task, nil), do: {:error, :task_not_blocked}

  defp locked_update(%Scope{} = scope, %module{id: id}, fun) when module in [Agent, Session] do
    Repo.transaction(fn ->
      current =
        Repo.one(
          from row in module,
            where:
              row.id == ^id and row.account_id == ^scope.active_account_id and
                row.project_id == ^scope.active_project_id,
            lock: "FOR UPDATE"
        )

      case current do
        nil -> Repo.rollback(:owner_not_found)
        owner -> finish_update(fun.(owner))
      end
    end)
  end

  defp finish_update({:ok, owner}), do: owner
  defp finish_update({:error, reason}), do: Repo.rollback(reason)

  defp update_embedded_task(%Session{} = owner, id, attrs),
    do: owner |> Session.update_task(id, attrs) |> Repo.update()

  defp update_embedded_task(%Agent{} = owner, id, attrs),
    do: owner |> Agent.update_task(id, attrs) |> Repo.update()

  @doc """
  Add a task and return the owner with it.

  `agent_id` is not set for an agent owner and that is deliberate: the list says
  whose it is, and a field repeating that is one more thing that can disagree
  with the row holding it.
  """
  @spec add_task(Scope.t(), t(), map()) :: {:ok, t()} | {:error, term()}
  def add_task(%Scope{} = scope, owner, attrs) do
    locked_update(scope, owner, fn current ->
      with :ok <- allow_new_task(current, attrs) do
        add_embedded_task(current, attrs)
      end
    end)
  end

  defp allow_new_task(%Agent{} = owner, %{status: status} = attrs)
       when status in [:active, "active"] do
    with :ok <- allow_activation(owner, nil) do
      allow_requirement_claim(owner, attrs)
    end
  end

  defp allow_new_task(_owner, _attrs), do: :ok

  defp allow_requirement_claim(owner, %{requirement_name: name} = attrs) when is_binary(name) do
    if Enum.any?([:component_id, :story_id, :project_id], &Map.get(attrs, &1)) do
      check_requirement_claim(owner, attrs)
    else
      :ok
    end
  end

  defp allow_requirement_claim(_owner, _attrs), do: :ok

  defp check_requirement_claim(owner, attrs) do
    SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "agent-task-claims:#{owner.project_id}:#{owner.working_copy_id}"
    ])

    others = Repo.all(agents_sharing_this_copy(owner))

    claimed? = others |> Enum.flat_map(&tasks/1) |> Enum.any?(&holds_requirement?(&1, attrs))

    if claimed?, do: {:error, :task_owned_by_another_agent}, else: :ok
  end

  # An agent with no working copy is not on every checkout — it is on none.
  #
  # `agent.working_copy_id == ^nil` is not a comparison Ecto will build: it
  # raises `ArgumentError` ("comparing with nil is forbidden, use is_nil/1"),
  # which escaped `start_task` as `Tool execution crashed` rather than as an
  # ordinary refusal. Every product-role agent on the QA fixture project has a
  # null copy, so claiming the one requirement actionable there crashed all of
  # them, and story 896's whole task-claim family was unreachable behind it.
  # Found live by QA on 2026-09-20.
  #
  # Nil matches nil, which is the right scoping rather than a way round the
  # error: the claim check asks who else could be working the same tree, and
  # two agents that name no tree are as much each other's neighbours as two
  # that name the same one.
  defp agents_sharing_this_copy(%{working_copy_id: nil} = owner) do
    from agent in Agent,
      where:
        agent.project_id == ^owner.project_id and agent.account_id == ^owner.account_id and
          is_nil(agent.working_copy_id) and agent.id != ^owner.id
  end

  defp agents_sharing_this_copy(owner) do
    from agent in Agent,
      where:
        agent.project_id == ^owner.project_id and agent.account_id == ^owner.account_id and
          agent.working_copy_id == ^owner.working_copy_id and agent.id != ^owner.id
  end

  defp holds_requirement?(task, attrs) do
    task.status in [:active, :blocked] and
      Enum.all?([:requirement_name, :component_id, :story_id, :project_id], fn key ->
        Map.get(task, key) == Map.get(attrs, key)
      end)
  end

  defp allow_activation(%Agent{} = owner, task_id) do
    case active_task(owner) do
      nil -> :ok
      %Task{id: ^task_id} -> :ok
      task -> {:error, {:active_task_exists, task.id}}
    end
  end

  defp allow_activation(%Session{}, _task_id), do: :ok

  defp add_embedded_task(%Session{} = session, attrs) do
    session |> Session.add_task(attrs) |> Repo.update()
  end

  defp add_embedded_task(%Agent{} = agent, attrs) do
    agent |> Agent.add_task(Map.delete(attrs, :agent_id)) |> Repo.update()
  end

  @doc "Mark a task active, and note which agent is on it where that matters."
  @spec activate_task(Scope.t(), t(), String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def activate_task(scope, owner, task_id, agent_id \\ nil)

  def activate_task(%Scope{} = scope, owner, task_id, agent_id) do
    locked_update(scope, owner, fn current ->
      case find_task(current, task_id) do
        %Task{status: :blocked} ->
          {:error, :task_blocked}

        nil ->
          {:error, :task_not_found}

        _ ->
          with :ok <- allow_activation(current, task_id) do
            update_embedded_task(current, task_id, activation_attrs(current, agent_id))
          end
      end
    end)
  end

  @doc "Close a task out."
  @spec complete_task(Scope.t(), t(), String.t(), atom()) ::
          {:ok, t()} | {:error, term()}
  def complete_task(scope, owner, task_id, result \\ :completed)

  def complete_task(%Scope{} = scope, owner, task_id, result) do
    locked_update(scope, owner, fn current ->
      update_embedded_task(current, task_id, %{status: result, completed_at: now()})
    end)
  end

  defp activation_attrs(%Session{}, agent_id) do
    %{status: :active, started_at: now()} |> maybe_put_agent(agent_id)
  end

  defp activation_attrs(%Agent{}, _agent_id), do: %{status: :active, started_at: now()}

  defp maybe_put_agent(updates, nil), do: updates
  defp maybe_put_agent(updates, agent_id), do: Map.put(updates, :agent_id, agent_id)

  defp now, do: DateTime.utc_now()
end
