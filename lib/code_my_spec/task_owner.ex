defmodule CodeMySpec.TaskOwner do
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents.Agent,
      CodeMySpec.Configurations,
      CodeMySpec.Issues,
      CodeMySpec.Repo,
      CodeMySpec.Sessions,
      CodeMySpec.Users.Scope
    ]

  # credo:disable-for-next-line ExSlop.Check.Readability.NarratorDoc
  @moduledoc """
  The two things that can hold a task, behind one set of calls.

  A `Session` (a Claude Code conversation) and an `Agent` (one we run, which
  has no session) each embed their own tasks. `Hooks.Stop` passes a `Session`;
  `Agents.StopDecision` passes an `Agent`; neither knows the other's storage.

  ## Ownership is the list, not a field

  A task is in exactly one owner's list. `Task.agent_id` means the Claude Code
  sub-agent a session's task was assigned to; it is unused on an agent's task.

  ## Why not a table yet

  Nothing yet asks a question that names no owner. Cross-owner queries (every
  active task on a requirement) would mean scanning jsonb across rows; that is
  the trigger to promote tasks to a table, and the change lands here.

  See knowledge/agents/coordination, "Task ownership".
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Agents.Agent.Task
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

  @doc """
  Record that the owner's open promotion task waits on the queue.

  Called by the MCP `promote` tool after `PromotionQueue` answers `:queued`,
  naming the subject the candidate was queued for. The wait is written onto the
  task's own row, so `allow_activation/2` reads it without asking the queue.
  Called from the MCP layer because it sits above both `Agents` and
  `PromotionQueue`.

  A no-op when the owner holds no open promotion task: an operator promoting
  from a script has no task to mark, and the queue messages nobody.
  """
  @spec await_promotion(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def await_promotion(%Session{} = owner, _type, _id), do: {:ok, owner}

  def await_promotion(%Agent{} = owner, subject_type, subject_id)
      when is_binary(subject_type) and is_binary(subject_id) do
    case Enum.find(tasks(owner), &promotion_task?/1) do
      nil ->
        {:ok, owner}

      %Task{id: id} ->
        owner
        |> Agent.update_task(id, %{
          awaiting_subject_type: subject_type,
          awaiting_subject_id: subject_id
        })
        |> Repo.update()
    end
  end

  # The tasks whose open state is the queue's, not the agent's.
  # Kept here rather than read from `Agents.Work`, which holds the same list:
  # `TaskOwner` sits below `Agents`, so the read would close the cycle.
  @promotion_tasks ~w(promote_issue story_promoted)

  defp promotion_task?(%Task{status: :active, requirement_name: name}),
    do: name in @promotion_tasks

  defp promotion_task?(_task), do: false

  @doc "Blocked attempts, including resolved blockers awaiting explicit resumption."
  @spec blocked_tasks(t()) :: [Task.t()]
  def blocked_tasks(owner), do: Enum.filter(tasks(owner), &(&1.status == :blocked))

  # Consecutive *identical* feedback is what the count means — a different
  # message is a different failure and starts over.
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

  @doc "Record what a story QA task is reviewing (`Qa.StoryReviews.capture/3`)."
  def record_review(scope, owner, task_id, review) when is_map(review) do
    locked_update(scope, owner, fn current ->
      case find_task(current, task_id) do
        nil ->
          {:error, :task_not_found}

        _ ->
          update_embedded_task(current, task_id, %{
            review_commit: review.commit,
            review_certified_at: review.certified_at,
            review_submissions: review.submissions,
            review_started_at: review.started_at
          })
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

  @doc """
  Block a task while retaining its identity, ownership and continuous policy.

  An `:active` task is the ordinary case: it becomes `:blocked` on the new
  blocker.

  A task that is already `:blocked` is accepted too: it now waits on the new
  blocker, so deciding that one frees exactly this task (otherwise only
  `cancel_task` could reach it). `blocker_resolved_at` is cleared — a task
  waiting again is not one whose blocker is answered.
  """
  @spec block_task(Scope.t(), t(), String.t(), atom(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def block_task(scope, owner, task_id, type, blocker_id, opts \\ [])
      when type in [:question, :tap_out, :manual, :issue] and is_binary(blocker_id) and
             blocker_id != "" do
    locked_update(scope, owner, fn current ->
      case find_task(current, task_id) do
        %Task{status: status} = task when status in [:active, :blocked] ->
          update_embedded_task(current, task_id, %{
            status: :blocked,
            # The first block's time is kept: it is when this task stopped being
            # worked, and re-blocking does not restart that clock.
            blocked_at: task.blocked_at || now(),
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
  resolved or dismissed, a question answered or withdrawn, a tap-out denied,
  dismissed or approved. The wake names the released task; a generic work
  prompt names nothing to resume.

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
  waits on the bug it filed instead of tapping out to a person.
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

  Here rather than in `Configurations.update/2`: Configurations is a leaf below
  this module and cannot call back into it. Any write that can change
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
        from(row in module,
          where: row.project_id == ^project_id,
          select:
            fragment(
              "(select array_agg(t->>'blocker_id') from unnest(?) t where t->>'blocker_type' = 'issue' and t->>'status' = 'blocked' and t->>'blocker_resolved_at' is null)",
              row.tasks
            )
        )
      )
    end)
    |> Enum.flat_map(&(&1 || []))
    |> Enum.uniq()
  end

  defp waiting_on(module, type, blocker_id) do
    from(row in module,
      where:
        fragment(
          "exists (select 1 from unnest(?) t where t->>'blocker_id' = ? and t->>'blocker_type' = ? and t->>'status' = 'blocked' and t->>'blocker_resolved_at' is null)",
          row.tasks,
          ^blocker_id,
          ^Atom.to_string(type)
        )
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

  # Busy on another task: resuming now would make it a second active one.
  # Told, not offered; `Work` offers it back once that task is done.
  defp wake_holder(scope, %Agent{} = agent, released, {_type, _id, outcome} = blocker, opts) do
    detail = Keyword.get(opts, :detail)

    # Agents answers this (`Agents.Events`); TaskOwner sits below Agents.
    meta =
      case active_task(agent) do
        nil ->
          %{
            scope: scope,
            agent: agent,
            released: released,
            header: resolved_header(blocker),
            detail: detail,
            subject: offer_subject(blocker),
            # 6f2d593e: only the immediate resume wording turns this into a
            # flat command (`Work.resume_ready/4`); the deferred "offered
            # back once you're done" notice is already a heads-up, not an
            # order, so it does not need the outcome.
            outcome: outcome
          }

        _active ->
          %{agent: agent, deferred: deferred_notice(released, blocker, detail)}
      end

    :telemetry.execute([:code_my_spec, :tasks, :released], %{}, meta)
  end

  defp wake_holder(_scope, %Session{}, _released, _blocker, _opts), do: :ok

  # A denied tap-out is its own kind of offer; anything else
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
          from(row in module,
            where:
              row.id == ^id and row.account_id == ^scope.active_account_id and
                row.project_id == ^scope.active_project_id,
            lock: "FOR UPDATE"
          )
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

  `agent_id` is not set for an agent owner: the list says whose it is.
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

  # Nil matches nil (Ecto refuses `== ^nil`): two agents that name no tree are
  # each other's neighbours, as two that name the same one are.
  defp agents_sharing_this_copy(%{working_copy_id: nil} = owner) do
    from(agent in Agent,
      where:
        agent.project_id == ^owner.project_id and agent.account_id == ^owner.account_id and
          is_nil(agent.working_copy_id) and agent.id != ^owner.id
    )
  end

  defp agents_sharing_this_copy(owner) do
    from(agent in Agent,
      where:
        agent.project_id == ^owner.project_id and agent.account_id == ^owner.account_id and
          agent.working_copy_id == ^owner.working_copy_id and agent.id != ^owner.id
    )
  end

  defp holds_requirement?(task, attrs) do
    task.status in [:active, :blocked] and
      Enum.all?([:requirement_name, :component_id, :story_id, :issue_id, :project_id], fn key ->
        Map.get(task, key) == Map.get(attrs, key)
      end)
  end

  defp allow_activation(%Agent{} = owner, task_id) do
    case active_task(owner) do
      nil -> :ok
      %Task{id: ^task_id} -> :ok
      task -> if awaiting_landing?(task), do: :ok, else: {:error, {:active_task_exists, task.id}}
    end
  end

  defp allow_activation(%Session{}, _task_id), do: :ok

  # A promotion task that waits on the queue does not hold the one-task slot:
  # it stays open until its batch lands or is ejected, without parking the
  # agent. The signal is the task's own row, written by `await_promotion/3`.
  defp awaiting_landing?(%Task{awaiting_subject_id: id}) when is_binary(id), do: true
  defp awaiting_landing?(_task), do: false

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
          activate_if_allowed(current, task_id, agent_id)
      end
    end)
  end

  defp activate_if_allowed(current, task_id, agent_id) do
    with :ok <- allow_activation(current, task_id) do
      update_embedded_task(current, task_id, activation_attrs(current, agent_id))
    end
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
