defmodule CodeMySpec.Agents.Work do
  @moduledoc "Eligibility and atomic turn admission for existing durable role agents."

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Assignment
  alias CodeMySpec.Agents.IssueWork
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Presence
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Agents.Wake
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

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
                   "under it, so whatever it had in flight was discarded and never " <>
                   "recorded. You still hold the task below. Nothing is wrong with it " <>
                   "and nothing has been decided about it; pick it back up from where " <>
                   "the thread leaves off, and dispose of it as usual when the work is " <>
                   "done. If you cannot tell how far it got, re-check rather than assume."

  @doc """
  Give back the turns a harness restart discarded (5a977f41).

  `Agents.account_for_interrupted_turns/2` tells an agent its turn was
  discarded, but only as history — and every agent then sat idle: a continuous
  coder resuming a task and a main agent acting on an instruction were both
  still idle twelve minutes after v2.0.296's restart. Holding a task, waiting
  on a tap-out or damped on its last offer, none of them is reached by
  `consider_copy/4` or `resume_held_tasks/2`.

  So the message the discarded turn was answering is delivered again, as a
  turn. `:own_reply` — the restart is the agent's own work coming back, not
  new work — which reaches a waiting or non-continuous agent and never an off
  one. `interrupted` is `Agents.interrupted_turns/1`'s answer from the restore
  this reconnect follows.
  """
  @spec redeliver_interrupted_turns(Scope.t(), %{Ecto.UUID.t() => Ecto.UUID.t() | nil}) :: :ok
  def redeliver_interrupted_turns(scope, interrupted) when is_map(interrupted) do
    Enum.each(interrupted, fn {agent_id, starter_id} ->
      case AgentsRepository.fetch_agent(scope, agent_id) do
        {:ok, agent} -> redeliver(scope, agent, starter_id)
        _gone -> :ok
      end
    end)
  end

  # With nothing recorded there is no message to give back, so only an agent in
  # the loop is told to carry on: a non-continuous one is woken by a person or
  # its own reply, and neither is on the thread.
  defp redeliver(_scope, %Agent{continuous: continuous}, nil) when continuous != true, do: :ok

  defp redeliver(scope, agent, starter_id) do
    with :ok <- Wake.allow?(scope, agent, :own_reply),
         {:ok, {reserved, ref}} <- reserve_interrupted(scope, agent.id) do
      turn_prompt = redeliver_prompt(starter_id) <> held_task_line(reserved)

      offered =
        reserved
        |> Conversations.record_sent_to_agent(turn_prompt)
        |> Offers.record(reserved, :resume, {"restart", nil})

      case Transport.request_work_turn(
             reserved.working_copy_id,
             reserved,
             ref,
             turn_prompt,
             5_000
           ) do
        {:ok, :started} ->
          {:ok, ref}

        _error ->
          Offers.undelivered(offered)
          release(scope, reserved.id, ref)
      end
    end
  end

  @redelivered "The harness restarted part-way through your last turn, and that turn " <>
                 "was discarded — the notice above says what that means. "

  defp redeliver_prompt(starter_id) do
    case starter_id && Repo.get(Message, starter_id) do
      %Message{} = starter ->
        @redelivered <>
          "This is the message it was answering, delivered again. Pick it up from what " <>
          "the thread shows was already done:\n\n" <> Message.text(starter)

      _none ->
        @redelivered <> "Carry on from what the thread shows was already done."
    end
  end

  # The task the turn was working, when it holds one — what `resume_held_tasks/2`
  # would have named, since this turn is taken in its place.
  defp held_task_line(agent) do
    case Agent.active_task(agent) do
      nil -> ""
      task -> "\n\n" <> task_line(task)
    end
  end

  # Holding a task does not fence this out, as it fences `reserve/2`: the
  # discarded turn may have been working one.
  defp reserve_interrupted(scope, id) do
    Repo.transaction(fn ->
      agent =
        Repo.one(
          from a in Agent,
            where:
              a.id == ^id and a.project_id == ^scope.active_project_id and
                a.account_id == ^scope.active_account_id,
            lock: "FOR UPDATE"
        )

      if agent && takes_redelivery?(agent), do: reserve(agent), else: :not_runnable
    end)
  end

  defp takes_redelivery?(agent) do
    present?(agent) and is_nil(agent.turn_started_at) and
      not reservation_open?(agent) and not is_nil(agent.working_copy_id)
  end

  @doc """
  Offer a turn to agents left holding a task with no turn open.

  `runnable_state?/3` refuses an agent with an active task, which is right while
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
    |> Enum.filter(&(&1.working_copy_id == copy_id and stranded?(scope, &1)))
    |> Enum.each(&resume(scope, &1))

    :ok
  end

  # A held task with a turn ended to wait is not stranded: whatever it waits on
  # messages it (`Wake`, through `Waiting`).
  defp stranded?(scope, agent) do
    present?(agent) and is_nil(agent.turn_started_at) and
      not reservation_open?(agent) and not is_nil(Agent.active_task(agent)) and
      not is_nil(agent.working_copy_id) and Wake.decide(scope, agent, :resume) == :wake
  end

  # Each offer asks `Wake` before it writes the prompt to the transcript, so
  # an off agent's thread never shows a turn it was not given (39af5611).
  defp resume(scope, agent) do
    with :ok <- Wake.allow?(scope, agent, :resume),
         {:ok, {reserved, ref}} <- reserve_stranded(scope, agent.id) do
      turn_prompt = resume_prompt(reserved)

      offered =
        reserved
        |> Conversations.record_sent_to_agent(turn_prompt)
        |> Offers.record(reserved, :resume, {"task", Agent.active_task(reserved).id})

      case Transport.request_work_turn(
             reserved.working_copy_id,
             reserved,
             ref,
             turn_prompt,
             5_000
           ) do
        {:ok, :started} ->
          {:ok, ref}

        _error ->
          Offers.undelivered(offered)
          release(scope, reserved.id, ref)
      end
    end
  end

  # The prompt promises "the task below", so the task has to follow (0d3b800d).
  defp resume_prompt(agent) do
    task = Agent.active_task(agent)

    @resume_prompt <> "\n\n" <> task_line(task)
  end

  defp task_line(task) do
    "The task: `#{task.requirement_name}`, id #{task.id}. `evaluate_task` with " <>
      "that id when it is done."
  end

  # Same row lock and stamp as `reserve/2`, against `stranded?/2` rather than
  # `runnable_state?/3` — two events racing to resume one agent must still hand
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

      if agent && stranded?(scope, agent), do: reserve(agent), else: :not_stranded
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

  `event` is what `Wake` is asked about: `:question_answered` for an answer,
  `:blocker_resolved` for a released block or a denied tap-out. `subject` is
  what the offer is recorded against (`Offers`).
  """
  def offer_turn_with(scope, %Agent{} = agent, preface, event, subject \\ {"notice", nil})
      when is_binary(preface) do
    with {:ok, current} <- AgentsRepository.fetch_agent(scope, agent.id),
         :ok <- admit(scope, current, event),
         {:ok, {reserved, ref}} <- reserve(scope, current.id, event) do
      turn_prompt = turn_prompt(preface, event, reserved)

      offered =
        reserved
        |> Conversations.record_sent_to_agent(turn_prompt)
        |> Offers.record(reserved, notice_kind(event, subject), subject)

      case Transport.request_work_turn(
             reserved.working_copy_id,
             reserved,
             ref,
             turn_prompt,
             5_000
           ) do
        {:ok, :started} ->
          {:ok, ref}

        error ->
          Offers.undelivered(offered)
          release(scope, reserved.id, ref)
          error
      end
    else
      hold -> not_admitted(hold)
    end
  end

  # A released or denied task's notice is the whole turn (criterion 1864): the
  # generic "eligible work is available, no task has been selected" beneath
  # "resume task X" contradicted it.
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

        if agent.working_copy_id, do: consider_copy(scope, agent.working_copy_id, event)
        :ok
    end
  end

  @doc """
  Offer an idle agent back the tasks a resolved blocker released — only those
  its work now includes (criterion 1863). `header` says what resolved, `detail`
  is the decider's answer when there is one. `:subject` records the offer on
  something other than the task — a denied tap-out (criterion 1672).

  A released task whose requirement still waits on something is not offered:
  "resume it" would send the agent to `start_task` for a task it is refused.
  It is told what the task waits on instead, and `offer/2` offers the task
  once the graph does.
  """
  @spec wake_released(Scope.t(), Agent.t(), [map()], String.t(), String.t() | nil, keyword()) ::
          :ok
  def wake_released(scope, %Agent{} = agent, released, header, detail \\ nil, opts \\ []) do
    execution = work_for(scope, agent.role, agent)

    {waiting, ready} = Enum.split_with(released, &still_waiting?(&1, execution))

    if waiting != [],
      do: note_released(agent, with_detail(waiting_notice(header, waiting, execution), detail))

    case ready do
      [] ->
        if agent.working_copy_id,
          do: consider_copy(scope, agent.working_copy_id, :blocker_resolved)

        :ok

      [task | _] ->
        notice = with_detail("#{header}; #{resume_instruction(scope, ready)}", detail)
        subject = Keyword.get(opts, :subject) || {"task", task.id}
        wake_with_notice(scope, agent, notice, :blocker_resolved, subject)
    end
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

  # The exact call that resumes each task (probe 1867): naming the task by id
  # alone sent agents looking for which story it was on, and one called
  # `start_task` with no entity at all.
  defp resume_instruction(scope, tasks) do
    "resume " <>
      Enum.map_join(tasks, "; ", fn task ->
        "task #{task.id} with `start_task(#{start_args(scope, task)})`"
      end) <> "."
  end

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

  defp start_args(_scope, task), do: ~s(requirement_name: "#{task.requirement_name}")

  defp task_list(tasks),
    do: Enum.map_join(tasks, "; ", &"task #{&1.id} (`#{&1.requirement_name}`)")

  defp with_detail(notice, detail) when is_binary(detail) and detail != "",
    do: notice <> "\n\n" <> detail

  defp with_detail(notice, _detail), do: notice

  @doc """
  Tell an agent holding an active task that a blocked one was released, without
  offering it: resuming would make it a second active task (story 1080).
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
         {:ok, {reserved, ref}} <- reserve(scope, current.id, event),
         :ok <- still_offered(scope, reserved, ref, subject) do
      turn_prompt = offer_prompt(scope, reserved, subject)

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
      offered =
        reserved
        |> Conversations.record_sent_to_agent(turn_prompt)
        |> Offers.record(reserved, offer_kind(subject), subject)

      case Transport.request_work_turn(
             reserved.working_copy_id,
             reserved,
             ref,
             turn_prompt,
             5_000
           ) do
        {:ok, :started} ->
          {:ok, ref}

        error ->
          Offers.undelivered(offered)
          release(scope, reserved.id, ref)
          suppress_offer(scope, reserved, offer)
          error
      end
    else
      :none -> {:ok, :not_runnable}
      :stale -> {:ok, :not_runnable}
      true -> {:ok, :offer_declined}
      hold -> not_admitted(hold)
    end
  end

  # The offer is decided from a read taken before the reservation, and the
  # agent can move in between: a898df49 — product started its design task,
  # asked a question that blocked it, and was offered that same task as work,
  # because the claimable read predated the block. Its turn was then held by a
  # stale offer and the triage it should have been offered could not land.
  #
  # Held by the reservation, nothing else can offer this agent a turn, so
  # recomputing here is the answer as of now. A subject no longer offered
  # releases the reservation; the next observation offers what is there.
  defp still_offered(scope, reserved, ref, subject) do
    case offer(scope, reserved) do
      {:work, _offer, ^subject} ->
        :ok

      _moved ->
        release(scope, reserved.id, ref)
        :stale
    end
  end

  @doc """
  The main agent's check-in turn: one per cadence tick, with or without work.

  `render` builds the prompt from whether main's work offer stands — eligible
  graph work it has not declined past the damper. Admitted as `:cadence`, so
  only a running, continuous, idle main that is not waiting gets it; mid-turn
  it is skipped, not queued — the next tick comes round.
  """
  def request_cadence_turn(scope, %Agent{} = agent, render) when is_function(render, 1) do
    with {:ok, current} <- AgentsRepository.fetch_agent(scope, agent.id),
         :ok <- admit(scope, current, :cadence),
         {:ok, {reserved, ref}} <- reserve(scope, current.id, :cadence) do
      turn_prompt = render.(work_offered?(scope, reserved))

      offered =
        reserved
        |> Conversations.record_sent_to_agent(turn_prompt)
        |> Offers.record(reserved, :check_in, {"cadence", nil})

      case Transport.request_work_turn(
             reserved.working_copy_id,
             reserved,
             ref,
             turn_prompt,
             5_000
           ) do
        {:ok, :started} ->
          {:ok, ref}

        error ->
          Offers.undelivered(offered)
          release(scope, reserved.id, ref)
          error
      end
    else
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

  Called from the turn-ended path, which is the only place that knows a turn
  finished with nothing claimed. Until this existed the agent was re-offered
  the same work immediately and forever: ending a turn clears `turn_started_at`
  and the reservation, and declining leaves `active_task` nil, so every
  condition `runnable_state?/3` tests is satisfied again the instant the turn
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
  the agent straight back into `runnable_state?/3`, and the next observation
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

  # Questions-only offers still go quiet after one decline (b7a705ee). Graph
  # work no longer does: the ladder in `Offers` escalates it and then holds it
  # back from this agent alone (criteria 1739–1741).
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
  #
  # A turn the provider refused declined nothing either: the agent never saw
  # the offer. A refusal still standing at turn end is this turn's, since
  # `refusal_outlived/2` clears an older one first.
  defp declined?(_scope, agent, turn_started_at) do
    is_nil(Agent.active_task(agent)) and is_nil(agent.provider_refusal) and
      not closed_a_task?(agent, turn_started_at)
  end

  # No start time to compare against — an interrupted turn, or a caller that
  # does not track one. Treated as having done something, because charging an
  # agent with a refusal it cannot be shown to have made is the error that
  # costs work rather than the one that costs a turn.
  defp closed_a_task?(_agent, nil), do: true

  # A cancel stamps `completed_at` too, but claiming and dropping the offer is
  # declining it, not work (7169d3cf).
  defp closed_a_task?(%Agent{tasks: tasks}, %DateTime{} = turn_started_at) do
    Enum.any?(tasks || [], fn task ->
      task.status != :cancelled and not is_nil(task.completed_at) and
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

  defp reserve(scope, id, event) do
    Repo.transaction(fn ->
      agent =
        Repo.one(
          from a in Agent,
            where:
              a.id == ^id and a.project_id == ^scope.active_project_id and
                a.account_id == ^scope.active_account_id,
            lock: "FOR UPDATE"
        )

      if agent && runnable_state?(scope, agent, event),
        do: reserve(agent),
        else: :not_runnable
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

  # Whether a turn could start now — nothing in flight, nothing held, a copy to
  # run on. Whether this agent should be woken for it at all is `Wake`'s.
  defp idle?(agent) do
    present?(agent) and is_nil(agent.turn_started_at) and
      not reservation_open?(agent) and is_nil(Agent.active_task(agent)) and
      not is_nil(agent.working_copy_id)
  end

  # Its process alive now (`Agents.Presence`): nothing starts a turn in one that
  # is not there.
  defp present?(agent), do: Presence.present?(agent.project_id, agent.id)

  defp admit(scope, agent, event) do
    if idle?(agent), do: Wake.allow?(scope, agent, event), else: {:hold, :busy}
  end

  # Under the row lock: the same answer, without announcing it twice.
  defp runnable_state?(scope, agent, event),
    do: idle?(agent) and Wake.decide(scope, agent, event) == :wake

  # A reservation is the gap between stamping a turn and the agent reporting it
  # started — seconds. The turn itself is guarded by `turn_started_at`, so
  # nothing legitimate sits in this window for minutes, and five is generous.
  #
  # It has to expire because every path that clears it needs a live process:
  # `release/3` on a failed dispatch, and the agent's own completion. The case
  # that strands one is the process going away after the transport accepted it.
  # A harness restart brings the agent back present without passing through
  # anything that clears it, so the row carries the stale reservation over.
  #
  # Measured on the math project 2026-09-22: coding stamped a reservation at
  # 01:53, the harness restarted three times, and the row carried it through
  # every one. `runnable_state?/3` requires no open reservation, so the agent
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
  # a second one (story 1080) — then `get_next_requirement`'s head, or main's
  # questions when there is no graph work.
  defp offer_subject(agent, nodes) do
    case released_tasks(agent, nodes) do
      [task | _] -> released_subject(task)
      [] -> graph_subject(nodes)
    end
  end

  defp graph_subject([{type, id, name} | _nodes]), do: {"requirement", "#{type}:#{id}:#{name}"}
  defp graph_subject([]), do: {"questions", nil}

  # Released and still claimable: one the graph no longer offers would be
  # refused by `start_task`, and offering it first would hide the rest.
  defp released_tasks(%Agent{tasks: tasks}, nodes) do
    Enum.filter(tasks || [], fn task ->
      task.status == :blocked and not is_nil(task.blocker_resolved_at) and
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

  defp offer_prompt(scope, agent, {"task", id}) do
    tasks = Enum.filter(agent.tasks, &(&1.id == id))
    "Your blocker was released; #{resume_instruction(scope, tasks)}"
  end

  defp offer_prompt(scope, agent, {"tap_out", id}) do
    tasks = Enum.filter(agent.tasks, &(&1.blocker_id == id))
    "Your tap-out was declined; #{resume_instruction(scope, tasks)}"
  end

  defp offer_prompt(scope, agent, {"requirement", key}) do
    case Offers.standing(agent.id)[key] do
      %{ignored: 1} -> prompt(agent) <> "\n\n" <> detail(scope, agent, key)
      %{ignored: n} when n > 1 -> prompt(agent) <> "\n\n" <> alternatives(scope, agent, key)
      _first -> prompt(agent)
    end
  end

  defp offer_prompt(_scope, agent, _subject), do: prompt(agent)

  # The second offer of the same work says more about it (criterion 1739).
  defp detail(scope, agent, key) do
    case Enum.find(offerable(scope, agent), &(node_key(&1) == key)) do
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

  # The third names what else it could take (criterion 1740).
  defp alternatives(scope, agent, key) do
    others =
      scope
      |> offerable(agent)
      |> Enum.reject(&(node_key(&1) == key))
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

  # Hashed rather than stored whole: the comparison is equality and nothing
  # reads the parts, so the column stays a fixed width no matter how much work
  # a role has. Sorted first — the offer is a set, and an order change would
  # read as a changed offer every pass and defeat the whole guard.
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

  # An offer of questions alone is held after one decline, and for as long as
  # the set is unchanged (b7a705ee). Neither reason above applies to it: a
  # question does not become answerable by waiting, and every change that
  # matters — one raised, answered, escalated — changes the set, so the
  # fingerprint moves and the offer is made again. Main's cadence check-in
  # still lists them. Measured 2026-10-02: main was re-offered one question it
  # believed it had escalated four times in six minutes, and every turn read
  # "no change".
  defp already_declined?(%{declined_offer: declined} = agent, offer, questions_only?)
       when not is_nil(declined) and declined == offer do
    repeats_spent?(agent.declined_offer_count, questions_only?) and
      within_window?(agent.declined_offer_at, questions_only?)
  end

  defp already_declined?(_agent, _offer, _questions_only?), do: false

  defp repeats_spent?(n, true), do: is_integer(n) and n >= 1
  defp repeats_spent?(n, false), do: is_integer(n) and n >= @max_repeats

  # Recorded by a build that did not stamp the time. Treated as expired rather
  # than open — the same reasoning as `reservation_open?/1` in reverse: here the
  # conservative reading is the one that keeps the agent reachable.
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

  # Teammates' questions start with whoever `RoleProfile.wakes_on?` names for
  # `:teammate_question` — the main agent (story 1052), and product for the
  # criteria questions routed to it (8c91d5bc). Each wakes for its own holder.
  # Their ids, not whether there are any, so a new question is a new offer.
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

  # `list_notifications` is code mode, like most of the catalogue — a main agent
  # reaches it from inside a script, and saying so is the difference between a
  # tool it can use and one it reports as broken.
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

  # Claimable work less what this agent ignored three times or declined
  # (criterion 1741): held back from it alone, so a teammate is still offered it.
  defp offerable(scope, agent) do
    standing = Offers.standing(agent.id)

    scope
    |> claimable_work(agent)
    |> Enum.reject(&match?(%{held?: true}, standing[node_key(&1)]))
  end

  defp node_key(node), do: "#{node.entity_type}:#{node.entity_id}:#{node.name}"

  @doc """
  The work for one caller: `Requirements.story_execution/4`'s status, its
  ordered `actionable` list, the `wave` cut from it, and why.

  The one answer to "what can this role do next here" (a31f1cd6). The turn
  offer, the stop menu, `get_next_requirement` and `start_task`'s resume check
  all read it, so none of them names work another refuses. "First" is the head
  of `actionable`; "any" is whether it is empty.

    * `role` — whose requirements, through `RoleProfile.requirements`; `nil` is
      every role's.
    * `owner` — an `Agent` is answered at its own checkout, without what
      `withheld?/3` holds back from it. Anything else (a `Session`, `nil`) is
      answered at the scope's checkout with nothing withheld.

  Withholding happens before the story's wave is cut.

  An agent with an active story (`bound_story_id/1`) is offered that story's
  work and nothing else (4292518a): no project-level work and no other story's,
  and its story is not held back by unsatisfied project-level prerequisites.
  Without one it is answered as before.

  Options: `:story_number` narrows to that story or refuses, as
  `get_next_requirement` takes it; `:owners` is the project's agents, so a
  fleet read lists them once.
  """
  @spec work_for(Scope.t(), atom() | nil, term(), keyword()) :: map()
  def work_for(scope, role, owner \\ nil, opts \\ [])

  # An agent bound to an issue, or just freed of one with nothing to fall
  # back on, bypasses the graph entirely — an issue is not in it
  # (`Agents.IssueWork`, story 1091). Checked ahead of everything else, the
  # same standing as `bound_story_id/1`: offered that and nothing else.
  def work_for(%Scope{} = scope, _role, %Agent{issue_id: id} = owner, opts)
      when is_binary(id) do
    scope = at_copy(scope, owner)
    execution = IssueWork.execution(scope, owner)
    withheld? = withholding(scope, owner, opts)
    actionable = Enum.reject(execution.actionable, withheld?)

    if execution.actionable != [] and actionable == [] do
      %{
        execution
        | status: :blocked,
          actionable: [],
          wave: [],
          remaining: 0,
          reason:
            "The issue's current task is held by a teammate or blocked on an unresolved decision."
      }
    else
      execution
    end
  end

  def work_for(%Scope{} = scope, _role, %Agent{team_free_at: %DateTime{}} = owner, _opts) do
    IssueWork.execution(at_copy(scope, owner), owner)
  end

  def work_for(%Scope{} = scope, role, owner, opts) do
    scope = at_copy(scope, owner)
    number = Keyword.get(opts, :story_number)
    withheld? = withholding(scope, owner, opts)
    assignment = assignment(scope, owner)

    scope
    |> Requirements.story_execution(role, number, withheld?, assignment)
    |> advance(scope, team_member?(owner), fn assignment ->
      Requirements.story_execution(scope, role, number, withheld?, assignment)
    end)
  end

  # The team takes its next story when its story is complete for all of it
  # (a31f1cd6). John: "fine for the team to take a new story from the working
  # copy when the team collectively finishes a story." The whole team moves,
  # through `Assignment.advance/4`, which locks the team's rows so two
  # teammates arriving at once move it once; then the answer is read again for
  # the story the team is on now. Never on the main copy: `advance/4` refuses
  # it, and the main agent reads `:project`, which has no story to finish.
  #
  # Only a team member's own read moves the team. A session, product or the
  # main agent looking at the copy sees the finished story as finished.
  defp advance(
         %{status: :complete, story: %{id: from}, next_story: %{id: to}} = execution,
         scope,
         true,
         read
       ) do
    case Assignment.advance(scope, scope.active_working_copy_id, from, to) do
      {:ok, :moved} -> read.(bind(team(scope.active_working_copy_id)))
      {:error, _reason} -> execution
    end
  end

  defp advance(execution, _scope, _team_member?, _read), do: execution

  defp team_member?(%Agent{role: role}), do: RoleProfile.scope(role) == :story
  defp team_member?(_owner), do: false

  # Whose story the answer is about (a31f1cd6). The main agent reads none —
  # story work happens on feature copies, never on main. Everyone else reads
  # the team's: a team member (coding, QA) the story it holds, product and a
  # session the story their copy's team holds.
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
  The story `agent` is bound to, or nil (4292518a).

  John: an agent on a working copy with an active story is bound by that story,
  and while it is active is not even offered work outside it. The active story
  is the agent's own `story_id`, which only a team member — coding or QA — ever
  holds (`Agent.changeset/2`, `Assignment`). The main agent reads the project
  and product reads every story from the main copy; neither holds one, so
  neither is bound, and an agent without a story is answered as before.

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

  defp at_copy(scope, %Agent{working_copy_id: id}) when is_binary(id),
    do: %{scope | active_working_copy_id: id}

  defp at_copy(scope, _owner), do: scope

  defp withholding(scope, %Agent{} = agent, opts) do
    owners = Keyword.get(opts, :owners) || AgentsRepository.list_agents(scope)
    &withheld?(owners, agent, &1)
  end

  defp withholding(_scope, _owner, _opts), do: fn _node -> false end

  @doc """
  `actionable/4` for this agent's role at its own checkout.

  Public so the main agent's "this agent has work" is this answer rather than a
  second one that disagrees (4849f20b). `owners` saves a reader asking for a
  whole fleet from listing the project's agents once per agent.
  """
  @spec claimable_work(Scope.t(), Agent.t(), [Agent.t()] | nil) :: [map()]
  def claimable_work(scope, agent, owners \\ nil),
    do: actionable(scope, agent.role, agent, owners: owners)

  @doc """
  Whether a task at `agent`'s checkout withholds `node` from it: another
  agent's live task, or its own blocked on an unresolved blocker.

  Its own active task is not withheld — `start_task` resumes that (467310a7).
  """
  @spec withheld?([Agent.t()], Agent.t(), map()) :: boolean()
  def withheld?(owners, agent, node) do
    owners
    |> Enum.filter(&(&1.working_copy_id == agent.working_copy_id))
    |> Enum.any?(fn owner ->
      mine? = owner.id == agent.id
      Enum.any?(owner.tasks || [], &holds_node?(&1, mine?, node))
    end)
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
