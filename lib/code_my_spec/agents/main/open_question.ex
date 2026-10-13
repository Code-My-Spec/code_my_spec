defmodule CodeMySpec.Agents.Main.OpenQuestion do
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

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Main.OpenQuestion
  alias CodeMySpec.Agents.Presence
  alias CodeMySpec.Utils.MapAccess

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          kind: :question | :permission,
          title: String.t() | nil,
          questions: [map()],
          holder: String.t(),
          escalation_reason: String.t() | nil,
          asked_at: DateTime.t(),
          story_id: integer() | nil,
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
    :story_id,
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
      story_id: request.story_id,
      agent_id: request.agent_id,
      agent_role: field(agent, :role),
      agent_status: lifecycle(agent),
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

  `holder` starts as the user: a permission request has no main-agent half to
  answer first, which is the honest rendering for one nobody has looked at
  yet. `aged?` is true once the project's own recovery interval has passed
  with nobody deciding it (criterion 1980) — at that point it becomes the
  main agent's, unless it has already been escalated with a reason
  (criterion 1981), which stays the user's regardless of age.
  """
  @spec from_permission(map(), map() | nil, map() | nil, boolean()) :: t()
  def from_permission(request, agent, working_copy, aged? \\ false) do
    %OpenQuestion{
      id: request.id,
      kind: :permission,
      title: permission_title(request.tool_name),
      questions: [%{"question" => permission_question(request)}],
      holder: permission_holder(request, field(agent, :role), aged?),
      escalation_reason: request.escalation_reason,
      asked_at: request.inserted_at,
      agent_id: request.agent_id,
      agent_role: field(agent, :role),
      agent_status: lifecycle(agent),
      working_copy_id: field(agent, :working_copy_id),
      working_copy_root: field(working_copy, :root),
      working_copy_label: field(working_copy, :label)
    }
  end

  defp permission_title("tap_out"), do: "Asked to leave the loop (tap_out)"
  defp permission_title(tool_name), do: "Permission requested: #{tool_name}"

  # Escalated stays the user's at any age — only the main agent decides to
  # send one up, and that decision does not get overridden by the clock
  # that exists to catch the ones nobody decided at all.
  #
  # Everyone else's tap-out is main's from the moment it is raised (criteria
  # 2073/2074); main's own has nobody above it but the user. It used to reach
  # main only after ageing a recovery interval, so a fresh one sat with the user.
  defp permission_holder(%{escalation_reason: reason}, _role, _aged?) when is_binary(reason),
    do: "user"

  defp permission_holder(_request, :main, _aged?), do: "user"
  defp permission_holder(_request, _role, _aged?), do: "main_agent"

  defp permission_question(%{escalated_as: as}) when is_binary(as), do: as
  defp permission_question(request), do: permission_text(request)

  # Criterion 2120: offering a teammate's tap-out to the main agent as work
  # means naming what it is work on -- the agent is already in `render/1`'s
  # own fields, but the task and the reason the agent gave lived only in
  # `tool_input`, which this text never read. A main agent offered this had
  # to go find both itself before it could act.
  defp permission_text(%{tool_name: "tap_out"} = request) do
    "This agent asked to leave the autonomous loop and is waiting on a decision. " <>
      "Until one is recorded it cannot be woken — a pending permission request " <>
      "refuses the wake the same way an unanswered question does." <>
      tap_out_task(request) <> tap_out_reason(request)
  end

  defp permission_text(%{tool_name: tool_name, tool_input: input}) do
    "This agent asked permission to call `#{tool_name}` and is waiting on a " <>
      "decision. Until one is recorded it cannot be woken. Input: #{inspect(input)}"
  end

  defp tap_out_task(%{task_id: task_id}) when is_binary(task_id), do: "\n  task: #{task_id}"
  defp tap_out_task(_request), do: ""

  defp tap_out_reason(%{tool_input: %{"reason" => reason}}) when is_binary(reason) and reason != "",
    do: "\n  reason: #{reason}"

  defp tap_out_reason(_request), do: ""

  @doc "The question text, for a listing that shows one line per question."
  @spec texts(t()) :: [String.t()]
  def texts(%OpenQuestion{questions: questions}) do
    Enum.map(questions, fn question -> MapAccess.get(question, :question) end)
  end

  # Derived, as everywhere an agent's state is shown (`Agents.lifecycle/2`).
  defp lifecycle(%Agent{} = agent),
    do: Agents.lifecycle(agent, Presence.ids(agent.project_id))

  defp lifecycle(_agent), do: nil

  defp field(nil, _key), do: nil
  defp field(struct, key), do: Map.get(struct, key)
end
