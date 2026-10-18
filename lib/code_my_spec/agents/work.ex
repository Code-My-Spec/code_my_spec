defmodule CodeMySpec.Agents.Work do
  @moduledoc "Eligibility and atomic turn admission for existing durable role agents."

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Assignment
  alias CodeMySpec.Agents.IssueAssignment
  alias CodeMySpec.Agents.IssueWork
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Presence
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Agents.Wake
  alias CodeMySpec.Conversations
  alias CodeMySpec.Notifications
  alias CodeMySpec.PromotionQueue.Waits
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  # Names only tools on every agent's direct surface: an agent told to call a
  # tool it does not carry reports the failure and stops.
  # See knowledge/agents, "Offering work".
  @prompt "Eligible work is available. Call get_next_requirement to see it, " <>
            "then claim it with start_task. No task has been selected or assigned for you."

  def consider_project(scope, reason, except_agent_ids \\ []) do
    scope
    |> AgentsRepository.list_agents()
    |> Enum.reject(&(&1.id in except_agent_ids))
    |> Enum.each(&request_turn_if_runnable(scope, &1, reason))

    :ok
  end

  def consider_copy(scope, copy_id, reason, except_agent_id \\ nil) do
    scope
    |> AgentsRepository.list_agents()
    |> Enum.filter(&(&1.working_copy_id == copy_id and &1.id != except_agent_id))
    |> Enum.each(&request_turn_if_runnable(scope, &1, reason))

    :ok
  end

  @resume_prompt "Your last turn ended without finishing — the harness restarted " <>
                   "under it. You still hold the task below. Nothing is wrong with it " <>
                   "and nothing has been decided about it; pick it back up from where " <>
                   "the thread leaves off, and dispose of it as usual when the work is " <>
                   "done. If you cannot tell how far it got, re-check rather than assume."

  @doc """
  Offer a turn to agents left holding a task with no turn open.

  An agent holding a task with no turn open (`turn_started_at` nil, nothing in
  flight) is stranded, not busy: a turn discarded mid-flight — a harness
  restart is the common way — leaves exactly that, and the ordinary offer
  path refuses an agent with an active task. Only agents on `copy_id`.
  """
  def resume_held_tasks(scope, copy_id) do
    scope
    |> AgentsRepository.list_agents()
    |> Enum.filter(&(&1.working_copy_id == copy_id and stranded?(scope, &1)))
    |> Enum.each(&resume(scope, &1))

    :ok
  end

  @doc "Resume only the agent whose process came up; reconnect sweeps remain copy-wide."
  @spec resume_held_task(Scope.t(), Ecto.UUID.t()) :: :ok
  def resume_held_task(%Scope{} = scope, agent_id) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         true <- stranded?(scope, agent) do
      resume(scope, agent)
    end

    :ok
  end

  # A held task with a turn ended to wait is not stranded: whatever it waits on
  # messages it (`Wake`, through `Waiting`).
  defp stranded?(scope, agent) do
    present?(agent) and is_nil(agent.turn_started_at) and
      not Offers.in_flight?(agent.id) and not is_nil(Agent.active_task(agent)) and
      not is_nil(agent.working_copy_id) and Wake.decide(scope, agent, :resume) == :wake
  end

  # Each offer asks `Wake` before it writes the prompt to the transcript, so
  # an off agent's thread never shows a turn it was not given.
  defp resume(scope, agent) do
    with :ok <- Wake.allow?(scope, agent, :resume),
         {:ok, {waking, offered}} <- request_stranded_turn(scope, agent.id) do
      turn_prompt = resume_prompt(waking)
      Offers.link_prompt(offered, Conversations.record_sent_to_agent(waking, turn_prompt))

      case Transport.request_work_turn(
             waking.working_copy_id,
             waking,
             offered.id,
             turn_prompt,
             5_000
           ) do
        {:ok, :started} ->
          {:ok, offered.id}

        _error ->
          Offers.undelivered(offered)
      end
    end
  end

  # The prompt promises "the task below", so the task has to follow.
  defp resume_prompt(agent) do
    task = Agent.active_task(agent)

    @resume_prompt <> "\n\n" <> task_line(task)
  end

  defp task_line(task) do
    "The task: `#{task.requirement_name}`, id #{task.id}. `evaluate_task` with " <>
      "that id when it is done."
  end

  # Same row lock and turn request as `admit_turn/4`, against `stranded?/2` rather
  # than `runnable_state?/3` — two events racing to resume one agent must still
  # hand out a single turn.
  defp request_stranded_turn(scope, id) do
    Repo.transaction(fn ->
      agent =
        Repo.one(
          from(a in Agent,
            where:
              a.id == ^id and a.project_id == ^scope.active_project_id and
                a.account_id == ^scope.active_account_id,
            lock: "FOR UPDATE"
          )
        )

      if agent && stranded?(scope, agent),
        do: request_turn(agent, :resume, {"task", Agent.active_task(agent).id}),
        else: :not_stranded
    end)
  end

  @doc """
  Offer one agent a turn whose prompt opens with `preface`.

  The text is the turn prompt — the input the agent is answering — rather than
  a recorded message, which the agent reads as history and answers past. A
  correction has to be what the agent is answering.

  `event` is what `Wake` is asked about: `:question_answered` for an answer,
  `:blocker_resolved` for a released block or a denied tap-out. `subject` is
  what the offer is recorded against (`Offers`).
  """
  def offer_turn_with(scope, %Agent{} = agent, preface, event, subject \\ {"notice", nil})
      when is_binary(preface) do
    with {:ok, current} <- AgentsRepository.fetch_agent(scope, agent.id),
         :ok <- admit(scope, current, event),
         {:ok, {waking, offered}} <-
           admit_turn(scope, current.id, event, {notice_kind(event, subject), subject}) do
      turn_prompt = turn_prompt(preface, event, waking)
      Offers.link_prompt(offered, Conversations.record_sent_to_agent(waking, turn_prompt))
      hand_turn(waking, offered, turn_prompt)
    else
      hold -> not_admitted(hold)
    end
  end

  # A released or denied task's notice is the whole turn: the generic work
  # prompt beneath "resume task X" would contradict it.
  defp turn_prompt(preface, :blocker_resolved, _agent), do: preface
  defp turn_prompt(preface, _event, agent), do: preface <> "\n\n" <> prompt(agent)

  @doc """
  Tell one agent something in a turn when it can take one, and on its thread
  when it cannot — then offer its copy a turn, so a busy agent still reads the
  notice on its next one.
  """
  def wake_with_notice(scope, %Agent{} = agent, notice, event, subject \\ {"notice", nil})
      when is_binary(notice) do
    case offer_turn_with(scope, agent, notice, event, subject) do
      {:ok, ref} when is_binary(ref) ->
        :ok

      _not_admissible ->
        agent
        |> Conversations.record_sent_to_agent(notice)
        |> Offers.record_or_link(agent, notice_kind(event, subject), subject)

        # Exclude this agent: it was just told directly above, on its own
        # thread. Without the exclusion, `consider_copy` finds this same
        # agent idle with this same released-but-still-blocked task still
        # claimable (`offer/2`'s `released_tasks/2`) and pushes it a second,
        # detail-less turn on the very offer just opened for it.
        if agent.working_copy_id,
          do: consider_copy(scope, agent.working_copy_id, event, agent.id)

        :ok
    end
  end

  @blocker_cycle [:blocker_id, :blocker_type, :blocked_at, :blocker_resolved_at]

  @doc """
  Offer an idle agent back the tasks a resolved blocker released — only those
  its work now includes. `header` says what resolved, `detail` is the
  decider's answer when there is one. `:subject` records the offer on
  something other than the task — a denied tap-out.

  A released task whose requirement still waits on something is not offered:
  "resume it" would send the agent to `start_task` for a task it is refused.
  It is told what the task waits on instead, and `offer/2` offers the task
  once the graph does.
  """
  @spec wake_released(Scope.t(), Agent.t(), [map()], String.t(), String.t() | nil, keyword()) ::
          :ok
  def wake_released(scope, %Agent{} = agent, released, header, detail \\ nil, opts \\ []) do
    {:ok, agent} = AgentsRepository.fetch_agent(scope, agent.id)

    released = Enum.filter(released, &still_released?(agent, &1))

    execution = work_for(scope, agent.role, agent)

    {waiting, ready} = Enum.split_with(released, &still_waiting?(&1, execution))

    if waiting != [],
      do: note_released(agent, with_detail(waiting_notice(header, waiting, execution), detail))

    resume_ready(scope, agent, ready, {header, detail}, opts)
  end

  defp resume_ready(scope, agent, [], _notice, _opts) do
    if agent.working_copy_id,
      do: consider_copy(scope, agent.working_copy_id, :blocker_resolved)

    :ok
  end

  defp resume_ready(scope, agent, [task | _] = ready, {header, detail}, opts) do
    notice = with_detail("#{header}; #{resume_instruction(scope, ready)}", detail)
    subject = Keyword.get(opts, :subject) || {"task", task.id}
    wake_with_notice(scope, agent, notice, :blocker_resolved, subject)
  end

  # Still the release this wake was about: the same blocker cycle, resolved and
  # not since re-blocked.
  defp still_released?(agent, previous) do
    Enum.any?(agent.tasks || [], fn current ->
      current.id == previous.id and current.status == :blocked and
        not is_nil(current.blocker_resolved_at) and
        Map.take(current, @blocker_cycle) == Map.take(previous, @blocker_cycle)
    end)
  end

  # Waiting only on its own story's evidence: the agent's work is that story
  # and the task's node is not in its actionable set. A task the graph cannot
  # place resumes as it always did.
  defp still_waiting?(%{story_id: story_id} = task, %{story: %{id: story_id}} = execution)
       when not is_nil(story_id),
       do: not Enum.any?(execution.actionable, &task_on_node?(task, &1))

  defp still_waiting?(_task, _execution), do: false

  defp waiting_notice(header, waiting, execution) do
    "#{header}, but #{task_list(waiting)} is not ready to resume: it waits on " <>
      "#{waits_on(execution)}. Do not start it yet; it is offered to you when it opens."
  end

  defp waits_on(%{blockers: [_ | _] = blockers}),
    do: Enum.map_join(blockers, "; ", &blocker_phrase/1)

  defp waits_on(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp waits_on(_execution), do: "prerequisites that are not satisfied yet"

  defp blocker_phrase(blocker) do
    [Map.get(blocker, :name), Map.get(blocker, :entity_name)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" on ")
  end

  # The exact call that resumes each task: an id alone sends agents looking for
  # which entity it was on.
  defp resume_instruction(scope, tasks) do
    "resume " <>
      Enum.map_join(tasks, "; ", fn task ->
        case start_args(scope, task) do
          nil ->
            "task #{task.id} only after inspecting its recorded requirement; entity identity is unavailable"

          args ->
            "task #{task.id} with `start_task(#{args})`"
        end
      end) <> "."
  end

  defp start_args(_scope, %{issue_id: issue_id} = task) when is_binary(issue_id),
    do:
      ~s(requirement_name: "#{task.requirement_name}", entity_type: "issue", entity_id: "#{issue_id}")

  defp start_args(scope, %{story_id: story_id} = task) when not is_nil(story_id) do
    number =
      case CodeMySpec.Stories.get_story(scope, story_id) do
        %{number: number} when is_integer(number) -> number
        _ -> story_id
      end

    ~s(requirement_name: "#{task.requirement_name}", entity_type: "story", entity_id: "#{number}")
  end

  defp start_args(_scope, %{component_module_name: module} = task) when is_binary(module),
    do:
      ~s(requirement_name: "#{task.requirement_name}", entity_type: "component", module_name: "#{module}")

  defp start_args(_scope, %{component_id: id} = task) when is_binary(id),
    do:
      ~s(requirement_name: "#{task.requirement_name}", entity_type: "component", entity_id: "#{id}")

  defp start_args(_scope, %{project_id: id} = task) when is_binary(id),
    do:
      ~s(requirement_name: "#{task.requirement_name}", entity_type: "project", entity_id: "#{id}")

  defp start_args(_scope, _task), do: nil

  defp task_list(tasks),
    do: Enum.map_join(tasks, "; ", &"task #{&1.id} (`#{&1.requirement_name}`)")

  defp with_detail(notice, detail) when is_binary(detail) and detail != "",
    do: notice <> "\n\n" <> detail

  defp with_detail(notice, _detail), do: notice

  @doc """
  Tell an agent holding an active task that a blocked one was released, without
  offering it: resuming would make it a second active task.
  `offer/2` offers it back once the agent holds none.
  """
  @spec note_released(Agent.t(), String.t()) :: :ok
  def note_released(%Agent{} = agent, notice) when is_binary(notice) do
    Conversations.record_sent_to_agent(agent, notice)
    :ok
  end

  @doc "The offer kind a notice carried under `event` on `subject` is recorded as."
  def notice_kind(:question_answered, _subject), do: :answer
  def notice_kind(_event, {"tap_out", _id}), do: :denial
  def notice_kind(_event, _subject), do: :unblocked

  @doc """
  Offer `agent` a work turn if it is idle and `Wake` allows `event` — a
  `:work_offer`, or main's `:teammate_question` — and there is work it has not
  just declined. `reason` is why it is being asked, for the log.
  """
  def request_turn_if_runnable(scope, %Agent{} = agent, _reason, event \\ :work_offer) do
    with {:ok, current} <- AgentsRepository.fetch_agent(scope, agent.id),
         :ok <- admit(scope, current, event),
         {:work, offer, subject} <- offer(scope, current),
         false <- already_declined?(current, offer, questions_only?(subject)),
         {:ok, {waking, offered}} <-
           admit_turn(scope, current.id, event, {offer_kind(subject), subject}),
         :ok <- still_offered(scope, waking, offered, subject) do
      turn_prompt = offer_prompt(scope, waking, subject, offered)

      # Recorded first, then sent: the transport is called directly, and a turn
      # with nothing on the transcript saying why reads as an agent starting
      # out of nowhere. Routing is measured off these rows.
      Offers.link_prompt(offered, Conversations.record_sent_to_agent(waking, turn_prompt))
      hand_turn(waking, offered, turn_prompt)
    else
      :none -> {:ok, :not_runnable}
      :stale -> {:ok, :not_runnable}
      true -> {:ok, :offer_declined}
      hold -> not_admitted(hold)
    end
  end

  # The offer was decided from a read taken before the turn request, and the
  # agent can move in between. Holding the request, nothing else can offer this
  # agent a turn, so recomputing here is the answer as of now; a subject no
  # longer offered withdraws the request.
  defp still_offered(scope, waking, offered, subject) do
    case offer(scope, waking) do
      {:work, _offer, ^subject} ->
        :ok

      _moved ->
        Offers.withdraw(offered)
        :stale
    end
  end

  @doc """
  The main agent's check-in turn only for actionable work or observed attention.

  `render` builds the prompt from whether main's work offer stands — eligible
  graph work it has not declined past the damper. Admitted as `:cadence`, so
  only a running, continuous, idle main that is not waiting gets it; mid-turn
  it is skipped, not queued — the next tick comes round.
  """
  def request_cadence_turn(scope, %Agent{} = agent, render, opts \\ [])
      when is_function(render, 1) do
    with {:ok, current} <- AgentsRepository.fetch_agent(scope, agent.id),
         :ok <- admit(scope, current, :cadence),
         true <- Keyword.get(opts, :attention?, false) or work_offered?(scope, current),
         {:ok, {waking, offered}} <-
           admit_turn(scope, current.id, :cadence, {:check_in, {"cadence", nil}}) do
      turn_prompt = render.(work_offered?(scope, waking))
      Offers.link_prompt(offered, Conversations.record_sent_to_agent(waking, turn_prompt))
      hand_turn(waking, offered, turn_prompt)
    else
      false -> {:ok, :no_work}
      hold -> not_admitted(hold)
    end
  end

  # Graph work only: questions reach the check-in through the digest.
  defp work_offered?(scope, agent) do
    nodes = graph_work(scope, agent)

    nodes != [] and
      not already_declined?(agent, fingerprint(held_questions(scope, agent), nodes), false)
  end

  # An off or retired agent answers as the gate always has; any other hold is
  # simply not runnable.
  defp not_admitted({:hold, _reason} = hold) do
    case Wake.to_error(hold) do
      {:error, {stood_down, _agent}} = error when stood_down in [:off, :retired] -> error
      _held -> {:ok, :not_runnable}
    end
  end

  defp not_admitted({:ok, :not_runnable} = result), do: result
  defp not_admitted(error), do: error

  @doc """
  Record that this agent ended a turn without taking the work it was offered.

  Called from the turn-ended path, the only place that knows a turn finished
  with nothing claimed. Without it every runnable condition holds again the
  instant the turn ends, and the next observation re-offers the same work —
  an agent can spin at a turn a second.

  See knowledge/agents, "The decline damper".

  An agent that *did* claim something has not declined anything, so its mark is
  cleared — the next offer after a completed task is a genuinely new one.
  """
  def record_decline(scope, %Agent{} = agent, turn_started_at \\ nil) do
    AgentsRepository.update_agent(scope, agent, decline_attrs(scope, agent, turn_started_at))
  end

  # One more repeat of the same offer, or the start of a new streak.
  defp streak(%{declined_offer: same, declined_offer_count: n}, same) when is_integer(n),
    do: %{
      declined_offer: same,
      declined_offer_at: DateTime.utc_now(),
      declined_offer_count: n + 1
    }

  defp streak(_agent, fingerprint),
    do: %{
      declined_offer: fingerprint,
      declined_offer_at: DateTime.utc_now(),
      declined_offer_count: 1
    }

  # Only questions-only offers are damped here. Graph work is escalated by the
  # ladder in `Offers` and then held back from this agent alone.
  defp decline_attrs(scope, agent, turn_started_at) do
    if declined?(scope, agent, turn_started_at) do
      case offer(scope, agent) do
        {:work, fingerprint, {"questions", nil}} -> streak(agent, fingerprint)
        _graph_work_or_none -> cleared()
      end
    else
      cleared()
    end
  end

  # A turn that did nothing. Holding a task is work; so is a task closed during
  # the turn (else every completion would damp the next offer); so is a turn
  # the provider refused (the agent never saw the offer — an older refusal was
  # already cleared at turn end).
  defp declined?(_scope, agent, turn_started_at) do
    is_nil(Agent.active_task(agent)) and is_nil(agent.provider_refusal) and
      not closed_a_task?(agent, turn_started_at)
  end

  # No start time to compare against: treated as having done something, since
  # charging an unproven refusal costs work and the other error costs a turn.
  defp closed_a_task?(_agent, nil), do: true

  # A cancel stamps `completed_at` too, but claiming and dropping the offer is
  # declining it, not work.
  defp closed_a_task?(%Agent{tasks: tasks}, %DateTime{} = turn_started_at) do
    Enum.any?(tasks || [], fn task ->
      task.status != :cancelled and not is_nil(task.completed_at) and
        DateTime.compare(task.completed_at, turn_started_at) != :lt
    end)
  end

  # The turn request is the offer `Offers.dispatch/3` writes, under the row
  # lock: two events racing to admit the same agent both take it, and only the
  # first sees a runnable state to write one.
  defp admit_turn(scope, id, event, {kind, subject}) do
    Repo.transaction(fn ->
      agent =
        Repo.one(
          from(a in Agent,
            where:
              a.id == ^id and a.project_id == ^scope.active_project_id and
                a.account_id == ^scope.active_account_id,
            lock: "FOR UPDATE"
          )
        )

      if agent && runnable_state?(scope, agent, event),
        do: request_turn(agent, kind, subject),
        else: :not_runnable
    end)
  end

  defp request_turn(agent, kind, subject) do
    case Offers.dispatch(agent, kind, subject) do
      {:ok, offered} -> {agent, offered}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The offer id is the turn's ref. A turn the harness would not take leaves
  # its offer undelivered, which is what lets the next wake through.
  defp hand_turn(agent, offered, turn_prompt) do
    case Transport.request_work_turn(agent.working_copy_id, agent, offered.id, turn_prompt, 5_000) do
      {:ok, :started} ->
        {:ok, offered.id}

      error ->
        Offers.undelivered(offered)
        error
    end
  end

  # The tasks whose open state is the queue's, not the agent's.
  @promotion_tasks ~w(promote_issue story_promoted)

  # Whether a turn could start now — nothing in flight, nothing held that the
  # agent could act on, a copy to run on. Whether this agent should be woken for
  # it at all is `Wake`'s.
  defp idle?(agent) do
    present?(agent) and is_nil(agent.turn_started_at) and
      not Offers.in_flight?(agent.id) and not busy_on?(agent) and
      not is_nil(agent.working_copy_id)
  end

  # A `promote_issue`/`story_promoted` task stays open until its candidate
  # lands or is ejected, and the queue messages the agent then. Holding only
  # such a task is waiting, not busy.
  defp busy_on?(agent) do
    case Agent.active_task(agent) do
      %{requirement_name: name} = task when name in @promotion_tasks ->
        not awaiting_landing?(agent, task)

      nil ->
        false

      _other ->
        true
    end
  end

  # An open candidate for this task's own subject is the queue's to finish;
  # a resolved one is the agent's turn.
  defp awaiting_landing?(agent, task) do
    case subject(agent, task) do
      nil -> false
      {type, id} -> Waits.open_for(agent.id, type, id)
    end
  end

  defp subject(_agent, %{awaiting_subject_type: type, awaiting_subject_id: id})
       when is_binary(type) and is_binary(id), do: {type, id}

  defp subject(_agent, %{issue_id: issue_id}) when is_binary(issue_id), do: {"issue", issue_id}

  defp subject(agent, %{story_id: story_id}) when is_integer(story_id) do
    case CodeMySpec.Stories.get_story(%Scope{active_project_id: agent.project_id}, story_id) do
      %{number: number} -> {"story", to_string(number)}
      nil -> nil
    end
  end

  defp subject(_agent, _task), do: nil

  # Its process alive now (`Agents.Presence`): nothing starts a turn in one that
  # is not there.
  defp present?(agent), do: Presence.present?(agent.project_id, agent.id)

  defp admit(scope, agent, event) do
    if idle?(agent), do: Wake.allow?(scope, agent, event), else: {:hold, :busy}
  end

  @doc """
  `admit/3`'s answer, for a caller that has to tell `:busy` from a hold.

  `request_turn_if_runnable/4` answers `{:ok, :not_runnable}` for every hold,
  so a test asking "is this agent busy?" cannot ask through it. This is the same
  decision, named.
  """
  @spec admission(Scope.t(), Agent.t(), :work_offer | :resume | :nudge) :: :ok | {:hold, term()}
  def admission(scope, agent, event), do: admit(scope, agent, event)

  # Under the row lock: the same answer, without announcing it twice.
  defp runnable_state?(scope, agent, event),
    do: idle?(agent) and Wake.decide(scope, agent, event) == :wake

  @doc """
  Forget what this agent last refused.

  A person answering a gate overrides the damper. Denying a tap-out means "no,
  there is work, go and do it" — it is the one input that is explicitly about
  this agent's refusal, and letting the fingerprint suppress the wake would
  make the deny silently do nothing, which is the stall the deny-wake was added
  to fix in the first place.
  """
  def clear_decline(scope, %Agent{} = agent) do
    AgentsRepository.update_agent(scope, agent, cleared())
  end

  defp cleared, do: %{declined_offer: nil, declined_offer_at: nil, declined_offer_count: nil}

  # What this agent is being offered, as a value comparable to what it last
  # refused.
  defp offer(scope, agent) do
    questions = held_questions(scope, agent)
    nodes = graph_work(scope, agent)

    if questions != [] or nodes != [] do
      {:work, fingerprint(questions, nodes), offer_subject(agent, nodes)}
    else
      :none
    end
  end

  # What the prompt sends it to claim: a task of its own whose blocker was
  # released, first — resumed only once it holds no active task, so it is never
  # a second one — then `get_next_requirement`'s head, or main's questions
  # when there is no graph work.
  defp offer_subject(agent, nodes) do
    case released_tasks(agent, nodes) do
      [task | _] -> released_subject(task)
      [] -> graph_subject(agent, nodes)
    end
  end

  defp graph_subject(agent, [{type, id, name} | _nodes]),
    do: {"requirement", node_key(agent, %{entity_type: type, entity_id: id, name: name})}

  defp graph_subject(_agent, []), do: {"questions", nil}

  # Released and still claimable: one the graph no longer offers would be
  # refused by `start_task`, and offering it first would hide the rest.
  #
  # And not held back: this is push-subject selection, not `claimable_work`
  # -- a released task this agent explicitly declined, or ignored to the
  # end of its own ladder, is not pushed again (criterion 1741's throttle).
  # Declining still holds the work back from `claimable_work` too; merely
  # ignoring it does not (see `withheld?/4`).
  defp released_tasks(%Agent{tasks: tasks} = agent, nodes) do
    standing = Offers.standing(agent.id)

    Enum.filter(tasks || [], fn task ->
      task.status == :blocked and not is_nil(task.blocker_resolved_at) and
        not match?(%{held?: true}, standing[task.id]) and
        Enum.any?(nodes, fn {type, id, name} ->
          task_on_node?(task, %{entity_type: type, entity_id: id, name: name})
        end)
    end)
  end

  # The same subject the release recorded, so the two supersede each other.
  defp released_subject(%{blocker_type: :tap_out, blocker_id: id}), do: {"tap_out", id}
  defp released_subject(task), do: {"task", task.id}

  defp offer_kind({"tap_out", _id}), do: :denial
  defp offer_kind({"task", _id}), do: :unblocked
  defp offer_kind(_subject), do: :work

  # Criterion 2158: an offer that asks the agent to act names itself and the
  # way to refuse it, so every body below is followed by the offer's own id
  # and `reject_offer` -- except a tap-out's own answer, which already says
  # what happened and is not itself an action request.
  defp offer_prompt(scope, agent, subject, offer) do
    scope
    |> offer_prompt_body(agent, subject)
    |> append_offer_note(subject, offer)
  end

  # A second offer of a released task carries its own rung's text, `:remind`,
  # rather than the same sentence again.
  defp offer_prompt_body(scope, agent, {"task", id}) do
    tasks = Enum.filter(agent.tasks, &(&1.id == id))
    base = "Your blocker was released; #{resume_instruction(scope, tasks)}"

    case rung(agent, :unblocked, "task", id) do
      :remind -> base <> answer(tasks) <> "\n\n" <> remind()
      _first -> base
    end
  end

  # An answer offer's second rung is the answer with the task it unblocks
  # (criterion 2175): the first said the answer, this repeats it beside the task.
  defp answer([%{blocker_type: :question, blocker_id: id}]),
    do: answer_text(Notifications.answer_detail(id))

  defp answer(_tasks), do: ""

  defp answer_text(nil), do: ""
  defp answer_text(text), do: "\n\n" <> text

  # Matches TaskOwner.resolved_header/1's own format for {:tap_out, id, :denied}
  # exactly, so a later rung of the same offer (this path) reads the same as
  # the first delivery (resume_ready/4, via wake_released/wake_with_notice) --
  # main's correction on 234810fe: one event, one wording, from one shared
  # builder, not two copies that happened to say similar things.
  defp offer_prompt_body(scope, agent, {"tap_out", id}) do
    tasks = Enum.filter(agent.tasks, &(&1.blocker_id == id))
    "Your blocker tap_out #{id} was denied; #{resume_instruction(scope, tasks)}"
  end

  # The extra text is chosen by the offer's rung on its kind's ladder: `:remind`
  # for a released task; `:detail` and `:alternatives` for requirement work.
  defp offer_prompt_body(scope, agent, {"requirement", key}) do
    case rung(agent, :work, "requirement", key) do
      :detail -> prompt(agent) <> "\n\n" <> detail(scope, agent, key)
      :alternatives -> prompt(agent) <> "\n\n" <> alternatives(scope, agent, key)
      _first -> prompt(agent)
    end
  end

  defp offer_prompt_body(_scope, agent, _subject), do: prompt(agent)

  defp append_offer_note(body, {"tap_out", _id}, _offer), do: body

  defp append_offer_note(body, _subject, %Offer{id: id}) do
    body <>
      "\n\n" <>
      "This is backed by offer `#{id}`. Complete it, or call `reject_offer` with that id and a reason."
  end

  defp append_offer_note(body, _subject, _offer), do: body

  # The way out of a second notice, for a task this agent was already told it
  # could resume. The line above already names it and the call that takes it, so
  # this says why it is being said again and what the alternative is.
  defp remind do
    "You were told this last turn and did not take it. Take it now, or " <>
      "`reject_offer` with your reason so main can reassign it."
  end

  # The rung the offer being rendered now carries: the rung the last ignored
  # offer wrote. None on a first offer.
  defp rung(agent, kind, type, key), do: Offers.rung(agent.id, kind, type, key)

  # The second offer of the same work says more about it.
  defp detail(scope, agent, key) do
    case Enum.find(offerable(scope, agent), &(node_key(agent, &1) == key)) do
      nil ->
        ""

      node ->
        """
        You were offered `#{node.name}` on #{entity(node)} last time and did not take it.

        Why it matters: #{why(node)}
        #{prerequisites_line(node)}Where to read: `get_next_requirement` lists it, and `start_task` on it returns the full instructions.
        If it is not yours to do, call `reject_offer` with your reason rather than leaving it.
        """
        |> String.trim()
    end
  end

  # The third names what else it could take.
  defp alternatives(scope, agent, key) do
    others =
      scope
      |> offerable(agent)
      |> Enum.reject(&(node_key(agent, &1) == key))
      |> Enum.take(5)

    base = detail(scope, agent, key)

    case others do
      [] ->
        base

      _ ->
        base <>
          "\n\nOther work you could take instead:\n" <>
          Enum.map_join(others, "\n", &"- `#{&1.name}` on #{entity(&1)}")
    end
  end

  defp entity(node), do: "#{node.entity_type} #{node.entity_name || node.entity_id}"

  defp why(%{description: description}) when is_binary(description) and description != "",
    do: description |> String.trim() |> String.trim_trailing(".") |> Kernel.<>(".")

  defp why(_node), do: "it is the next requirement for your role here."

  # Prerequisites are definition ids within the entity's graph; named from it.
  defp prerequisites_line(%{prerequisites: [_ | _] = ids} = node) do
    case node |> definitions() |> Enum.filter(&(&1.id in ids)) |> Enum.map(& &1.name) do
      [] -> ""
      names -> "It follows #{Enum.map_join(names, ", ", &"`#{&1}`")}, which are done.\n"
    end
  end

  defp prerequisites_line(_node), do: ""

  defp definitions(%{entity_type: "story"}), do: RequirementDefinitionData.story_graph()
  defp definitions(%{entity_type: "project"}), do: RequirementDefinitionData.project_graph()
  defp definitions(_node), do: []

  defp questions_only?({"questions", nil}), do: true
  defp questions_only?(_subject), do: false

  # Hashed: the comparison is equality, so the column stays fixed-width. Sorted
  # first — the offer is a set, and an order change must not read as new.
  defp fingerprint(questions, nodes) do
    :crypto.hash(:sha256, :erlang.term_to_binary({questions, Enum.sort(nodes)}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  # How many times the *same* offer may be re-made before it goes quiet. Not
  # zero: an agent may look again and take it. Five, matching `StopDecision`'s
  # repeat threshold, so the two throttles agree.
  @max_repeats 5

  # The window after which an unchanged offer is made again anyway: work whose
  # set is unchanged but whose claimability moved must still get another look.
  # Caps a spin at thirty turns an hour. A human message bypasses it.
  @decline_ttl_seconds 600

  # An offer of questions alone is held after one decline, for as long as the
  # set is unchanged: waiting does not make a question answerable, and every
  # change that matters changes the set. Main's check-in still lists them.
  #
  # Only refusals count. A delivery failure is recorded as an undelivered
  # offer, never folded in here, or every reader of the damper would go quiet
  # over an offer that merely missed once.
  defp already_declined?(%{declined_offer: declined} = agent, offer, questions_only?)
       when not is_nil(declined) and declined == offer do
    repeats_spent?(agent.declined_offer_count, questions_only?) and
      within_window?(agent.declined_offer_at, questions_only?)
  end

  defp already_declined?(_agent, _offer, _questions_only?), do: false

  defp repeats_spent?(n, true), do: is_integer(n) and n >= 1
  defp repeats_spent?(n, false), do: is_integer(n) and n >= @max_repeats

  # No timestamp: treated as expired, which keeps the agent reachable.
  defp within_window?(nil, _questions_only?), do: false
  defp within_window?(_at, true), do: true
  defp within_window?(at, false), do: DateTime.diff(DateTime.utc_now(), at) < @decline_ttl_seconds

  @doc """
  The damper holding this agent's current offer, or nil.

  `claimable` is `claimable_work/3`'s answer, passed in so a fleet read computes
  it once. Read by `list_agent_work` so a damped agent is not shown as idle.
  """
  @spec damped(Scope.t(), Agent.t(), [map()]) ::
          %{count: pos_integer(), requirement: String.t() | nil, until: DateTime.t()} | nil
  def damped(scope, %Agent{} = agent, claimable) do
    offer = offer_fingerprint(scope, agent, claimable)

    if already_declined?(agent, offer, false) do
      %{
        count: agent.declined_offer_count,
        requirement: claimable |> List.first() |> then(&(&1 && &1.name)),
        until: DateTime.add(agent.declined_offer_at, @decline_ttl_seconds, :second)
      }
    end
  end

  @doc false
  def offer_fingerprint(scope, agent, claimable) do
    fingerprint(
      held_questions(scope, agent),
      Enum.map(claimable, &{&1.entity_type, &1.entity_id, &1.name})
    )
  end

  # Teammates' questions held by this role's holder (main, or product for the
  # criteria questions routed to it), for a role that wakes on
  # `:teammate_question`. Their ids, so a new question is a new offer.
  defp held_questions(scope, %{role: role}) do
    holder = MainAgent.holder_of(role)

    if RoleProfile.wakes_on?(role, :teammate_question) and not is_nil(holder) do
      scope
      |> MainAgent.list_open_questions()
      |> Enum.filter(&(&1.holder == holder))
      |> Enum.map(& &1.id)
      |> Enum.sort()
    else
      []
    end
  end

  # `list_notifications` is code mode, reached from inside `run_script`; the
  # prompt says so, or the agent reports it as a broken tool.
  defp prompt(%{role: role}) do
    if RoleProfile.wakes_on?(role, :teammate_question),
      do:
        @prompt <>
          " Questions are also waiting for you: read them with " <>
          "`run_script` calling list_notifications, and answer each with " <>
          "`answer_notification` so the answer is recorded and reaches the asker. " <>
          "One that is the user's to decide goes up with `escalate_question`, " <>
          "never re-asked with `ask_user_question`: that opens a second question " <>
          "and leaves this one yours.",
      else: @prompt
  end

  # The nodes themselves rather than a boolean, so the offer can be fingerprinted.
  defp graph_work(scope, agent) do
    scope
    |> offerable(agent)
    |> Enum.map(&{&1.entity_type, &1.entity_id, &1.name})
  end

  # Claimable work less what this agent is not to be pushed again: this
  # feeds `graph_work/2`, the push-subject selection `offer/2` and
  # `admit_turn/4` act on, so it reads the combined `held?` -- a decline
  # or a ladder exhausted by ignoring both stop the push (criterion 1741).
  # `claimable_work/2` itself stays open to a pull (`withheld?/4` reads the
  # narrower `declined?`), so an exhausted offer still shows there.
  defp offerable(scope, agent) do
    standing = Offers.standing(agent.id)

    scope
    |> claimable_work(agent)
    |> Enum.reject(&match?(%{held?: true}, standing[node_key(agent, &1)]))
  end

  # The one place an offer's `subject_key` is built. A story node's
  # `entity_id` is the database id; the key uses the public number that
  # `get_next_requirement` and `start_task` show.
  defp node_key(agent, %{entity_type: "story", entity_id: id, name: name}) do
    case CodeMySpec.Stories.get_story(%Scope{active_project_id: agent.project_id}, id) do
      %{number: number} -> "story:#{number}:#{name}"
      nil -> "story:#{id}:#{name}"
    end
  end

  defp node_key(_agent, %{entity_type: type, entity_id: id, name: name}),
    do: "#{type}:#{id}:#{name}"

  @doc """
  The work for one caller: `Requirements.story_execution/4`'s status, its
  ordered `actionable` list, the `wave` cut from it, and why.

  The one answer to "what can this role do next here". The turn offer, the
  stop menu, `get_next_requirement` and `start_task`'s resume check all read
  it, so none of them names work another refuses. "First" is the head of
  `actionable`; "any" is whether it is empty.

    * `role` — whose requirements, through `RoleProfile.requirements`; `nil` is
      every role's.
    * `owner` — an `Agent` is answered at its own checkout, without what
      `withheld?/3` holds back from it. Anything else (a `Session`, `nil`) is
      answered at the scope's checkout with nothing withheld.

  Withholding happens before the story's wave is cut.

  An agent with issue work — its copy's assigned issues, its own issue, or
  just freed of an issue team — is answered from `IssueWork`, outside the
  graph. An agent with an active story (`bound_story_id/1`) is offered that
  story's work and nothing else, not held back by project-level prerequisites.

  Options: `:story_number` narrows to that story or refuses, as
  `get_next_requirement` takes it; `:owners` is the project's agents, so a
  fleet read lists them once.
  """
  @spec work_for(Scope.t(), atom() | nil, term(), keyword()) :: map()
  def work_for(scope, role, owner \\ nil, opts \\ [])

  # Issue work bypasses the graph entirely — an issue is not in it — and is
  # checked ahead of everything else.
  def work_for(%Scope{} = scope, role, %Agent{} = owner, opts) do
    scope = at_copy(scope, owner)

    bag =
      if Assignment.team_member?(owner.role),
        do: IssueAssignment.bag(scope, owner.working_copy_id),
        else: []

    cond do
      bag != [] ->
        filter_issue_work(scope, owner, IssueWork.execution(scope, owner, bag), opts)

      is_binary(owner.issue_id) ->
        filter_issue_work(scope, owner, IssueWork.execution(scope, owner), opts)

      not is_nil(owner.team_free_at) ->
        IssueWork.execution(scope, owner)

      true ->
        story_work_for(scope, role, owner, opts)
    end
  end

  def work_for(%Scope{} = scope, role, owner, opts),
    do: story_work_for(scope, role, owner, opts)

  defp filter_issue_work(scope, owner, execution, opts) do
    actionable = Enum.reject(execution.actionable, withholding(scope, owner, opts))

    if execution.actionable != [] and actionable == [] do
      %{
        execution
        | status: :blocked,
          actionable: [],
          wave: [],
          remaining: 0,
          reason: "The issue work is held by a teammate or blocked on an unresolved decision."
      }
    else
      %{execution | actionable: actionable, wave: actionable, remaining: length(actionable)}
    end
  end

  defp story_work_for(scope, role, owner, opts) do
    scope = at_copy(scope, owner)
    number = Keyword.get(opts, :story_number)
    withheld? = withholding(scope, owner, opts)
    Requirements.story_execution(scope, role, number, withheld?, assignment(scope, owner))
  end

  # Whose story the answer is about. A project-scoped role (main) reads none.
  # A team member (coding, QA) reads the story it holds; product and a session
  # read the story their copy's team holds. Reading never moves a team to its
  # next story.
  # See knowledge/agents, "Story binding".
  #
  # A team member holding a story is bound to it (`bound_story_id/1`).
  defp assignment(scope, %Agent{role: role} = agent) do
    case RoleProfile.scope(role) do
      :project -> :project
      :story -> bind({:team, bound_story_id(agent), agent.epic_id})
      _epic -> team(scope.active_working_copy_id)
    end
  end

  defp assignment(scope, _owner), do: team(scope.active_working_copy_id)

  defp team(copy_id),
    do: {:team, WorkingCopies.team_story_id(copy_id), Assignment.team_epic_id(copy_id)}

  defp bind({:team, nil, _epic} = unbound), do: unbound
  defp bind({:team, story_id, epic_id}), do: {:bound, story_id, epic_id}

  @doc """
  The story `agent` is bound to, or nil.

  A team member — coding or QA — holding a `story_id` is bound to it and is
  not offered work outside it. Main and product never hold one, so neither is
  bound.

  What counts as the story's work is `StoryExecution.story_work?/3`.
  """
  @spec bound_story_id(term()) :: integer() | nil
  def bound_story_id(%Agent{role: role, story_id: id}),
    do: if(Assignment.team_member?(role), do: id)

  def bound_story_id(_owner), do: nil

  @doc "`work_for/4`'s ordered actionable list."
  @spec actionable(Scope.t(), atom() | nil, term(), keyword()) :: [map()]
  def actionable(scope, role, owner \\ nil, opts \\ [])
  def actionable(%Scope{active_project_id: nil}, _role, _owner, _opts), do: []
  def actionable(scope, role, owner, opts), do: work_for(scope, role, owner, opts).actionable

  @doc """
  The story graph's own actionable list, bypassing `work_for/4`'s issue-binding
  short-circuit.

  For asking whether an existing, blocked story task may still resume:
  `work_for/4`'s issue bypass is a dispatch-priority rule and would refuse a
  still-eligible story task for an agent that also holds an issue.
  `withholding/3` still applies.
  """
  @spec story_actionable(Scope.t(), atom() | nil, term(), keyword()) :: [map()]
  def story_actionable(scope, role, owner \\ nil, opts \\ [])
  def story_actionable(%Scope{active_project_id: nil}, _role, _owner, _opts), do: []

  def story_actionable(scope, role, owner, opts),
    do: story_work_for(scope, role, owner, opts).actionable

  defp at_copy(scope, %Agent{working_copy_id: id}) when is_binary(id),
    do: %{scope | active_working_copy_id: id}

  defp at_copy(scope, _owner), do: scope

  defp withholding(scope, %Agent{} = agent, opts) do
    owners = Keyword.get(opts, :owners) || AgentsRepository.list_agents(scope)
    standing = Offers.standing(agent.id)
    &withheld?(owners, agent, &1, standing)
  end

  defp withholding(_scope, _owner, _opts), do: fn _node -> false end

  @doc """
  `actionable/4` for this agent's role at its own checkout.

  Public so the main agent's "this agent has work" is this answer rather than a
  second one that disagrees. `owners` saves a reader asking for a
  whole fleet from listing the project's agents once per agent.
  """
  @spec claimable_work(Scope.t(), Agent.t(), [Agent.t()] | nil) :: [map()]
  def claimable_work(scope, agent, owners \\ nil),
    do: actionable(scope, agent.role, agent, owners: owners)

  @doc """
  What a pull (`get_next_requirement`) would currently show this agent to
  act on: `{kind, subject}` for the head of its claimable work, the same
  selection `offer_subject/2` makes for a pushed turn, or nil when there is
  none. Read-only -- a pull never records an offer (issue e6f18e57, product's
  ruling on 7371fb26: only pushed work turns climb the ladder).
  `Agents.reject_offer/4`'s own fallback uses this to decline work that was
  shown but never backed by an offer.
  """
  @spec shown_work(Scope.t(), Agent.t()) :: {Offer.kind(), Offers.subject()} | nil
  def shown_work(scope, %Agent{} = agent) do
    case claimable_work(scope, agent) do
      [] ->
        nil

      nodes ->
        subject =
          offer_subject(agent, Enum.map(nodes, &{&1.entity_type, &1.entity_id, &1.name}))

        {offer_kind(subject), subject}
    end
  end

  @doc """
  Whether a task at `agent`'s checkout withholds `node` from it: another
  agent's live task, its own blocked on an unresolved blocker, or its own
  open offer for the same work that `Offers.standing/1` reads as declined.

  The last half is criterion 2163: a declined offer holds the work back
  from the agent that declined it, alone, until main acts -- reassigns it,
  gives the agent other work, or offers it again. This reads `standing`'s
  narrower `declined?`, not `held?` -- `held?` also covers an offer merely
  ignored to the end of its own ladder, which is not a decline (criterion
  2169, product's correction on 3e9a96e9, itself correcting 1ef7cfe3).
  That case stops being pushed (`offerable/2` reads `held?` for that, so
  criterion 1741's throttle still holds), but it stays open and claimable:
  a pull (`get_next_requirement`) still shows it, and `start_task` or
  `reject_offer` still act on it, until main does.

  Its own active task is not withheld -- `start_task` resumes that.
  """
  @spec withheld?([Agent.t()], Agent.t(), map(), map()) :: boolean()
  def withheld?(owners, agent, node, standing \\ %{}) do
    held_back?(agent, node, standing) or
      (owners
       |> Enum.filter(&(&1.working_copy_id == agent.working_copy_id))
       |> Enum.any?(fn owner ->
         mine? = owner.id == agent.id
         Enum.any?(owner.tasks || [], &holds_node?(&1, mine?, node))
       end))
  end

  defp held_back?(agent, node, standing) do
    match?(%{declined?: true}, standing[node_key(agent, node)])
  end

  defp holds_node?(task, mine?, node) do
    task_on_node?(task, node) and
      ((task.status == :active and not mine?) or
         (task.status == :blocked and (not mine? or is_nil(task.blocker_resolved_at))))
  end

  @doc "Whether `task` is the work `node` names."
  def task_on_node?(task, node) do
    task.requirement_name == node.name and
      entity_id(task, node.entity_type) == to_string(node.entity_id)
  end

  defp entity_id(task, "issue"), do: to_string(task.issue_id)
  defp entity_id(task, "story"), do: to_string(task.story_id)
  defp entity_id(task, "component"), do: to_string(task.component_id)
  defp entity_id(task, "project"), do: to_string(task.project_id)
  defp entity_id(_task, _type), do: nil
end
