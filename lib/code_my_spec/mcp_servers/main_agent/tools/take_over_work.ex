defmodule CodeMySpec.McpServers.MainAgent.Tools.TakeOverWork do
  @moduledoc """
  Take a task off an agent, when it is work that agent cannot do.

  Refused when the agent is capable of it — including when it is being slow.
  Your wider scope is for what a role cannot do, not for what you would rather
  not wait for.
  """

  # It exists in order to refuse. Criterion 3328: the main agent may do
  # anything, so watching an agent work slowly on something it could finish is a
  # standing temptation, and each individual takeover is defensible while the
  # end state is one agent doing everything with three idle.

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
