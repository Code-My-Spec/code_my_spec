defmodule CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion do
  @moduledoc """
  Hand one of your agents' questions to the user, with why you could not answer.

  Use it when the decision is theirs — what to build, what it is worth, which
  way the product goes. Not for anything the project already records: look that
  up and answer it.

  The question stays open and stays in your listing, marked as waiting on them.
  """

  # The question is not closed, reassigned or copied — its holder moves. Both
  # obvious alternatives are failures criterion 3264 names: deleted, you see
  # your own escalations forever with no way to tell the handled from the rest;
  # marked answered, the person's question disappears from under them while
  # they are looking at it.
  #
  # Comments rather than moduledoc for the same reason as every other tool here
  # — the moduledoc is advertised to every agent at connect and the spine is
  # capped at 20 KB.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.MainAgentMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :question_id, :string, required: true, doc: "From `list_open_questions`."

    field :reason, :string,
      required: true,
      doc: "Why this is the user's call and not yours. They read it."

    field :as, :string,
      doc:
        "The same question as a choice about their product. Put it in their words when " <>
          "the agent's were module names — the original travels with it."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, question} <-
           MainAgent.escalate_question(scope, question_id(params), reason(params),
             as: MapAccess.get(params, :as)
           ) do
      {:reply, MainAgentMapper.escalated(question), frame}
    else
      {:error, reason} -> {:reply, MainAgentMapper.error(reason), frame}
    end
  end

  defp question_id(params), do: MapAccess.get(params, :question_id)
  defp reason(params), do: MapAccess.get(params, :reason)
end
