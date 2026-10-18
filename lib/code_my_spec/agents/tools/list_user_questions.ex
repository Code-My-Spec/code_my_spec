defmodule CodeMySpec.Agents.Tools.ListUserQuestions do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Notifications
  alias CodeMySpec.Sessions

  @impl true
  def name, do: "list_user_questions"

  @impl true
  def description do
    """
    Your unanswered questions, oldest first, with their linked task IDs.

    Recovers what you asked before a compaction, or lets you check whether a
    question is still open before asking another. Internal callers see their
    own durable agent's questions across restarts; external callers see their
    session's. Answered questions are not listed -- `check_answer` hands back
    a reply once it lands, and there is no expiry: an unanswered question
    stays listed until it is.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, %{agent_id: id, scope: scope})
      when is_binary(id) do
    case Agents.fetch_agent(scope, id) do
      {:ok, _agent} ->
        questions =
          id
          |> Notifications.list_question_requests_for_agent()
          |> Enum.filter(&(&1.status == "pending"))

        {:ok, render(questions)}

      {:error, _reason} ->
        {:error, "Agent not found in this project."}
    end
  end

  def call(_params, context) do
    scope = context[:scope]

    case Sessions.external_id_for_harness(working_copy_id(scope)) do
      nil ->
        {:ok, no_session()}

      external_id ->
        questions =
          external_id
          |> Notifications.list_question_requests_for_session()
          |> Enum.filter(&(&1.status == "pending"))

        {:ok, render(questions)}
    end
  end

  defp render([]) do
    """
    Nothing is waiting on the user — you have no open questions in this session.

    If you need a decision to go further, `ask_user` raises one.
    """
  end

  defp render(questions) do
    header =
      case length(questions) do
        1 -> "1 open question, waiting on the user:"
        n -> "#{n} open questions, waiting on the user:"
      end

    body = Enum.map_join(questions, "\n", &"  - #{text(&1)}\n    id: #{&1.id}#{task_link(&1)}")

    header <>
      "\n" <>
      body <>
      "\n\nCall `check_answer` with an id to collect a reply once it lands. " <>
      "Do not re-ask any of these — that queues a duplicate for the user."
  end

  defp task_link(%{task_id: id}) when is_binary(id), do: "\n    task: #{id}"
  defp task_link(_question), do: ""

  # The question as the user saw it. `questions` is the tool's array verbatim,
  # and a free-form `ask_user` puts exactly one entry in it.
  defp text(%{questions: [%{"question" => q} | _]}) when is_binary(q), do: q
  defp text(%{title: title}) when is_binary(title), do: title
  defp text(_request), do: "(no question text)"

  defp no_session do
    """
    No session is registered for this working copy, so there are no questions to
    list. A question is tied to the conversation it was asked in, and that link
    is made from the session running here.
    """
  end

  defp working_copy_id(%{active_working_copy_id: id}) when is_binary(id), do: id
  defp working_copy_id(_scope), do: nil
end
