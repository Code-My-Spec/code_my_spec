defmodule CodeMySpec.Notifications.AnEmptyAnswerIsNotAnAnswerTest do
  @moduledoc """
  A submission that says nothing must not replace an answer that says
  something.

  Found by QA on story 1009, 2026-09-20. The question form renders one radio
  per option plus a radio for "Other..." paired with a text input. Type a
  correction into that box without also clicking its radio, press Send, and
  the page said "Answer sent" while the stored answer became `""` — `overruled`
  true, `answered_by` "user", and a correct, record-backed main-agent answer no
  longer the current value. `check_answer` then handed the asking agent "The
  user replied, overruling the main agent's earlier answer:" followed by
  nothing.

  Two things were wrong and both are fixed here: text typed with no radio
  checked is a choice rather than a blank, and a submission where *everything*
  is blank is refused outright.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Notifications

  defp ask(scope, text) do
    {:ok, request} =
      Notifications.create_question_request(scope.user.id, %{
        "title" => "Claude has a question",
        "questions" => [
          %{
            "question" => text,
            "header" => nil,
            "multiSelect" => false,
            "options" => [%{"label" => "Allow"}, %{"label" => "Refuse"}]
          }
        ]
      })

    request
  end

  describe "collect_answers/2" do
    test "text typed into Other with no radio checked is that text" do
      questions = [%{"question" => "Which one?"}]

      assert Notifications.collect_answers(questions, %{"q_0_other" => "a third thing"}) ==
               %{"Which one?" => "a third thing"}
    end

    test "a checked radio still wins over stale text in the Other box" do
      questions = [%{"question" => "Which one?"}]

      assert Notifications.collect_answers(questions, %{
               "q_0" => "Allow",
               "q_0_other" => "leftover typing"
             }) == %{"Which one?" => "Allow"}
    end

    test "nothing chosen and nothing typed is blank" do
      questions = [%{"question" => "Which one?"}]

      assert Notifications.collect_answers(questions, %{}) == %{"Which one?" => ""}
    end
  end

  describe "answer_question_request/3" do
    setup do
      %{scope: full_scope_fixture()}
    end

    test "refuses a submission where every answer is blank", %{scope: scope} do
      request = ask(scope, "Which one?")

      assert {:error, :empty_answer} =
               Notifications.answer_question_request(request.id, %{"Which one?" => ""})

      assert %{status: "pending", answers: %{}} =
               Notifications.get_question_request(request.id)
    end

    test "refuses whitespace, which is the same nothing with a space in it", %{scope: scope} do
      request = ask(scope, "Which one?")

      assert {:error, :empty_answer} =
               Notifications.answer_question_request(request.id, %{"Which one?" => "   "})
    end

    test "a blank override does not erase the answer it would have replaced", %{scope: scope} do
      request = ask(scope, "Should refunds over ninety days be allowed?")

      {:ok, _} =
        Notifications.answer_question_request(
          request.id,
          %{"Should refunds over ninety days be allowed?" => "Refuse, per the ledger policy"},
          answered_by: "main_agent"
        )

      assert {:error, :empty_answer} =
               Notifications.answer_question_request(request.id, %{
                 "Should refunds over ninety days be allowed?" => ""
               })

      kept = Notifications.get_question_request(request.id)

      assert kept.answers["Should refunds over ninety days be allowed?"] ==
               "Refuse, per the ledger policy",
             "a submission that said nothing replaced an answer that said something"

      assert kept.answered_by == "main_agent"
      refute kept.overruled
    end

    test "one blank beside one answered is a partial reply, which is allowed", %{scope: scope} do
      {:ok, request} =
        Notifications.create_question_request(scope.user.id, %{
          "title" => "Claude has questions",
          "questions" => [
            %{"question" => "First?", "header" => nil, "multiSelect" => false, "options" => []},
            %{"question" => "Second?", "header" => nil, "multiSelect" => false, "options" => []}
          ]
        })

      assert {:ok, _} =
               Notifications.answer_question_request(request.id, %{
                 "First?" => "yes",
                 "Second?" => ""
               })
    end
  end
end
