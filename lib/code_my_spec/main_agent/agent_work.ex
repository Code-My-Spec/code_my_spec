defmodule CodeMySpec.MainAgent.AgentWork do
  @moduledoc """
  What one agent is doing, as parts rather than as a verdict.

  Story 1054's design constraint, in a struct. Every field here is something
  observed — a task that is open, a moment something was last said, a question
  nobody has answered — and none of them is a conclusion drawn from the others.

  ## Why there is no `status`

  Criterion 3275, and it is a refusal rather than an omission. A computed status
  reads better and is shorter, and it is wrong often enough to matter: the same
  silence threshold that produces "stalled" calls a streaming agent dead and a
  tapped-out one broken. Once it is computed the parts it came from are gone, so
  the main agent cannot disagree with it — a verdict is lossy and does not say
  so.

  The two fields that look like verdicts are not. `idle?` is the graph's own
  answer about this role's queue, and `blocked_reasons` quotes what the agent
  asked rather than summarising why it stopped.
  """

  alias CodeMySpec.MainAgent.AgentWork

  @type t :: %__MODULE__{
          agent_id: Ecto.UUID.t(),
          role: atom(),
          agent_status: atom(),
          working_copy_id: Ecto.UUID.t() | nil,
          working_copy_root: String.t() | nil,
          task_name: String.t() | nil,
          task_status: atom() | nil,
          task_started_at: DateTime.t() | nil,
          story_title: String.t() | nil,
          last_said_at: DateTime.t() | nil,
          blocked_reasons: [String.t()],
          tapped_out?: boolean(),
          continuous?: boolean() | nil,
          turn_started_at: DateTime.t() | nil,
          provider_refusal: String.t() | nil,
          provider_retry_at: DateTime.t() | nil,
          idle?: boolean(),
          machine_tools: [String.t()] | nil,
          problems: [map()]
        }

  defstruct [
    :agent_id,
    :role,
    :agent_status,
    :working_copy_id,
    :working_copy_root,
    :task_name,
    :task_status,
    :task_started_at,
    :story_title,
    :last_said_at,
    :turn_started_at,
    :continuous?,
    :provider_refusal,
    :provider_retry_at,
    :machine_tools,
    blocked_reasons: [],
    tapped_out?: false,
    idle?: false,
    problems: []
  ]

  @doc """
  Whether this agent's machine has told us it can do nothing.

  `nil` and `[]` are different answers and only one of them is a fault. Nil is a
  copy that has not said what it can do — every copy before the field existed,
  and every one that has not joined since — and calling that broken would report
  most of the fleet as unable to work. An empty list is a machine that answered
  the question with "nothing", which is what a harness holding a dead MCP client
  says.
  """
  @spec toolless?(t()) :: boolean()
  def toolless?(%AgentWork{machine_tools: []}), do: true
  def toolless?(%AgentWork{}), do: false

  @doc """
  Whether the provider refused this agent's last turn (044599cc).

  One predicate for the check-in line, the machinery line, `quiet?/1` and
  `list_agent_work`, so none of them can call a refused agent working.
  """
  @spec provider_blocked?(t()) :: boolean()
  def provider_blocked?(%AgentWork{provider_refusal: refusal}), do: is_binary(refusal)

  @doc "What a provider-blocked agent is blocked on, in the provider's words."
  @spec provider_block(t()) :: String.t()
  def provider_block(%AgentWork{provider_refusal: refusal, provider_retry_at: nil}),
    do: "provider — #{refusal}"

  def provider_block(%AgentWork{provider_refusal: refusal, provider_retry_at: at}),
    do: "provider — #{refusal} (retry after #{DateTime.to_iso8601(at)})"

  @doc """
  What an agent with no task is doing while its role's queue holds work.

  One phrase for both `check_in` and `list_agent_work`, and it names the
  reason. A bare "no task claimed, and the graph does hold work" was printed
  for a tapped-out, stopped or mid-turn agent too, so the line under a "Nothing
  needs you" headline read as a stall the headline had missed (3f1fc39f). Only
  the last clause is a stall, and it is exactly `Digest.stalled?/1`.
  """
  @spec unclaimed_work(t()) :: String.t()
  def unclaimed_work(%AgentWork{tapped_out?: true}),
    do: "tapped out, though the graph holds work for its role"

  def unclaimed_work(%AgentWork{agent_status: status}) when status != :running,
    do: "#{status}, though the graph holds work for its role"

  def unclaimed_work(%AgentWork{provider_refusal: refusal}) when is_binary(refusal),
    do: "refused by its provider, though the graph holds work for its role"

  def unclaimed_work(%AgentWork{turn_started_at: %DateTime{} = at}),
    do: "mid-turn since #{DateTime.to_iso8601(at)}, no task claimed yet"

  # Not a stall: graph wakes admit only continuous agents, so nothing but a
  # message will ever reach it (723b929d).
  def unclaimed_work(%AgentWork{continuous?: false}),
    do:
      "not in the loop (continuous off), so no graph change wakes it, though the graph " <>
        "holds work for its role — message_agent it, or put its copy to work"

  def unclaimed_work(%AgentWork{}),
    do:
      "STALLED: no task claimed while the graph holds work for its role, and no turn " <>
        "open to claim it — message_agent it"
end
