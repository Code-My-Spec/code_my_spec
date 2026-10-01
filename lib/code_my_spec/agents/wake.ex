defmodule CodeMySpec.Agents.Wake do
  @moduledoc """
  The one decision every wake goes through: may this event reach this agent
  now (a31f1cd6 step 4a).

  John: "is the agent on? yes. Is the agent continuous? yes. Is this answer
  relevant to this agent? yes. OK then we wake the agent." Each delivery path
  used to answer some of that ad hoc — the work offer all of it, a message
  only the transport's off gate. Every caller now names its event and asks
  here; what is left at the call site is about the payload (is there work, is
  there a finding worth sending), never about the agent.

  ## The decision, in order

    1. **On** — not off, not retired, and running or starting.
    2. **Relevant** — the role's `RoleProfile.wake` names the event, or the
       event is always relevant (`@always_relevant`): a person's message, and
       anything answering the agent's own request.
    3. **Continuous** — a continuous agent may be woken. A non-continuous one
       gets what `@not_continuous` says for the event: `:wake` for what it was
       told it would be messaged about, `:queue` for what it collects when it
       comes back (delivered into a turn in flight, otherwise held), `:hold`
       for everything that would put it to work.
    4. **Not waiting on something else** — `Agents.Waiting` on the path the
       event starts a turn through, last because it reads beyond the row. Only
       when it would start one: an event queued into a turn in flight wakes
       nobody. Most replies name no path — they are what the agent waits on.

  An operator's message (a person typing at the agent) passes 2–4.

  `decide/3` is the table; `allow?/3` folds in whether a turn is in flight.
  Mid-turn delivery is unchanged: the transport queues a message behind the
  running turn, so `:wake` and `:queue` both mean "deliver" while one runs.

  Each answer is announced as `[:code_my_spec, :agents, :wake]` with the agent,
  event and decision, so a caller's routing is observable.
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Agents.Waiting
  alias CodeMySpec.Users.Scope

  @typedoc """
    * `:operator_message` — a person typing at the agent.
    * `:own_reply` — the result of something it started and was told it would
      be messaged about: its analysis run landing or failing, its provisioning
      run finishing, its promote's outcome, its permission request decided,
      its failed turn re-offered, its restart explained.
    * `:question_answered` — its own question answered.
    * `:blocker_resolved` — a blocker on its own task resolved.
    * `:nudge` — the turn-end review of the turn it just ended (`StopDecision`).
    * `:work_offer` — eligible work on the graph.
    * `:resume` — a task it holds with no turn open.
    * `:teammate_question` — a teammate raised a question it answers first.
    * `:findings` — an analysis run's findings it did not ask for.
    * `:issue_filed` — an issue filed from the widget.
    * `:cadence` — the main agent's check-in timer.
  """
  @type event ::
          :operator_message
          | :own_reply
          | :question_answered
          | :blocker_resolved
          | :nudge
          | :work_offer
          | :resume
          | :teammate_question
          | :findings
          | :issue_filed
          | :cadence

  @type hold ::
          {:off, Agent.t()}
          | {:retired, Agent.t()}
          | :not_running
          | :not_relevant
          | :not_continuous
          | :collects_when_back
          | Waiting.reason()

  @events [
    :operator_message,
    :own_reply,
    :question_answered,
    :blocker_resolved,
    :nudge,
    :work_offer,
    :resume,
    :teammate_question,
    :findings,
    :issue_filed,
    :cadence
  ]

  # Relevant to whoever it is addressed to: a person speaking to it, or the
  # answer to its own request.
  @always_relevant [:operator_message, :own_reply, :question_answered, :blocker_resolved]

  # The `Agents.Waiting` path each event would start a turn through.
  @waiting_path %{
    work_offer: :wake,
    teammate_question: :wake,
    question_answered: :wake,
    blocker_resolved: :wake,
    resume: :resume,
    nudge: :turn_end
  }

  # What a non-continuous agent gets. Today's behaviour, per event.
  #
  # `:own_reply` and `:nudge` wake it: it was told to end its turn and wait for
  # the message, or it is hearing about the turn it just ended. A question's
  # answer and a released blocker are collected when it comes back — criterion
  # 3219, "a durable question exists so that an agent which stopped can collect
  # its answer when it comes back rather than be woken by it". `:cadence` is
  # only ever pushed to a non-continuous main: a continuous one is offered work
  # instead. `:findings` and `:issue_filed` wake it as they always have — see
  # the report on a31f1cd6 step 4a before changing that.
  @not_continuous %{
    operator_message: :wake,
    own_reply: :wake,
    nudge: :wake,
    cadence: :wake,
    findings: :wake,
    issue_filed: :wake,
    question_answered: :queue,
    blocker_resolved: :queue,
    work_offer: :hold,
    resume: :hold,
    teammate_question: :hold
  }

  @telemetry [:code_my_spec, :agents, :wake]

  @doc "Every event kind."
  @spec events() :: [event()]
  def events, do: @events

  @doc "The telemetry event each decision is announced as."
  def telemetry_event, do: @telemetry

  @doc """
  Whether `event` may reach `agent` now: `:ok`, or `{:hold, reason}`.

  `decide/3`, with `:queue` resolved against the agent's turn: delivered into
  a turn in flight, held (`:collects_when_back`) when none is.
  """
  @spec allow?(Scope.t(), Agent.t(), event()) :: :ok | {:hold, hold()}
  def allow?(%Scope{} = scope, %Agent{} = agent, event) when event in @events do
    result =
      case decide(scope, agent, event) do
        :wake -> :ok
        :queue -> if in_turn?(agent), do: :ok, else: {:hold, :collects_when_back}
        {:hold, _reason} = hold -> hold
      end

    :telemetry.execute(@telemetry, %{}, %{agent_id: agent.id, event: event, result: result})
    result
  end

  @doc """
  The table: `:wake`, `:queue` (deliver into a turn in flight only), or
  `{:hold, reason}`.
  """
  @spec decide(Scope.t(), Agent.t(), event()) :: :wake | :queue | {:hold, hold()}
  def decide(%Scope{} = scope, %Agent{} = agent, event) when event in @events do
    with :ok <- on(agent),
         :ok <- relevant(agent, event),
         :wake <- continuous(agent, event),
         :ok <- not_waiting(scope, agent, event) do
      :wake
    end
  end

  @doc """
  A hold as the error the delivery paths have always answered: the gate's
  `{:off | :retired, agent}` and the transport's `:not_running` as they were,
  anything else as `{:held, reason}`.
  """
  @spec to_error({:hold, hold()}) :: {:error, term()}
  def to_error({:hold, {stood_down, _agent} = reason}) when stood_down in [:off, :retired],
    do: {:error, reason}

  def to_error({:hold, :not_running}), do: {:error, :not_running}
  def to_error({:hold, reason}), do: {:error, {:held, reason}}

  # Read fresh through the gate, so a turn-off lands on work already queued.
  defp on(agent) do
    case Transport.deliverable(agent) do
      :ok -> running(agent)
      {:error, reason} -> {:hold, reason}
    end
  end

  defp running(%Agent{status: status}) when status in [:running, :starting], do: :ok
  defp running(_agent), do: {:hold, :not_running}

  defp relevant(_agent, event) when event in @always_relevant, do: :ok

  defp relevant(%Agent{role: role}, event) do
    if RoleProfile.wakes_on?(role, event), do: :ok, else: {:hold, :not_relevant}
  end

  # Waiting holds a wake, not a delivery into a turn already running.
  defp not_waiting(scope, agent, event) do
    with path when not is_nil(path) <- Map.get(@waiting_path, event),
         false <- in_turn?(agent),
         reason when not is_nil(reason) <- Waiting.reason(scope, agent, path) do
      {:hold, reason}
    else
      _ -> :ok
    end
  end

  defp continuous(%Agent{continuous: true}, _event), do: :wake

  defp continuous(_agent, event) do
    case Map.fetch!(@not_continuous, event) do
      :hold -> {:hold, :not_continuous}
      decision -> decision
    end
  end

  defp in_turn?(%Agent{turn_started_at: at}), do: not is_nil(at)
end
