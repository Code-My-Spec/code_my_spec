defmodule CodeMySpec.Notifications.QuestionRequestTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Notifications
  alias CodeMySpec.Notifications.QuestionRequest

  import CodeMySpec.UsersFixtures

  setup do
    scope = user_scope_fixture()
    %{user_id: scope.user.id}
  end

  defp questions do
    [
      %{
        "question" => "Which database?",
        "header" => "DB",
        "multiSelect" => false,
        "options" => [
          %{"label" => "Postgres", "description" => "relational"},
          %{"label" => "SQLite", "description" => "embedded"}
        ]
      }
    ]
  end

  describe "create_question_request/2" do
    test "creates a pending request with the questions", %{user_id: user_id} do
      assert {:ok, %QuestionRequest{} = req} =
               Notifications.create_question_request(user_id, %{
                 "title" => "Pick a DB",
                 "questions" => questions()
               })

      assert req.status == "pending"
      assert req.user_id == user_id
      assert [%{"question" => "Which database?"}] = req.questions
      assert req.answers == %{}
    end

    test "requires at least one question", %{user_id: user_id} do
      assert {:error, changeset} =
               Notifications.create_question_request(user_id, %{"questions" => []})

      assert %{questions: [_ | _]} = errors_on(changeset)
    end
  end

  describe "answer_question_request/2" do
    test "records the answer and broadcasts it", %{user_id: user_id} do
      {:ok, req} = Notifications.create_question_request(user_id, %{"questions" => questions()})
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "question_request:#{req.id}")

      answers = %{"Which database?" => "Postgres"}
      assert {:ok, answered} = Notifications.answer_question_request(req.id, answers)
      assert answered.status == "answered"
      assert answered.answers == answers

      assert_receive {:question_answered, %{id: id, answers: ^answers}}
      assert id == req.id
    end

    test "rejects answering an already-answered request", %{user_id: user_id} do
      {:ok, req} = Notifications.create_question_request(user_id, %{"questions" => questions()})
      {:ok, _} = Notifications.answer_question_request(req.id, %{"Which database?" => "SQLite"})

      assert {:error, {:already_resolved, "answered"}} =
               Notifications.answer_question_request(req.id, %{"Which database?" => "Postgres"})
    end

    test "returns not_found for a missing request" do
      assert {:error, :not_found} =
               Notifications.answer_question_request(Ecto.UUID.generate(), %{"x" => "y"})
    end
  end
end
