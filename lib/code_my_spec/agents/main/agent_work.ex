defmodule CodeMySpec.Agents.Main.AgentWork do
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

  alias CodeMySpec.Agents.Main.AgentWork

  @type t :: %__MODULE__{
          agent_id: Ecto.UUID.t(),
          role: atom(),
          agent_status: atom(),
          working_copy_id: Ecto.UUID.t() | nil,
          working_copy_root: String.t() | nil,
          issue_id: Ecto.UUID.t() | nil,
          team_free?: boolean(),
          task_name: String.t() | nil,
          task_status: atom() | nil,
          task_started_at: DateTime.t() | nil,
          story_title: String.t() | nil,
          designing: String.t() | nil,
          last_said_at: DateTime.t() | nil,
          blocked_reasons: [String.t()],
          tapped_out?: boolean(),
          turn_in_flight?: boolean(),
          unstarted_turn: CodeMySpec.Agents.Offer.t() | nil,
          continuous?: boolean() | nil,
          turn_started_at: DateTime.t() | nil,
          provider_refusal: String.t() | nil,
          provider_retry_at: DateTime.t() | nil,
          turn_timeouts: %{count: pos_integer(), exec: String.t()} | nil,
          idle?: boolean(),
          machine_tools: [String.t()] | nil,
          problems: [map()],
          damped:
            %{count: pos_integer(), requirement: String.t() | nil, until: DateTime.t()} | nil
        }

  defstruct [
    :agent_id,
    :role,
    :agent_status,
    :working_copy_id,
    :working_copy_root,
    :issue_id,
    :task_name,
    :task_status,
    :task_started_at,
    :story_title,
    :designing,
    :last_said_at,
    :turn_started_at,
    :continuous?,
    :provider_refusal,
    :provider_retry_at,
    :turn_timeouts,
    :machine_tools,
    :damped,
    :unstarted_turn,
    blocked_reasons: [],
    tapped_out?: false,
    turn_in_flight?: false,
    idle?: false,
    team_free?: false,
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
  Whether the agent's latest turns died on the provider CLI's timeout
  (eb09b076). A task and a recent `last said` otherwise read as working.
  """
  @spec timing_out?(t()) :: boolean()
  def timing_out?(%AgentWork{turn_timeouts: %{count: n}}), do: n > 0
  def timing_out?(%AgentWork{}), do: false

  @doc "The run of timed-out turns, in one phrase for `check_in` and `list_agent_work`."
  @spec turn_timeouts(t()) :: String.t() | nil
  def turn_timeouts(%AgentWork{turn_timeouts: %{count: 1, exec: exec}}),
    do: "last turn timed out (#{exec})"

  def turn_timeouts(%AgentWork{turn_timeouts: %{count: n, exec: exec}}),
    do: "last #{n} turns timed out (#{exec})"

  def turn_timeouts(%AgentWork{}), do: nil

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

  # Offers held back by `Work`'s damper after repeated declines. Nothing re-offers
  # at expiry; the main agent decides on its wake (35e80d6d).
  def unclaimed_work(%AgentWork{damped: %{count: n, requirement: req, until: until}}),
    do:
      "damped after #{n} declines of #{req || "its offer"} until " <>
        "#{DateTime.to_iso8601(until)} — message_agent it, or take the work"

  def unclaimed_work(%AgentWork{unstarted_turn: %{} = offer}),
    do:
      "STALLED: offered #{offered(offer)} at #{DateTime.to_iso8601(offer.turn_requested_at)} " <>
        "and the turn never started — message_agent it"

  def unclaimed_work(%AgentWork{task_status: :blocked}),
    do:
      "STALLED: only blocked work in hand while the graph holds work for its role, and " <>
        "no turn open to claim it — message_agent it"

  def unclaimed_work(%AgentWork{}),
    do:
      "STALLED: no task claimed while the graph holds work for its role, and no turn " <>
        "open to claim it — message_agent it"

  @doc "What a turn request offered, as a check-in names it."
  @spec offered(CodeMySpec.Agents.Offer.t()) :: String.t()
  def offered(%{kind: kind, subject_type: type, subject_key: nil}), do: "#{kind} (#{type})"
  def offered(%{kind: kind, subject_key: key}), do: "#{kind} #{key}"
end
