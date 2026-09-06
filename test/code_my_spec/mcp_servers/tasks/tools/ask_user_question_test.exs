defmodule CodeMySpec.McpServers.Tasks.Tools.AskUserQuestionTest do
  @moduledoc """
  The structured question an agent asks.

  Everything downstream of it was already built — `ChatComponents.question/1`
  renders the options, `collect_answers/2` resolves the choice — so what this
  covers is the way in: that the payload it writes is the shape the renderer
  reads, and that what the caller said survives the trip.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion

  setup do
    {:ok, scope: full_scope_fixture()}
  end

  defp frame(scope), do: %Anubis.Server.Frame{assigns: %{current_scope: scope}}

  defp a_question(opts \\ []) do
    %{
      "question" => Keyword.get(opts, :question, "Which visual tone?"),
      "header" => Keyword.get(opts, :header, "Theme"),
      "options" => [
        %{"label" => "Warm parchment", "description" => "A grounded medieval feel."},
        %{"label" => "Cool slate", "description" => "A restrained, tactical feel."}
      ]
    }
  end

  # Straight off the table: this is about what was written, and going through a
  # listing would test the listing's filters as well.
  defp latest(_scope) do
    import Ecto.Query

    CodeMySpec.Notifications.QuestionRequest
    |> order_by([q], desc: q.inserted_at)
    |> limit(1)
    |> CodeMySpec.Repo.one()
  end

  test "the caller's title is what the person sees", %{scope: scope} do
    {:reply, response, _} =
      AskUserQuestion.execute(
        %{questions: [a_question()], title: "Capital vassalization rule"},
        frame(scope)
      )

    refute response.isError

    # It read the title off `frame.assigns`, where it never was — it arrives in
    # the params. Every question the agents asked was headed "Claude has a
    # question" while the agent had written something useful.
    assert latest(scope).title == "Capital vassalization rule"
  end

  test "no title falls back to something rather than nothing", %{scope: scope} do
    {:reply, _response, _} = AskUserQuestion.execute(%{questions: [a_question()]}, frame(scope))

    assert latest(scope).title == "Claude has a question"
  end

  test "the options survive in the shape the renderer reads", %{scope: scope} do
    {:reply, _response, _} = AskUserQuestion.execute(%{questions: [a_question()]}, frame(scope))

    assert [question] = latest(scope).questions
    assert question["question"] == "Which visual tone?"
    assert question["header"] == "Theme"
    assert question["multiSelect"] == false

    assert [%{"label" => "Warm parchment", "description" => _}, %{"label" => "Cool slate"} | _] =
             question["options"]
  end

  # A question with no options renders as a textarea, which is `send_message`.
  # An agent that meant to offer choices should hear that it did not, rather
  # than get a paragraph back and wonder why.
  test "a question with no options is refused, and says what to call instead", %{scope: scope} do
    {:reply, response, _} =
      AskUserQuestion.execute(
        %{questions: [%{"question" => "Thoughts?", "options" => []}]},
        frame(scope)
      )

    assert response.isError
    body = Enum.map_join(response.content, "\n", &Map.get(&1, "text", ""))
    assert body =~ "send_message"
  end

  # Four is what a person is shown at once. Refused rather than truncated:
  # dropping the fifth silently means the agent waits on an answer to something
  # nobody was ever shown.
  test "more questions than a person is shown is refused", %{scope: scope} do
    {:reply, response, _} =
      AskUserQuestion.execute(%{questions: List.duplicate(a_question(), 5)}, frame(scope))

    assert response.isError
  end
end
