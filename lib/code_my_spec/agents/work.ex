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
  def record_decline(scope, %Agent{} = agent) do
    attrs =
      case {Agent.active_task(agent), offer(scope, agent)} do
        {nil, {:work, fingerprint}} ->
          %{declined_offer: fingerprint, declined_offer_at: DateTime.utc_now()}

        _ ->
          %{declined_offer: nil, declined_offer_at: nil}
      end

    AgentsRepository.update_agent(scope, agent, attrs)
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
      not is_nil(agent.working_copy_id)
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
    AgentsRepository.update_agent(scope, agent, %{declined_offer: nil, declined_offer_at: nil})
  end

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

  # The window after which an unchanged offer is made again anyway.
  #
  # Without it the fingerprint is a wedge: work whose *set* does not change but
  # whose claimability does — a blocker cleared, a dependency finished
  # elsewhere, a tool granted — would leave the agent asleep with no edge left
  # to wake it, which is the failure this system already knows well from an
  # agent holding a task nothing can interrupt.
  #
  # Ten minutes turns a 60-turn-per-minute spin into six turns an hour while
  # still guaranteeing the agent gets another look. A human `message_agent`
  # bypasses this entirely and always did.
  @decline_ttl_seconds 600

  defp already_declined?(%{declined_offer: nil}, _offer), do: false

  defp already_declined?(%{declined_offer: declined}, offer) when declined != offer, do: false

  # Recorded by a build that did not stamp the time. Treated as expired rather
  # than open — the same reasoning as `reservation_open?/1` in reverse: here the
  # conservative reading is the one that keeps the agent reachable.
  defp already_declined?(%{declined_offer_at: nil}, _offer), do: false

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
    scope = %{scope | active_working_copy_id: agent.working_copy_id}
    owners = AgentsRepository.list_agents(scope)

    scope
    |> Requirements.actionable_for_role(agent.role)
    |> Enum.reject(&held?(owners, agent, &1))
    |> Enum.map(&{&1.entity_type, &1.entity_id, &1.name})
  end

  defp held?(owners, agent, node) do
    owners
    |> Enum.filter(&(&1.working_copy_id == agent.working_copy_id))
    |> Enum.any?(fn owner ->
      Enum.any?(owner.tasks || [], &holds_node?(&1, owner.id == agent.id, node))
    end)
  end

  defp holds_node?(task, mine?, node) do
    task.requirement_name == node.name and
      entity_id(task, node.entity_type) == to_string(node.entity_id) and
      (task.status == :active or
         (task.status == :blocked and (not mine? or is_nil(task.blocker_resolved_at))))
  end

  defp entity_id(task, "story"), do: to_string(task.story_id)
  defp entity_id(task, "component"), do: to_string(task.component_id)
  defp entity_id(task, "project"), do: to_string(task.project_id)
  defp entity_id(_task, _type), do: nil
end
