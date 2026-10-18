defmodule CodeMySpec.Agents.StopDecision do
  @moduledoc """
  What the orchestrator says to an agent that has just ended a turn, delivered
  as a message.

  `Hooks.Stop` answers an external agent's Stop hook with the same content —
  the problem summary from `Validation.validate_stop/3` and the directive from
  `Agents.Menu.render/4` — in the hook's envelope. An agent under Alloy fires
  no hooks, so it hears the same decision as a message. Content shared,
  delivery different.

  The agent is never told to wait for analysis: it is a live process, and
  results are pushed when they exist (`AnalysisReport`). The hook's response
  cap does not apply to a message.

  Nothing is sent when there is nothing to say: a message wakes the agent and
  costs it a turn.

  See knowledge/agents/coordination, "The stop decision".
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
    # Opened first: `record_sent_to_agent/2` silently records nothing when the
    # agent has no conversation, so an agent's first message would vanish.
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      agent.id
    )

    decided = decide_with_key(scope, agent, opts)

    case decided do
      {nil, _key} ->
        request_turn(scope, agent)

      # A menu that repeats byte-for-byte is a repeat: genuine progress changes
      # it. Keyed on the rendered text in its own `stuck?` slot.
      {message, :continuing} ->
        continuing(scope, agent, message, Agent.active_task(agent))
    end
  end

  @doc """
  The decision as a value, or `nil` when there is nothing to say.

  Public because it is the half both transports share: a hook and a message
  must carry the same sentence.
  """
  @spec decide(Scope.t(), Agent.t()) :: String.t() | nil
  def decide(%Scope{} = scope, %Agent{} = agent) do
    {message, _key} = decide_with_key(scope, agent, [])
    message
  end

  # The same threshold as `Hooks.Stop`'s stuck escape: repeated identical blocks
  # otherwise spend a budget unattended. Keyed on the agent (an Alloy agent has
  # no session) and on the blocking key, not the text, so a changed count or
  # age does not reset it. In `:persistent_term`: a restart costs one duplicate.
  @stuck_threshold 5

  defp decide_with_key(%Scope{} = scope, %Agent{} = agent, opts) do
    decide_with_work(scope, agent, opts)
  end

  defp decide_with_work(%Scope{} = scope, %Agent{} = agent, opts) do
    validate_opts = Keyword.put(opts, :agent_id, agent.id)

    {:ok, _result} = Validation.validate_stop(scope, nil, validate_opts)
    keep_working(scope, agent)
  end

  # Nothing is blocking. An agent not in the loop is told nothing (a message
  # costs it a turn). In the loop, `Menu.render/4` answering `""` is the
  # terminus: nothing left to do, nothing said, the agent stops.
  defp keep_working(%Scope{} = scope, %Agent{continuous: true} = agent) do
    # Narrowed to this agent's own role, so it goes home when its own work
    # runs out rather than looping on other roles' queues.
    case Menu.render(scope, true, agent.role, agent) do
      "" -> {nil, nil}
      menu -> {"Your turn is done and the loop is still running." <> menu, :continuing}
    end
  end

  defp keep_working(%Scope{}, %Agent{}), do: {nil, nil}

  # `tag` (`:decision`, `:continuing`) gives each counter its own slot.
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

  # Off this process: `deliver/3` runs inside the harness channel at turn end,
  # and the turn request calls back into that channel (a would-be deadlock).
  defp request_turn(scope, agent) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Work.request_turn_if_runnable(scope, agent, :turn_ended)
    end)

    :ok
  end

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
