defmodule CodeMySpec.McpServers.Tasks.Tools.CheckAnswerInProcessTest do
  @moduledoc """
  `check_answer` reads the question row directly, with no HTTP hop.

  It was the last of the three question tools still going through
  `QuestionClient`: `ask_user` moved in-process for story 896 and
  `list_user_questions` was written that way, which left the half of the
  exchange that *collects* the answer as the only step no spex could drive.
  They were verified to reach the same database, so nothing was broken — it was
  a round trip and a blind spot rather than a split brain (issue `f2739ae7`).

  This asserts the two answers that matter and, by running at all, the thing the
  issue was really about: the tool is now reachable from a test.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpec.Notifications
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
    scope = full_scope_fixture()
    {:ok, user_id: scope.user.id}
  end

  defp frame, do: %Anubis.Server.Frame{assigns: %{}}

  defp text(response) do
    response.content |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  test "an answered question returns what the user said", %{user_id: user_id} do
    {:ok, request} =
      Notifications.create_question_request(user_id, %{
        "title" => "Claude has a message",
        "questions" => [%{"question" => "Which storage backend?"}]
      })

    {:ok, _} =
      Notifications.answer_question_request(request.id, %{
        "Which storage backend?" => "S3"
      })

    {:reply, response, _} = CheckAnswer.execute(%{question_id: request.id}, frame())

    refute response.isError
    assert text(response) =~ "S3"
  end

  test "an unanswered question reports pending rather than failing", %{user_id: user_id} do
    {:ok, request} =
      Notifications.create_question_request(user_id, %{
        "title" => "Claude has a message",
        "questions" => [%{"question" => "Which storage backend?"}]
      })

    {:reply, response, _} = CheckAnswer.execute(%{question_id: request.id}, frame())

    refute response.isError,
           "pending is an ordinary result — an agent that reads it as an error " <>
             "either re-asks, queueing a duplicate for the user, or gives up"

    assert text(response) =~ "Still waiting"
  end
end
