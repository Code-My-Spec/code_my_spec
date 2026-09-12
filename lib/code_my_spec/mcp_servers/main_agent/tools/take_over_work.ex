defmodule CodeMySpec.McpServers.MainAgent.Tools.TakeOverWork do
  @moduledoc """
  Ask to take a task off an agent. **This always refuses.**

  It exists to say no, and the no is the feature. Your wider scope is for what a
  role cannot do, not for what you would rather not wait for — including when an
  agent is being slow. Each individual takeover is defensible; the end state is
  one agent doing everything with three idle, decided by nobody.

  Where you legitimately act past a role's reach, act directly rather than
  confiscating its task — `ready_stories_without_epic` is the worked example, and
  that already works.

  Said plainly here because the refusal reads like an assessment of the task and
  is not one: `task_id` is accepted and never consulted, so the answer is the
  same whatever you pass. Nothing specifies when a takeover should succeed, so
  nothing does.
  """

  # Criterion 3328. QA (3b7023ae) noted the tool cannot succeed for any input and
  # that the well-worded refusal therefore reads as discriminating when it is
  # unconditional — hence saying so in the description an agent actually reads,
  # rather than only in a comment it does not.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.AnswerMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :agent_id, :string, required: true, doc: "The agent holding the work."
    field :task_id, :string, required: true, doc: "The task you want to take on."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, taken} <-
           MainAgent.take_over_work(
             scope,
             MapAccess.get(params, :agent_id),
             MapAccess.get(params, :task_id)
           ) do
      {:reply, AnswerMapper.taken(taken), frame}
    else
      {:error, reason} -> {:reply, AnswerMapper.error(reason), frame}
    end
  end
end
