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
    case decide(scope, agent) do
      nil -> :ok
      message -> send_to(scope, agent, message)
    end
  rescue
    error ->
      Logger.warning(
        "[StopDecision] could not decide for agent #{agent.id}: " <> Exception.message(error)
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
    # No task: an internal agent has no session, and a session is where the
    # external path finds one. Task-aware behaviour — the nudge about work left
    # open — is the other half of story 1043 and wants the agent's own task
    # rather than a session's.
    case Validation.validate_stop(scope, nil, agent_id: agent.id) do
      {:error, reason, _key} -> reason <> Validation.Menu.render(scope)
      {:ok, _result} -> nil
    end
  end

  # Through the transport every other message to an agent goes through, so an
  # agent mid-turn is queued rather than interrupted — the engine decides
  # started-or-queued without running anything, and a decision that barged into
  # a turn in flight would lose whatever that turn was part-way through.
  defp send_to(scope, agent, message) do
    ref = "stop-decision-" <> Ecto.UUID.generate()

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
