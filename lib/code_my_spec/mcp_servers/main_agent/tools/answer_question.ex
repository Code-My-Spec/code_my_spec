defmodule CodeMySpec.McpServers.MainAgent.Tools.AnswerQuestion do
  @moduledoc """
  Answer one of your agents' open questions from what the project records.

  Use it whenever you can find the answer. Escalating something the project
  already knows sends a person to look up what the system could have told them.

  Say `worked_around` when you had to supply something the asking role should
  have been able to find itself — that gets counted and, once, filed as a gap
  in that role's tools.

  Not a way round a role's limits: asking it to use a tool that role
  deliberately does not carry is refused.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.AnswerMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :question_id, :string, required: true, doc: "From `list_open_questions`."
    field :answer, :string, required: true, doc: "What you found, in the agent's terms."

    field :worked_around, :string,
      doc: "The capability the asking role lacked, if you covered for one."

    field :on_behalf_of, :string, doc: "A role you are acting as. Usually leave this out."
    field :tool, :string, doc: "A tool you are using on that role's behalf."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, answered} <-
           MainAgent.answer_question(
             scope,
             MapAccess.get(params, :question_id),
             MapAccess.get(params, :answer),
             worked_around: MapAccess.get(params, :worked_around),
             on_behalf_of: MapAccess.get(params, :on_behalf_of),
             tool: MapAccess.get(params, :tool)
           ) do
      {:reply, AnswerMapper.answered(answered), frame}
    else
      {:error, reason} -> {:reply, AnswerMapper.error(reason), frame}
    end
  end
end
