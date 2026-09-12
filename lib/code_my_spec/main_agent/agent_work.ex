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
          task_started_at: DateTime.t() | nil,
          story_title: String.t() | nil,
          last_said_at: DateTime.t() | nil,
          blocked_reasons: [String.t()],
          tapped_out?: boolean(),
          turn_started_at: DateTime.t() | nil,
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
    :task_started_at,
    :story_title,
    :last_said_at,
    :turn_started_at,
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
end
