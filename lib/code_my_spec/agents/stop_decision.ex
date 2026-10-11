defmodule CodeMySpec.Agents.StopDecision do
  @moduledoc """
  What the orchestrator says to an agent that has just ended a turn, delivered
  as a message.

  ## The second renderer, not a second decision

  `Hooks.Stop` answers an external agent's Stop hook. It produces the same
  thing this does — the problem summary from `Validation.validate_stop/3` and
  the directive from `Agents.Menu.render/2` — and wraps it in the hook
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
  alias CodeMySpec.Agents.Menu
  alias CodeMySpec.Agents.Wake
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations
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
    # `Wake` decides whether it hears anything: off, or waiting on something
    # that messages it when it lands (anything said here only buys a "still
    # waiting" turn), and it is not nudged.
    case Wake.allow?(scope, agent, :nudge) do
      :ok -> decide_and_deliver(scope, agent, opts)
      {:hold, _reason} -> :ok
    end
  end

  defp decide_and_deliver(scope, agent, opts) do
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
        request_turn(scope, agent)

      # A menu that repeats byte-for-byte is a repeat regardless of the key it
      # arrived under — genuine progress changes the menu (a count drops, a
      # task id changes), so this only ever fires when nothing actually moved.
      # Keyed on the rendered text itself, in its own `stuck?` slot, so a
      # continuing agent that is genuinely stuck stops hearing the same
      # "your turn is done" every turn instead of forever, same as any other
      # class of repeat. The escape while it is silenced is `tap_out`, offered
      # in the menu itself.
      {message, :continuing} ->
        continuing(scope, agent, message, Agent.active_task(agent))

      {message, key} ->
        if stuck?(agent, key),
          do: :ok,
          else: send_to(scope, agent, message, {:problems, {"problem_set", problem_key(key)}})
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

  defp decide_with_key(%Scope{} = scope, %Agent{} = agent, opts) do
    decide_with_work(scope, agent, opts)
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
        {reason <> Menu.render(scope, agent.continuous == true, agent.role, agent), key}

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
    case Menu.render(scope, true, agent.role, agent) do
      "" -> {nil, nil}
      menu -> {"Your turn is done and the loop is still running." <> menu, :continuing}
    end
  end

  defp keep_working(%Scope{}, %Agent{}), do: {nil, nil}

  # `tag` separates the counters — `:decision`, `:continuing`, `:wake` — so one
  # slot per agent doesn't let them overwrite each other's count and reset a
  # threshold none of them reached on their own.
  # A turn that ended with no active task is the runnable check's moment: the
  # agent has nothing open, so eligibility is worth asking about once. With a
  # task still active the menu is the answer instead, subject to the same
  # repeat-silencing as any other class.
  defp continuing(scope, agent, _message, nil), do: request_turn(scope, agent)

  # The menu is one offer per held task: it only goes out while a task is
  # held, and every item on it is "carry on". Recording each item would claim
  # the agent was offered choices the menu does not ask it to make.
  defp continuing(scope, agent, message, task) do
    if stuck?(agent, message, :continuing),
      do: :ok,
      else: send_to(scope, agent, message, {:menu, {"menu", task.id}})
  end

  # `Validation.blocking_key/1` is a hash already; anything else is made one.
  defp problem_key(key) when is_binary(key), do: key

  defp problem_key(key),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(key)) |> Base.encode16(case: :lower)

  # Off this process for the reason `dispatch` is (ad8c1213): `deliver/3` runs
  # inside the harness channel at turn end, and the turn request is a call back
  # into that channel, refused as a would-be deadlock (104bcb23).
  defp request_turn(scope, agent) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Work.request_turn_if_runnable(scope, agent, :turn_ended)
    end)

    :ok
  end

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

  # Use the same durable admission as every other message source. The engine
  # keeps its active turn; this decision waits in the database mailbox.
  defp send_to(_scope, agent, message, {kind, subject}) do
    CodeMySpec.Agents.send_to_agent(agent.id, message, :nudge,
      offer: {kind, subject},
      timeout: dispatch_timeout(),
      async: true
    )

    :ok
  end

  defp dispatch_timeout, do: Application.get_env(:code_my_spec, :stop_decision_timeout, 10_000)
end
