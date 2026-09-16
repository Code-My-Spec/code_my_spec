defmodule CodeMySpec.MainAgent.OpenQuestion do
  @moduledoc """
  One question waiting, with who asked it and from where.

  A struct rather than the `QuestionRequest` row, because the row is missing
  exactly what makes the listing usable: a question knows its `agent_id` and
  nothing else about the asker, and the main agent needs the role to judge it,
  the checkout to place it, and the holder to know whether it is still its own
  problem.

  None of that is stored on the question. It follows from the agent — an agent
  belongs to one checkout in one project — which is why criterion 3266 asks for
  the checkout to be *derived* and not supplied: a caller that passes its own
  can pass the wrong one, and a value read through the agent cannot be wrong
  without the agent being wrong.
  """

  alias CodeMySpec.MainAgent.OpenQuestion
  alias CodeMySpec.Utils.MapAccess

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          kind: :question | :permission,
          title: String.t() | nil,
          questions: [map()],
          holder: String.t(),
          escalation_reason: String.t() | nil,
          asked_at: DateTime.t(),
          agent_id: Ecto.UUID.t() | nil,
          agent_role: atom() | nil,
          agent_status: atom() | nil,
          working_copy_id: Ecto.UUID.t() | nil,
          working_copy_root: String.t() | nil,
          working_copy_label: String.t() | nil
        }

  defstruct [
    :id,
    :title,
    :questions,
    :holder,
    :escalation_reason,
    :asked_at,
    :agent_id,
    :agent_role,
    :agent_status,
    :working_copy_id,
    :working_copy_root,
    :working_copy_label,
    kind: :question
  ]

  @doc """
  Build one from the row and the agent it came through.

  The working copy is allowed to be missing. A checkout can be forgotten while
  the question it produced is still waiting, and dropping the question because
  its checkout is gone is criterion 3263's failure by another route — the
  question outlives the process that asked it, and it outlives the tree too.
  """
  @spec new(map(), map() | nil, map() | nil) :: t()
  def new(request, agent, working_copy) do
    %OpenQuestion{
      id: request.id,
      title: request.title,
      questions: request.questions,
      holder: request.holder,
      escalation_reason: request.escalation_reason,
      asked_at: request.inserted_at,
      agent_id: request.agent_id,
      agent_role: field(agent, :role),
      agent_status: field(agent, :status),
      working_copy_id: field(agent, :working_copy_id),
      working_copy_root: field(working_copy, :root),
      working_copy_label: field(working_copy, :label)
    }
  end

  @doc """
  The same struct, built from a permission request.

  A `tap_out` or an `ask_user_question` is an agent waiting on a person exactly
  as a question is, and `StopDecision.wake/2` treats them identically —
  `Notifications.awaiting_answer?/1` is `pending_question? or
  pending_permission?`, so either one takes the agent off the graph until
  somebody decides.

  They were missing from the listing that calls itself "everything the agents on
  this project are waiting on, in one place", which made the commonest way for
  an agent to go silent the one way the listing could not show. Agent
  `880c7713` sat unreachable for seven hours on an un-actioned `tap_out` while
  every surface reported it running, continuous and idle with 17 actionable
  requirements (`8cb3f626`).

  `holder` is the user: a permission request has no main-agent half to answer
  first, which is the honest rendering rather than one that invites an answer
  that cannot be given.
  """
  @spec from_permission(map(), map() | nil, map() | nil) :: t()
  def from_permission(request, agent, working_copy) do
    %OpenQuestion{
      id: request.id,
      kind: :permission,
      title: permission_title(request.tool_name),
      questions: [%{"question" => permission_text(request)}],
      holder: "user",
      escalation_reason: nil,
      asked_at: request.inserted_at,
      agent_id: request.agent_id,
      agent_role: field(agent, :role),
      agent_status: field(agent, :status),
      working_copy_id: field(agent, :working_copy_id),
      working_copy_root: field(working_copy, :root),
      working_copy_label: field(working_copy, :label)
    }
  end

  defp permission_title("tap_out"), do: "Asked to leave the loop (tap_out)"
  defp permission_title(tool_name), do: "Permission requested: #{tool_name}"

  defp permission_text(%{tool_name: "tap_out"}) do
    "This agent asked to leave the autonomous loop and is waiting on a decision. " <>
      "Until one is recorded it cannot be woken — a pending permission request " <>
      "refuses the wake the same way an unanswered question does."
  end

  defp permission_text(%{tool_name: tool_name, tool_input: input}) do
    "This agent asked permission to call `#{tool_name}` and is waiting on a " <>
      "decision. Until one is recorded it cannot be woken. Input: #{inspect(input)}"
  end

  @doc "The question text, for a listing that shows one line per question."
  @spec texts(t()) :: [String.t()]
  def texts(%OpenQuestion{questions: questions}) do
    Enum.map(questions, fn question -> MapAccess.get(question, :question) end)
  end

  defp field(nil, _key), do: nil
  defp field(struct, key), do: Map.get(struct, key)
end
