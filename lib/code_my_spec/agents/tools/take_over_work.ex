defmodule CodeMySpec.Agents.Tools.TakeOverWork do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Tools.AnswerResponses, as: AnswerMapper
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def name, do: "take_over_work"

  @impl true
  def description do
    """
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
  end

  @impl true
  def params do
    %{
      agent_id: {:required, {:meta, :string, [description: "The agent holding the work."]}},
      task_id: {:required, {:meta, :string, [description: "The task you want to take on."]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, taken} <-
           MainAgent.take_over_work(
             scope,
             MapAccess.get(params, :agent_id),
             MapAccess.get(params, :task_id)
           ) do
      AnswerMapper.taken(taken)
    else
      {:error, reason} -> AnswerMapper.error(reason)
    end
  end
end
