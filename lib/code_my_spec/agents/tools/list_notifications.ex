defmodule CodeMySpec.Agents.Tools.ListNotifications do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Main.OpenQuestion
  alias CodeMySpec.Agents.Tools.MainAgentResponses, as: MainAgentMapper

  @impl true
  def name, do: "list_notifications"

  @impl true
  def description do
    """
    Everything the agents on this project are waiting on, in one place.

    Questions and permissions together — a `tap_out` stops an agent exactly as an
    unanswered question does. Grouped by who holds each one: yours to answer, or
    already sent up and waiting on the user. `kind` says whether it takes an
    answer or a decision. Settle any of them with `answer_notification`.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case questions(context) do
      {:ok, scope, questions} ->
        MainAgentMapper.listing(questions, mine(scope, context))

      {:error, reason} ->
        MainAgentMapper.error(reason)
    end
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, _scope, questions} <- questions(context) do
      {:ok, Enum.map(questions, &row/1)}
    end
  end

  defp questions(context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> {:ok, scope, MainAgent.list_open_questions(scope)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row(question) do
    %{
      "id" => question.id,
      "kind" => to_string(question.kind),
      "title" => question.title,
      # The title can be generic; without these a scripted caller cannot answer.
      "questions" => OpenQuestion.texts(question),
      "holder" => question.holder,
      "story_id" => question.story_id,
      "agent_id" => question.agent_id,
      "agent_role" => question.agent_role && to_string(question.agent_role),
      "working_copy_id" => question.working_copy_id,
      "working_copy_label" => question.working_copy_label
    }
  end

  # Product's own are the criteria questions routed to it (8c91d5bc).
  defp mine(scope, %{agent_id: id}) when is_binary(id) do
    case CodeMySpec.Agents.fetch_agent(scope, id) do
      {:ok, %{role: :product}} -> "product_agent"
      _ -> "main_agent"
    end
  end

  defp mine(_scope, _context), do: "main_agent"
end
