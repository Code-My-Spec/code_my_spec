defmodule CodeMySpec.Agents.Work do
  @moduledoc "Eligibility and atomic turn admission for existing durable role agents."

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Conversations
  alias CodeMySpec.MainAgent
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation

  # Only tools the agent actually carries directly.
  #
  # This named `list_requirements` and, for main, `list_notifications` — both
  # reachable from `run_script` and neither on an agent's direct surface. A main
  # agent measured on 2026-09-20 called `list_notifications` first because the
  # prompt told it to, got `Unknown tool`, and then did exactly what
  # `OperatingRules` requires of it: reported the failure, refused to work
  # around it, and stopped. It never reached `start_task`.
  #
  # So the prompt talked the agent out of the loop the prompt was sent to start.
  # `Tools.GetNextRequirement` and `Tools.StartTask` are on the engine's list;
  # nothing else named here was.
  @prompt "Eligible work is available. Call get_next_requirement to see it, " <>
            "then claim it with start_task. No task has been selected or assigned for you."

  def consider_project(scope, reason) do
    scope
    |> AgentsRepository.list_agents()
    |> Enum.each(&consider(scope, &1, reason))

    :ok
  end

  def consider_copy(scope, copy_id, reason, except_agent_id \\ nil) do
    scope
    |> AgentsRepository.list_agents()
    |> Enum.filter(&(&1.working_copy_id == copy_id and &1.id != except_agent_id))
    |> Enum.each(&consider(scope, &1, reason))

    :ok
  end

  # An agent holding a task is not offered new work, but it is not skipped
  # either: it is asked to dispose of what it holds. Skipping it left an agent
  # that stopped holding `bdd_specs_passing` idle for 50 minutes on 2026-09-22,
  # through the fix for the result it was waiting on and a fleet restart
  # (`64299aef`). Each path refuses the other's agent, so both are asked.
  defp consider(scope, agent, reason) do
    request_turn_if_runnable(scope, agent, reason)
    resume_if_held(scope, agent)
  end

  @held_prompt "You still hold the task below and no turn of yours is running. " <>
                 "Something may have changed since you stopped — a result you were " <>
                 "waiting on may have landed. Check where it stands and dispose of it: " <>
                 "evaluate_task when it is done, cancel_task or tap_out if it cannot be."

  # Damped by the same streak as a declined offer, keyed on the held task: every
  # graph change and cadence tick reaches this, and an agent legitimately
  # waiting would otherwise spend a turn on each.
  defp resume_if_held(scope, agent) do
    with {:ok, current} <- AgentsRepository.fetch_agent(scope, agent.id),
         true <- stranded?(current) and not awaiting_tap_out?(current),
         held = held_offer(current),
         false <- already_declined?(current, held) do
      suppress_offer(scope, current, held)
      resume(scope, current, held_prompt(scope, current))
    end
  end

  defp held_offer(agent), do: "held:" <> Agent.active_task(agent).id

  defp held_prompt(scope, agent) do
    scope = %{scope | active_working_copy_id: agent.working_copy_id}
    @held_prompt <> Validation.Menu.render(scope, true, agent.role, agent)
  end

  @resume_prompt "Your last turn ended without finishing — the harness restarted " <>
                   "under it, so whatever it had in flight was discarded and never " <>
                   "recorded. You still hold the task below. Nothing is wrong with it " <>
                   "and nothing has been decided about it; pick it back up from where " <>
                   "the thread leaves off, and dispose of it as usual when the work is " <>
                   "done. If you cannot tell how far it got, re-check rather than assume."

  @doc """
  Offer a turn to agents left holding a task with no turn open.

  `runnable_state?/1` refuses an agent with an active task, which is right while
  a turn is genuinely running and wrong the moment one is not. A turn discarded
  mid-flight — a harness restart is the common way — clears `turn_started_at`
  and leaves the task held, which is the exact combination every recovery path
  in the system then skips. `consider_copy/4` on reconnect skips it too, for the
  same reason.

  So the agent is not busy; it is stranded, and only a human message frees it.
  Measured 2026-09-22: a QA agent mid-way through a browser re-test was
  discarded by another session's promote at 19:02, was told "you have an open
  task", and then sat untouched until it was messaged by hand six minutes
  later. The same shape held a coding agent on another project for eight days.

  Holding a task is not evidence of a live turn — `turn_started_at` is, and
  this requires it to be nil. An open reservation is still respected, because
  that window is a dispatch genuinely in flight.
  """
  def resume_held_tasks(scope, copy_id) do
    scope
    |> AgentsRepository.list_agents()
    |> Enum.filter(&(&1.working_copy_id == copy_id and stranded?(&1)))
    |> Enum.each(&resume(scope, &1, @resume_prompt))

    :ok
  end

  defp stranded?(agent) do
    agent.status == :running and agent.continuous and is_nil(agent.turn_started_at) and
      not reservation_open?(agent) and not is_nil(Agent.active_task(agent)) and
      not is_nil(agent.working_copy_id)
  end

  defp resume(scope, agent, turn_prompt) do
    with {:ok, {reserved, ref}} <- reserve_stranded(scope, agent.id) do
      Conversations.record_sent_to_agent(reserved, turn_prompt)

      case Transport.impl().request_work_turn(
             reserved.working_copy_id,
             reserved,
             ref,
             turn_prompt,
             5_000
           ) do
        {:ok, :started} -> {:ok, ref}
        _error -> release(scope, reserved.id, ref)
      end
    end
  end

  # Same row lock and stamp as `reserve/2`, against `stranded?/1` rather than
  # `runnable_state?/1` — two events racing to resume one agent must still hand
  # out a single turn.
  defp reserve_stranded(scope, id) do
    Repo.transaction(fn ->
      agent =
        Repo.one(
          from a in Agent,
            where:
              a.id == ^id and a.project_id == ^scope.active_project_id and
                a.account_id == ^scope.active_account_id,
            lock: "FOR UPDATE"
        )

      if agent && stranded?(agent), do: reserve(agent), else: :not_stranded
    end)
  end

  @doc """
  Offer one agent a turn whose prompt opens with `preface`.

  The difference between this and recording a message then calling
  `consider_copy/4` is where the text lands, and that difference is the whole
  point. A recorded message is history: the agent reads it as something that
  was said earlier, alongside its own last conclusion, and its own conclusion
  wins. The turn prompt is the input the agent is answering.

  Measured 2026-09-22, and it is why two shipped fixes changed nothing. A
  denial notice naming the agent's now-resolved blocker by id was recorded at
  21:37:20.317; the agent's turn — driven by the generic work prompt — said at
  21:37:29.079 that the same issue id was unresolved and the tap-out still
  pending. Nine seconds, same id. Delivering the same words through
  `message_agent`, which puts them in the turn, worked three times out of three
  across two agents.

  So the correction has to be what the agent is answering, not something it
  could answer past.
  """
  def offer_turn_with(scope, %Agent{} = agent, preface) when is_binary(preface) do
    with {:ok, current} <- AgentsRepository.fetch_agent(scope, agent.id),
         true <- runnable_state?(current),
         {:ok, {reserved, ref}} <- reserve(scope, current.id) do
      turn_prompt = preface <> "\n\n" <> prompt(reserved)
      Conversations.record_sent_to_agent(reserved, turn_prompt)

      case Transport.impl().request_work_turn(
             reserved.working_copy_id,
             reserved,
             ref,
             turn_prompt,
             5_000
           ) do
        {:ok, :started} ->
          {:ok, ref}

        error ->
          release(scope, reserved.id, ref)
          error
      end
    else
      false -> {:ok, :not_runnable}
      {:ok, :not_runnable} = result -> result
      error -> error
    end
  end

  def request_turn_if_runnable(scope, %Agent{} = agent, _reason) do
    with {:ok, current} <- AgentsRepository.fetch_agent(scope, agent.id),
         true <- runnable_state?(current),
         {:work, offer} <- offer(scope, current),
         false <- already_declined?(current, offer),
         {:ok, {reserved, ref}} <- reserve(scope, current.id) do
      turn_prompt = prompt(reserved)

      # Recorded as well as sent, and recorded first — the same reasoning as
      # `StopDecision.send_to/3`, which records because it dispatches through
      # the transport directly rather than through `Agents.send_to_agent/2`.
      #
      # Without it a turn arrives out of nowhere: the transcript shows an agent
      # that suddenly started working with nothing in front of it saying why,
      # which is precisely what an operator watching an autonomous fleet needs
      # to be able to read. `wake` recorded its message for the same reason,
      # and the retirement took the recording with it — story 1050 measures
      # routing off these rows, and every correctly routed turn read as
      # silence.
      Conversations.record_sent_to_agent(reserved, turn_prompt)

      case Transport.impl().request_work_turn(
             reserved.working_copy_id,
             reserved,
             ref,
             turn_prompt,
             5_000
           ) do
        {:ok, :started} ->
          {:ok, ref}

        error ->
          release(scope, reserved.id, ref)
          suppress_offer(scope, reserved, offer)
          error
      end
    else
      false -> {:ok, :not_runnable}
      :none -> {:ok, :not_runnable}
      true -> {:ok, :offer_declined}
      {:ok, :not_runnable} = result -> result
      error -> error
    end
  end

  @doc """
  Record that this agent ended a turn without taking the work it was offered.

  Called from the turn-ended path, which is the only place that knows a turn
  finished with nothing claimed. Until this existed the agent was re-offered
  the same work immediately and forever: ending a turn clears `turn_started_at`
  and the reservation, and declining leaves `active_task` nil, so every
  condition `runnable_state?/1` tests is satisfied again the instant the turn
  ends. The next observation — and a turn ending is itself enough to produce
  one — fires `consider_project/2` and hands the agent the offer it just
  refused.

  Measured on the math project 2026-09-22, QA agent 85118c1a: 197 turns in
  3m29s, each one reading "not re-claiming it; ending the turn", at a steady
  60 a minute. Nothing in the system damped it and nothing would have.

  An agent that *did* claim something has not declined anything, so its mark is
  cleared — the next offer after a completed task is a genuinely new one.
  """
  def record_decline(scope, %Agent{} = agent, turn_started_at \\ nil) do
    AgentsRepository.update_agent(scope, agent, decline_attrs(scope, agent, turn_started_at))
  end

  @doc """
  Hold off on re-offering work whose dispatch did not land.

  A turn that cannot be delivered never becomes a turn, so the agent never ends
  one and `record_decline/3` — which fires on the turn-ended path — never runs.
  Nothing else damps it either: `release/3` clears the reservation, which puts
  the agent straight back into `runnable_state?/1`, and the next observation
  offers it the same work again.

  So an agent whose machine is unreachable spins on the *server* side, with no
  agent involved at all. Measured 2026-09-22: main agent `d632ee86` on a
  checkout whose harness was not connected recorded 130 undelivered prompts a
  minute for nine minutes, each one logging "nothing registered for working
  copy", while the transcript filled with turns that never happened.

  Same window as a refusal, for the same reason: retrying an unreachable
  machine six times an hour is diagnosis, twice a second is a denial of
  service against our own database.
  """
  def suppress_offer(scope, %Agent{} = agent, fingerprint) do
    AgentsRepository.update_agent(scope, agent, streak(agent, fingerprint))
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

  defp decline_attrs(scope, agent, turn_started_at) do
    cond do
      # A holder declined nothing, and its streak is the held task's — kept, so
      # a turn ending does not reset the damper on `resume_if_held/2`.
      Agent.active_task(agent) ->
        %{}

      declined?(scope, agent, turn_started_at) ->
        case offer(scope, agent) do
          {:work, fingerprint} -> streak(agent, fingerprint)
          :none -> cleared()
        end

      true ->
        cleared()
    end
  end

  # A turn that did nothing, as distinct from one that did something and left
  # more behind.
  #
  # Holding a task is the obvious case. The subtle one is a turn that *closed*
  # a task: the agent no longer holds anything, so the naive reading is that it
  # declined — and the offer it would be charged with declining is the next
  # piece of work, handed to it by `consider_copy(:task_completed)` moments
  # later. That would damp the pipeline at exactly the point it is supposed to
  # advance, turning every completed task into a ten-minute wait for the next
  # one.
  #
  # So work done during the turn counts as work, whether or not it is still
  # open when the turn ends.
  defp declined?(_scope, agent, turn_started_at) do
    is_nil(Agent.active_task(agent)) and not closed_a_task?(agent, turn_started_at)
  end

  # No start time to compare against — an interrupted turn, or a caller that
  # does not track one. Treated as having done something, because charging an
  # agent with a refusal it cannot be shown to have made is the error that
  # costs work rather than the one that costs a turn.
  defp closed_a_task?(_agent, nil), do: true

  defp closed_a_task?(%Agent{tasks: tasks}, %DateTime{} = turn_started_at) do
    Enum.any?(tasks || [], fn task ->
      not is_nil(task.completed_at) and
        DateTime.compare(task.completed_at, turn_started_at) != :lt
    end)
  end

  def release(scope, agent_id, ref) do
    from(a in Agent,
      where:
        a.id == ^agent_id and a.project_id == ^scope.active_project_id and
          a.account_id == ^scope.active_account_id and a.work_request_id == ^ref
    )
    |> Repo.update_all(set: [work_request_id: nil, work_requested_at: nil])

    :ok
  end

  defp reserve(scope, id) do
    Repo.transaction(fn ->
      agent =
        Repo.one(
          from a in Agent,
            where:
              a.id == ^id and a.project_id == ^scope.active_project_id and
                a.account_id == ^scope.active_account_id,
            lock: "FOR UPDATE"
        )

      if agent && runnable_state?(agent), do: reserve(agent), else: :not_runnable
    end)
  end

  # Stamping the reservation is what makes the request idempotent: two events
  # racing to admit the same agent both take the row lock above, and only the
  # first sees a runnable state to stamp.
  defp reserve(agent) do
    ref = Ecto.UUID.generate()

    agent
    |> Agent.changeset(%{work_request_id: ref, work_requested_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, saved} -> {saved, ref}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp runnable_state?(agent) do
    agent.status == :running and agent.continuous and is_nil(agent.turn_started_at) and
      not reservation_open?(agent) and is_nil(Agent.active_task(agent)) and
      not is_nil(agent.working_copy_id) and not awaiting_tap_out?(agent)
  end

  # An agent that tapped out has asked to leave the loop until a person
  # answers. metric_flow's coding agent was nudged 42 times over 5.5 hours on
  # 2026-09-27 while its tap-out waited, answering each with a turn that said
  # the same thing. A decision resolves the blocker or cancels the task, and
  # either one makes it runnable again.
  defp awaiting_tap_out?(agent) do
    Enum.any?(agent.tasks || [], fn task ->
      task.status == :blocked and task.blocker_type == :tap_out and
        is_nil(task.blocker_resolved_at)
    end)
  end

  # A reservation is the gap between stamping a turn and the agent reporting it
  # started — seconds. The turn itself is guarded by `turn_started_at`, so
  # nothing legitimate sits in this window for minutes, and five is generous.
  #
  # It has to expire because every path that clears it needs a live process:
  # `release/3` on a failed dispatch, and the agent's own completion. The case
  # that strands one is the process going away after the transport accepted it.
  # `record_stopped/2` clears it when the reap notices — but a harness restart
  # re-reports the agent as running without passing through there, and
  # `record_running_on_copy/3` leaves an already-`:running` row alone. That row
  # is exactly the one holding the stale reservation.
  #
  # Measured on the math project 2026-09-22: coding stamped a reservation at
  # 01:53, the harness restarted three times, and the row carried it through
  # every one. `runnable_state?/1` requires no open reservation, so the agent
  # was un-admittable for two hours while its own `spex_boundary_ready` sat
  # ready and the other three roles waited behind it.
  #
  # Expiring rather than clearing on sight: `reserve/1` stamps a fresh ref over
  # the top, and `release/3` matches on the ref it was given, so a late releaser
  # for the dead reservation cannot clobber the live one.
  @reservation_ttl_seconds 300

  defp reservation_open?(%{work_request_id: nil}), do: false

  # Stamped by a build that did not record the time. Treated as open rather than
  # expired, because "no timestamp" is not evidence of age.
  defp reservation_open?(%{work_requested_at: nil}), do: true

  defp reservation_open?(%{work_requested_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at) < @reservation_ttl_seconds

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

  # What this agent is being offered, as a value that can be compared to what it
  # last refused. `eligible_work?/2` answered only "is there any", which cannot
  # tell a new offer from a repeat of the one just declined.
  defp offer(scope, agent) do
    questions = question_work?(scope, agent)
    nodes = graph_work(scope, agent)

    if questions or nodes != [] do
      {:work, fingerprint(questions, nodes)}
    else
      :none
    end
  end

  # Hashed rather than stored whole: the comparison is equality and nothing
  # reads the parts, so the column stays a fixed width no matter how much work
  # a role has. Sorted first — `actionable_for_role/2` makes no ordering
  # promise, and an unstable order would read as a changed offer every pass and
  # defeat the whole guard.
  defp fingerprint(questions, nodes) do
    :crypto.hash(:sha256, :erlang.term_to_binary({questions, Enum.sort(nodes)}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  # How many times the *same* offer may be re-made before it goes quiet.
  #
  # Not zero, which is what this guard first did and what story 1048 refuses:
  # criterion 3570 — "previously observed eligible work permits a later turn" —
  # lets a graph-admitted turn end without claiming and then requires the
  # turn-end event alone to reconsider the unchanged work. Criterion 3572 says
  # the same from the other side, "without suppressing later turns". An agent
  # that looks again and takes it the second time is the system working; the
  # defect is the 197th look, not the 2nd.
  #
  # Five, matching `StopDecision.stuck?/3`, which already solved this for the
  # sibling path — a repeated message goes quiet after the same five repeats.
  # Two throttles on two paths disagreeing about what "repeated" means is how
  # an operator ends up unable to predict either.
  @max_repeats 5

  # The window after which an unchanged offer is made again anyway.
  #
  # Without it the fingerprint is a wedge: work whose *set* does not change but
  # whose claimability does — a blocker cleared, a dependency finished
  # elsewhere, a tool granted — would leave the agent asleep with no edge left
  # to wake it, which is the failure this system already knows well from an
  # agent holding a task nothing can interrupt.
  #
  # Ten minutes caps a spin at thirty turns an hour rather than 3,600, while
  # still guaranteeing the agent gets another look. A human `message_agent`
  # bypasses this entirely and always did.
  @decline_ttl_seconds 600

  defp already_declined?(%{declined_offer: nil}, _offer), do: false

  defp already_declined?(%{declined_offer: declined}, offer) when declined != offer, do: false

  # Recorded by a build that did not stamp the time. Treated as expired rather
  # than open — the same reasoning as `reservation_open?/1` in reverse: here the
  # conservative reading is the one that keeps the agent reachable.
  defp already_declined?(%{declined_offer_at: nil}, _offer), do: false

  defp already_declined?(%{declined_offer_count: n}, _offer)
       when not is_integer(n) or n < @max_repeats,
       do: false

  defp already_declined?(%{declined_offer_at: at}, _offer),
    do: DateTime.diff(DateTime.utc_now(), at) < @decline_ttl_seconds

  defp question_work?(scope, %{role: :main}) do
    Enum.any?(MainAgent.list_open_questions(scope), &(&1.holder == "main_agent"))
  end

  defp question_work?(_scope, _agent), do: false

  # `list_notifications` is code mode, like most of the catalogue — a main agent
  # reaches it from inside a script, and saying so is the difference between a
  # tool it can use and one it reports as broken.
  defp prompt(%{role: :main}) do
    @prompt <>
      " Questions are also waiting for you: read them with " <>
      "`run_script` calling list_notifications."
  end

  defp prompt(_agent), do: @prompt

  # The nodes themselves rather than a boolean, so the offer can be fingerprinted.
  defp graph_work(scope, agent) do
    scope
    |> claimable_work(agent)
    |> Enum.map(&{&1.entity_type, &1.entity_id, &1.name})
  end

  @doc """
  The graph work this agent would be offered: its role's actionable nodes at its
  own checkout, minus any another agent there holds.

  Public so the main agent's "this agent has work" is this answer rather than a
  second one that disagrees (4849f20b). `owners` saves a reader asking for a
  whole fleet from listing the project's agents once per agent.
  """
  @spec claimable_work(Scope.t(), Agent.t(), [Agent.t()] | nil) :: [map()]
  def claimable_work(scope, agent, owners \\ nil) do
    scope = %{scope | active_working_copy_id: agent.working_copy_id}
    owners = owners || AgentsRepository.list_agents(scope)

    scope
    |> Requirements.actionable_for_role(agent.role)
    |> Enum.reject(&held?(owners, agent, &1))
  end

  defp held?(owners, agent, node), do: held_by?(owners, agent, node, true)

  @doc """
  Whether a task at `agent`'s checkout withholds `node` from it: another
  agent's live task, or its own blocked on an unresolved blocker.

  `get_next_requirement` asks this so it never offers what `start_task` refuses
  (467310a7). Its own active task is not withheld — `start_task` resumes that.
  """
  @spec withheld?([Agent.t()], Agent.t(), map()) :: boolean()
  def withheld?(owners, agent, node), do: held_by?(owners, agent, node, false)

  defp held_by?(owners, agent, node, own_active?) do
    owners
    |> Enum.filter(&(&1.working_copy_id == agent.working_copy_id))
    |> Enum.any?(fn owner ->
      mine? = owner.id == agent.id
      Enum.any?(owner.tasks || [], &holds_node?(&1, mine?, own_active?, node))
    end)
  end

  defp holds_node?(task, mine?, own_active?, node) do
    task.requirement_name == node.name and
      entity_id(task, node.entity_type) == to_string(node.entity_id) and
      ((task.status == :active and (own_active? or not mine?)) or
         (task.status == :blocked and (not mine? or is_nil(task.blocker_resolved_at))))
  end

  defp entity_id(task, "story"), do: to_string(task.story_id)
  defp entity_id(task, "component"), do: to_string(task.component_id)
  defp entity_id(task, "project"), do: to_string(task.project_id)
  defp entity_id(_task, _type), do: nil
end
