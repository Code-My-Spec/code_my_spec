defmodule CodeMySpec.Agents.Tools.EscalateQuestion do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Tools.MainAgentResponses, as: MainAgentMapper
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def name, do: "escalate_question"

  @impl true
  def description do
    """
    Hand one of your agents' questions to the user, with why you could not answer.

    Use it when the decision is theirs — what to build, what it is worth, which
    way the product goes. Not for anything the project already records: look that
    up and answer it.

    The question stays open and stays in your listing, marked as waiting on them.
    """
  end

  @impl true
  def params do
    %{
      reason:
        {:required,
         {:meta, :string,
          [description: "Why this is the user's call and not yours. They read it."]}},
      as:
        {:meta, :string,
         [
           description:
             "The same question as a choice about their product. Put it in their words when the agent's were module names — the original travels with it."
         ]},
      to:
        {:meta, :string,
         [
           description:
             "`user` (the default) to escalate; `main` or `product` to hand it to the other answerer instead, without the user seeing it."
         ]},
      question_id: {:required, {:meta, :string, [description: "From `list_open_questions`."]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, question} <- move(scope, params, MapAccess.get(params, :to)) do
      MainAgentMapper.escalated(question)
    else
      {:error, reason} -> MainAgentMapper.error(reason)
    end
  end

  # Criterion 2123: main and product hand questions to each other sideways.
  defp move(scope, params, to) when to in ["main", "product"],
    do: MainAgent.hand_question(scope, question_id(params), to, reason(params))

  defp move(scope, params, _to),
    do:
      MainAgent.escalate_question(scope, question_id(params), reason(params),
        as: MapAccess.get(params, :as)
      )

  defp question_id(params), do: MapAccess.get(params, :question_id)
  defp reason(params), do: MapAccess.get(params, :reason)
end
