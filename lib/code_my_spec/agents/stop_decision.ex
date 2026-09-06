defmodule CodeMySpec.Agents.StopDecision do
  @moduledoc """
  What the orchestrator says to an agent that has just ended a turn, delivered
  as a message.

  ## The second renderer, not a second decision

  `Hooks.Stop` answers an external agent's Stop hook. It produces the same
  thing this does — the problem summary from `Validation.validate_stop/3` and
  the directive from `Validation.Menu.render/2` — and wraps it in the hook
  protocol's envelope. An agent running under Alloy fires no hooks, so none of
  it reached one: `validate_stop/3` had exactly two callers, both hooks, and
  the engine called neither. Issue `f0cc65ab`, now stories 1042 and 1043.

  So the content is shared and only the delivery differs. That is the whole
  design, in John's words: "for external agents we deliver via queueing to the
  stop hook, for the internal one we use messaging."

  ## What does not carry across, and why that is the point

  The hook has a `pending_analysis?` branch that tells the agent to
  `curl .../analysis/wait` and stop again, because a hook must answer *now* and
  the analyzers have not finished. There is no counterpart here and there must
  not be. An internal agent is a live process: it stops, the analyzers run, and
  the answer is sent when it exists. Story 1043 states it as a rule — the agent
  is never told to wait — and the one-turn-late problem story 1042 was written
  about does not arise on this path.

  The hook's `@total_response_cap` does not carry either. It is sized for a hook
  response; a message into an agent's queue has its own budget.

  ## Silence is a real answer

  Nothing is sent when there is nothing to say. A message wakes the agent, and
  an agent woken to be told its tree is clean has been charged a turn for no
  information — which is the failure the analyzer alert's own silences exist to
  avoid, arriving through a louder door.
  """

  require Logger

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Conversations
  alias CodeMySpec.Sessions
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation

  @doc """
  Decide, and tell the agent if there is anything to tell it.

  `:ok` either way. A decision nobody could deliver is not a failure of the
  turn that triggered it, and raising here would take down the channel process
  carrying an agent's transcript.
  """
  @spec deliver(Scope.t(), Agent.t()) :: :ok
  def deliver(%Scope{} = scope, %Agent{} = agent) do
    # Opened once, before anything is recorded into it, and that is not a
    # formality. `record_orchestrator_action/3` looks the conversation up by
    # agent and answers `:ok` when there is none — correct for a caller that
    # must not crash, and silent. An agent that has never spoken has no
    # conversation, so its very first thing to hear is exactly the one that
    # would vanish. Every turn event already opens one for the same reason.
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      agent.id
    )

    case decide_with_key(scope, agent) do
      {nil, _key} ->
        :ok

      # A continuation is not a repeat. R8 counts identical *blocks* — the same
      # findings refusing the same agent turn after turn — and a loop handing
      # back the menu after a turn that passed is the opposite of that: work got
      # done. Feeding it through `stuck?/2` would count five successful turns as
      # five identical failures and end the loop silently at the fifth, which is
      # the one failure mode a loop must not have. The escape is `tap_out`,
      # offered in the menu itself.
      {message, :continuing} ->
        send_to(scope, agent, message)

      {message, key} ->
        case stuck?(agent, key) do
          true -> :ok
          false -> send_to(scope, agent, message)
        end
    end

    # Beside the decision, not instead of it. On the external path
    # `nudge_open_task/2` fires via `tap/2` on every stop with an open task,
    # independently of whether anything blocked — an agent that stops with a
    # failing compile *and* work open has two different things to act on, and
    # collapsing them loses one.
    nudge_open_task(scope, agent)
  rescue
    error ->
      Logger.warning(
        "[StopDecision] could not decide for agent #{agent.id}: " <> Exception.message(error)
      )

      :ok
  end

  @doc """
  Tell one agent that work of its kind is available.

  Story 538's R12, delivered. An agent whose queue emptied was told nothing and
  stopped — correctly, under R6 — and then nothing existed that would bring it
  back: product finishes a spec unblocking three coding requirements and the
  coding agent sits idle with no reason to look again.

  Here rather than in `Agents` because this is the same act as a stop decision
  and has to travel the same way — recorded before it is dispatched, dispatched
  off this process so a busy agent is queued rather than interrupted (criterion
  3053), and silent when there is nothing to say. A second delivery path would
  drift from this one, and the drift would be invisible until an agent stopped
  hearing from one of them.

  Silent for a role with an empty queue, for the reason this module keeps
  everywhere: a message wakes a process and costs it a turn, and an agent woken
  to be told there is nothing has been charged for no information.

  Not a decision about whether to keep going — that is `deliver/2`, at the end
  of a turn. This is the nudge that gets an idle agent to take one.
  """
  @spec wake(Scope.t(), Agent.t()) :: :ok
  def wake(%Scope{} = scope, %Agent{} = agent) do
    case Validation.Menu.render(scope, agent.continuous == true, agent.role) do
      "" ->
        :ok

      menu ->
        Conversations.find_or_create_agent_conversation(
          scope.active_account_id,
          scope.active_project_id,
          agent.id
        )

        send_to(scope, agent, "Work of your kind is available." <> menu)
    end
  rescue
    error ->
      Logger.warning(
        "[StopDecision] could not wake agent #{agent.id}: " <> Exception.message(error)
      )

      :ok
  end

  @doc """
  The decision as a value, or `nil` when there is nothing to say.

  Public because it is the half both transports share. A hook rendering this
  into its envelope and a message carrying it verbatim have to be looking at
  the same sentence, or the two agents get different accounts of one tree.
  """
  @spec decide(Scope.t(), Agent.t()) :: String.t() | nil
  def decide(%Scope{} = scope, %Agent{} = agent) do
    {message, _key} = decide_with_key(scope, agent)
    message
  end

  # Threshold and behaviour copied from `Hooks.Stop`'s R8 escape, which exists
  # because eight consecutive blocks on a finding belonging to another story
  # were observed spending a whole budget unattended.
  #
  # Keyed on the **agent**, not a session. The external counter lives on the
  # session — `Sessions.record_eval_feedback/3` — and an agent under Alloy has
  # none. John's call, and it is the same shift issue `927c2b78` wanted
  # elsewhere: the session was never the right identity for "who was told".
  #
  # On the blocking *key* rather than the rendered sentence, because
  # `Validation.blocking_key/1` is computed from the finding set. Counting the
  # text would reset every time a count or an age changed inside an otherwise
  # identical block, which is exactly what R8's key exists to avoid.
  #
  # In `:persistent_term` for the reason `Analysis.Alert` uses it: it is worth
  # one duplicate after a restart, which is cheaper than a column and a write
  # per turn.
  @stuck_threshold 5

  defp decide_with_key(%Scope{} = scope, %Agent{} = agent) do
    # The role travels with the id because the decision depends on it: whether a
    # `block_changed` source is enforced for an agent with no session turns on
    # whether that agent writes code. Passed from the struct rather than looked
    # up again inside `Validation`, which has the id and would have to query for
    # what the caller is already holding.
    case Validation.validate_stop(scope, nil, agent_id: agent.id, agent_role: agent.role) do
      {:error, reason, key} ->
        {reason <> Validation.Menu.render(scope, agent.continuous == true), key}

      {:ok, _result} ->
        keep_working(scope, agent)
    end
  end

  # Nothing is blocking. Whether the agent hears anything depends on the mode it
  # is in, and that is the whole of story 538's R2 on this path: continuous is a
  # mode on the agent, and it decides what to do with the answer to "is there
  # work", never whether the question is asked.
  #
  # An agent not in the loop is told nothing, and that is not the same silence
  # the hook keeps. The hook is already answering a request, so a sentence there
  # is free; here a message *wakes a process* and costs it a turn. This module's
  # own rule — an agent woken to be told its tree is clean has been charged for
  # no information — outranks reporting, so R11's "say what is outstanding"
  # belongs to the hook's response and not to a message nobody asked for.
  #
  # `Menu.render/2` answers `""` when no class is live, which is the loop's
  # terminus: nothing left to do, nothing said, the agent stops. That is R6
  # arriving for free rather than as a second emptiness check that could
  # disagree with the first.
  defp keep_working(%Scope{} = scope, %Agent{continuous: true} = agent) do
    # Narrowed to this agent's own role — R10. A coding agent asked whether the
    # *project* has work is held open by product's queue and QA's, neither of
    # which it can do anything about, and it would loop until somebody else
    # finished. Asked about its own, it goes home when its own runs out, which
    # is R6.
    case Validation.Menu.render(scope, true, agent.role) do
      "" -> {nil, nil}
      menu -> {"Your turn is done and the loop is still running." <> menu, :continuing}
    end
  end

  defp keep_working(%Scope{}, %Agent{}), do: {nil, nil}

  defp stuck?(%Agent{} = agent, key) do
    slot = {__MODULE__, agent.id}
    seen = :persistent_term.get(slot, nil)

    count =
      case seen do
        {^key, n} -> n + 1
        _ -> 1
      end

    :persistent_term.put(slot, {key, count})

    if count > @stuck_threshold do
      Logger.info(
        "[StopDecision] agent #{agent.id} has been told the same thing #{count} times and " <>
          "has not acted on it — leaving it alone until something else lands"
      )

      true
    else
      false
    end
  end

  # The same nudge `Hooks.Stop` records, found a different way.
  #
  # The external path reads the task off the stopping session, which is where a
  # task is embedded and where a hook's payload points. An agent under Alloy has
  # no session — and can still hold a task, because an orchestrator assigns one
  # naming its `agent_id` and the task lives on the orchestrator's session. So
  # the lookup is by agent, and the wording is the hook's verbatim.
  #
  # John, on why the orchestrator must not simply close it: "the agent should be
  # nudged to complete its own task ... it should always be at the agent's
  # discretion." The whole call travels with it, task id included, because being
  # told to make a call and being told to go read about one are different
  # instructions — QA of story 985 found the second reads as somewhere to go
  # looking.
  defp nudge_open_task(scope, agent) do
    case Sessions.open_task_for_agent(scope, agent.id) do
      nil ->
        :ok

      task ->
        Conversations.record_orchestrator_action(
          agent,
          "You stopped with #{task.requirement_name} still open. Close it yourself when " <>
            "it is done — nothing will do it for you.",
          tool: ~s(evaluate_task task_id: "#{task.id}"),
          kind: "nudge"
        )

        :ok
    end
  end

  # Through the transport every other message to an agent goes through, so an
  # agent mid-turn is queued rather than interrupted — the engine decides
  # started-or-queued without running anything, and a decision that barged into
  # a turn in flight would lose whatever that turn was part-way through.
  defp send_to(scope, agent, message) do
    # Recorded as well as sent, and recorded first.
    #
    # `Conversations.record_orchestrator_action/3` is the half story 1041
    # already shares — it takes an agent and knows nothing about how that agent
    # runs, which is why the handover shows up for both kinds today. The
    # decision is the same sort of thing: something the orchestrator did *to*
    # the agent, and a transcript that shows only what the agent did is the gap
    # 1041 exists to close.
    #
    # Before the dispatch, because delivery can fail — a halted agent has
    # nobody to tell — and what the orchestrator decided is true whether or not
    # anyone was there to hear it. The conversation was opened by `deliver/2`.
    Conversations.record_orchestrator_action(agent, message, kind: "decision")

    ref = "stop-decision-" <> Ecto.UUID.generate()

    # Off this process, and that is not an optimisation.
    #
    # `message_agent` is a `GenServer.call` to the process holding the working
    # copy, and that process runs the whole turn inside the call. The turn ends
    # while it is still there, so `deliver/2` runs in it — and the dispatch is
    # another call to the same pid. A process cannot call itself: it raised
    # `:calling_self`, the decision was lost, and the operator's `message_agent`
    # failed with a crash instead of a result. Issue `ad8c1213`, found the
    # moment there was finally a decision to deliver.
    #
    # It is also what criterion 3053 asks for in the first place. "A busy agent
    # is queued, not interrupted" cannot be true of a send made synchronously
    # inside the turn it is about; the message has to join the agent's queue the
    # way any other message does.
    #
    # Nothing is waiting on the answer. The record is already written above, and
    # the only outcomes below are `:ok` and a line in the log.
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      dispatch(scope, agent, ref, message)
    end)

    :ok
  end

  defp dispatch(scope, agent, ref, message) do
    case CodeMySpec.Agents.Transport.impl().dispatch_message(
           scope.active_working_copy_id,
           agent,
           ref,
           message,
           dispatch_timeout()
         ) do
      {:ok, _} ->
        :ok

      # A halted agent is not owed one, and this is not a fault. It stopped on
      # purpose; there is nobody to tell, which is a state rather than a failed
      # delivery. Logged at info so the absence is visible without reading as
      # something to fix.
      {:error, reason} ->
        Logger.info(
          "[StopDecision] agent #{agent.id} was not told (#{inspect(reason)}) — " <>
            "nothing is wrong if it has stopped"
        )

        :ok
    end
  end

  defp dispatch_timeout, do: Application.get_env(:code_my_spec, :stop_decision_timeout, 10_000)
end
