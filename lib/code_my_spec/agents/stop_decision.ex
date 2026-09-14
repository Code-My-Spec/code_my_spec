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
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Conversations
  alias CodeMySpec.Notifications
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation

  @doc """
  Decide, and tell the agent if there is anything to tell it.

  `:ok` either way, on the paths that resolve. A decision that raises crashes
  the channel process carrying this turn — supervised, so it restarts — rather
  than being logged and dropped where nobody would see it.
  """
  @spec deliver(Scope.t(), Agent.t(), keyword()) :: :ok
  def deliver(scope, agent, opts \\ [])

  def deliver(%Scope{} = scope, %Agent{} = agent, opts) do
    # Opened once, before anything is recorded into it, and that is not a
    # formality. `record_sent_to_agent/2` looks the conversation up by
    # agent and answers `:ok` when there is none — correct for a caller that
    # must not crash, and silent. An agent that has never spoken has no
    # conversation, so its very first thing to hear is exactly the one that
    # would vanish. Every turn event already opens one for the same reason.
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      agent.id
    )

    decided = decide_with_key(scope, agent, opts)

    case decided do
      {nil, _key} ->
        :ok

      # A menu that repeats byte-for-byte is a repeat regardless of the key it
      # arrived under — genuine progress changes the menu (a count drops, a
      # task id changes), so this only ever fires when nothing actually moved.
      # Keyed on the rendered text itself, in its own `stuck?` slot, so a
      # continuing agent that is genuinely stuck stops hearing the same
      # "your turn is done" every turn instead of forever, same as any other
      # class of repeat. The escape while it is silenced is `tap_out`, offered
      # in the menu itself.
      {message, :continuing} ->
        if stuck?(agent, message, :continuing), do: :ok, else: send_to(scope, agent, message)

      {message, key} ->
        if stuck?(agent, key), do: :ok, else: send_to(scope, agent, message)
    end
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

  ## The same "asked and is allowed to stop" rule `deliver/2` has

  `wake_project_roles/2` calls this for every continuous, running agent on
  any graph change project-wide — not this agent's own turn ending, somebody
  else's, anywhere in the project. An agent with a question or a tap-out
  request open has nothing to do about that until it hears back, the same as
  `decide_with_key/3`'s reasoning, and had no such check here at all: it was
  told "work of your kind is available" on every unrelated change while
  waiting, sometimes under a minute apart on a project several worktrees
  edit at once, and had to spend a turn saying so each time.

  ## A working agent is never woken

  John's rule, and it settles what two criteria had been disagreeing about: "a
  running agent never gets a wake message. If the agent is running and it
  completes something and that triggers a wake message to itself — which is a
  bit dumb anyway — we would not deliver that message to the working agent
  because it's already working."

  A wake exists to bring an idle agent back. An agent mid-turn is coming back
  on its own, and the decision at the end of that turn is where it finds out
  what is next — so a wake landing during the turn is at best a duplicate of
  the stop reply and at worst an interruption charged as a turn.

  That is exactly what an agent's own completion produced. `TaskEvaluator`
  wakes the copy's roles from inside the stop hook (`stop.ex:511` →
  `wake_the_others/2`), so an agent whose own turn completed its own task was
  woken by itself, in the same request that was about to hand it the menu in
  its reply. Criteria 3180 and 3196 are that duplicate. Criterion 3108 is the
  case that must still get through — a *different* agent, idle, unblocked by
  work somebody else finished.

  `turn_started_at` is the signal rather than `status`, because it answers the
  question being asked — is this agent mid-response — and `:running` does not:
  it is written on a clean start and survives until a clean stop, so it is true
  of an idle agent all day. Story 1054's criterion 3297 put the column there
  for this shape of question.
  """
  @spec wake(Scope.t(), Agent.t()) :: :ok
  def wake(%Scope{} = scope, %Agent{} = agent) do
    cond do
      Notifications.awaiting_answer?(agent.id) -> :ok
      working?(agent) -> :ok
      true -> do_wake(scope, agent)
    end
  end

  defp working?(%Agent{turn_started_at: %DateTime{}}), do: true
  defp working?(%Agent{}), do: false

  defp do_wake(scope, agent) do
    case Validation.Menu.render(scope, agent.continuous == true, agent.role, agent) do
      "" ->
        :ok

      menu ->
        message = "Work of your kind is available." <> menu

        # Same reasoning as `deliver/2`'s `:continuing` branch: this fires on
        # every graph change project-wide, and a change unrelated to this
        # agent's own menu renders the identical text again. Keyed on the
        # message rather than the event, so a real change to what this agent
        # can see still gets through.
        if stuck?(agent, message, :wake) do
          :ok
        else
          Conversations.find_or_create_agent_conversation(
            scope.active_account_id,
            scope.active_project_id,
            agent.id
          )

          send_to(scope, agent, message)
        end
    end
  end

  @doc """
  The decision as a value, or `nil` when there is nothing to say.

  Public because it is the half both transports share. A hook rendering this
  into its envelope and a message carrying it verbatim have to be looking at
  the same sentence, or the two agents get different accounts of one tree.
  """
  @spec decide(Scope.t(), Agent.t()) :: String.t() | nil
  def decide(%Scope{} = scope, %Agent{} = agent) do
    {message, _key} = decide_with_key(scope, agent, [])
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

  # An agent that asked a person something is allowed to stop.
  #
  # Refusing it is the shape of loop that looks like diligence and is waste: the
  # agent has nothing to do until a human types, the menu it would be handed
  # says so in a line it cannot act on, and every stop costs a turn. John: "it
  # shouldn't hit the agent with the stop hook."
  #
  # Nothing is lost by stopping, because the answer comes back as a message —
  # `Notifications.answer_question_request/2` dispatches it through
  # `Agents.send_to_agent/3` the moment it lands. That is the difference from
  # `check_answer`, which needs a running agent to do the checking and so cannot
  # be combined with going quiet.
  #
  # Above the validation call rather than below it: a blocked tree is still no
  # reason to hammer an agent that cannot act on anything until it hears back,
  # and the findings will still be there when it wakes.
  defp decide_with_key(%Scope{} = scope, %Agent{} = agent, opts) do
    if Notifications.awaiting_answer?(agent.id) do
      {nil, nil}
    else
      decide_with_work(scope, agent, opts)
    end
  end

  defp decide_with_work(%Scope{} = scope, %Agent{} = agent, opts) do
    # The role travels with the id because the decision depends on it: whether a
    # `block_changed` source is enforced for an agent with no session turns on
    # whether that agent writes code. Passed from the struct rather than looked
    # up again inside `Validation`, which has the id and would have to query for
    # what the caller is already holding.
    validate_opts = Keyword.merge(opts, agent_id: agent.id, agent_role: agent.role)

    case Validation.validate_stop(scope, nil, validate_opts) do
      {:error, reason, key} ->
        # The role goes here too. A refusal names the findings and then says
        # what to do next, and "next" is this agent's own work for the same
        # reason it is on every other path — a blocked coding agent pointed at
        # QA's queue is being told to do something it will not do.
        {reason <> Validation.Menu.render(scope, agent.continuous == true, agent.role, agent),
         key}

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
    case Validation.Menu.render(scope, true, agent.role, agent) do
      "" -> {nil, nil}
      menu -> {"Your turn is done and the loop is still running." <> menu, :continuing}
    end
  end

  defp keep_working(%Scope{}, %Agent{}), do: {nil, nil}

  # `tag` separates the counters — `:decision`, `:continuing`, `:wake` — so one
  # slot per agent doesn't let them overwrite each other's count and reset a
  # threshold none of them reached on their own.
  defp stuck?(agent, key, tag \\ :decision)

  defp stuck?(%Agent{} = agent, key, tag) do
    slot = {__MODULE__, tag, agent.id}
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

  # Through the transport every other message to an agent goes through, so an
  # agent mid-turn is queued rather than interrupted — the engine decides
  # started-or-queued without running anything, and a decision that barged into
  # a turn in flight would lose whatever that turn was part-way through.
  defp send_to(scope, agent, message) do
    # Recorded as well as sent, and recorded first.
    #
    # `Conversations.record_sent_to_agent/2` because this dispatches through the
    # transport directly rather than through `Agents.dispatch_message/3`, which
    # is the thing that normally records. Without it the decision reaches the
    # agent and appears in no transcript.
    #
    # Before the dispatch, because delivery can fail — a halted agent has
    # nobody to tell — and what the orchestrator decided is true whether or not
    # anyone was there to hear it. The conversation was opened by `deliver/2`.
    Conversations.record_sent_to_agent(agent, message)

    deliver_message(scope, agent, message)
  end

  # The dispatch half, shared. `send_to/3` records a decision and sends it; the
  # nudge records its own line with its own `kind` and sends through here, so
  # there is one definition of how a message reaches an agent and no second one
  # to forget to call.
  defp deliver_message(scope, agent, message) do
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

  # The agent's own working copy, not the caller's.
  #
  # These were the same thing while the only caller was `deliver/2`, which runs
  # at the end of a turn in the copy the turn happened in. R12's wake broke that
  # assumption: it is triggered by somebody else — a person clicking a control, an
  # agent finishing a task in a different checkout — and the scope it carries is
  # theirs. So the message was looked up against the wrong copy's harness and
  # answered `:harness_not_connected` with the right harness connected and
  # reconciling that exact copy.
  #
  # It reported as a delivery failure rather than a wrong address, because both
  # produce the same silence: the message is recorded on the agent's
  # conversation before it is sent, so the transcript showed three agents told
  # and nothing happening. John, looking at the copy: "I don't see those agents
  # running."
  #
  # `agent.working_copy_id` is the only thing here that knows where the agent
  # is, and it is right on every path — including the original one, where it
  # equals what the scope carried.
  defp dispatch(_scope, agent, ref, message) do
    case Transport.impl().dispatch_message(
           agent.working_copy_id,
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
