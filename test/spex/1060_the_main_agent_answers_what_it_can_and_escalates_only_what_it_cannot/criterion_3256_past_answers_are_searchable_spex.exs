defmodule CodeMySpecSpex.Story1060.Criterion3256Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 3256 — Past answers are searchable.

  Rule: what the user has already decided is part of what the project records.

  The capability 3257 and 3258 are both about using. It is separate from them
  because it fails on its own and earlier: a main agent that cannot look at what
  the user has answered before cannot avoid asking twice, cannot recognise a
  precedent, and cannot tell a fitting one from a stretched one — three
  criteria, one missing reading.

  The questions are already stored. What is missing is a way to ask about them:
  `list_open_questions` is by definition the ones nobody has answered, and
  `check_answer` needs an id the main agent would only have if it already knew
  which earlier question mattered.

  ## Answered, and by text

  Both halves are the point. Open questions are the wrong set — a precedent is
  by definition settled — and searching by the question's words is what makes it
  usable at all: the main agent has a new question's text and nothing else to
  match on.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.SearchAnswers
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "What the user decided before can be looked up" do
    scenario "the user has answered questions in the past" do
      given_ "two questions the user has answered and one still open", context do
        reply = join_working_copy(context, "/tmp/spex-3256", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        settled =
          Fixtures.ask_question(scope.user.id,
            title: "a decision the user made",
            questions: [
              %{
                "question" => "Should deleting a customer delete their invoices?",
                "options" => [%{"label" => "Keep"}, %{"label" => "Delete"}]
              }
            ]
          )

        :ok = Fixtures.answer_question(scope, settled, "Keep")

        unrelated =
          Fixtures.ask_question(scope.user.id,
            title: "another decision",
            questions: [
              %{
                "question" => "Should exports be CSV or JSON?",
                "options" => [%{"label" => "CSV"}, %{"label" => "JSON"}]
              }
            ]
          )

        :ok = Fixtures.answer_question(scope, unrelated, "CSV")

        _open =
          Fixtures.ask_question(scope.user.id,
            title: "not yet decided",
            questions: [
              %{
                "question" => "Should deleting a customer notify them?",
                "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
              }
            ]
          )

        {:ok, Map.put(context, :scope, scope)}
      end

      when_ "the main agent searches those earlier questions", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SearchAnswers.execute(%{query: "deleting a customer"}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :results, response_text(response))}
      end

      then_ "it finds the matching answered question and what was decided",
            context do
        assert context.results =~ "Should deleting a customer delete their invoices?",
               """
               The main agent cannot look at what the user has already decided.

               Three criteria rest on this one reading: it cannot avoid asking
               twice (3257), cannot recognise a precedent, and cannot tell a
               fitting one from a stretched one (3258).

               results:
               #{context.results}
               """

        assert context.results =~ "Keep",
               """
               The earlier question is found and what the user decided is not.

               A precedent is the decision, not the question — finding the
               question alone leaves the main agent knowing it has been asked
               before and nothing about how it was settled.

               results:
               #{context.results}
               """

        {:ok, context}
      end

      then_ "and it does not return questions nobody has answered", context do
        refute context.results =~ "Should deleting a customer notify them?",
               """
               An unanswered question came back from a search for precedent.

               A precedent is by definition settled. An open question matching
               the same words is the *opposite* — evidence that this has been
               asked and not decided — and treating it as precedent would answer
               a new question from a question.

               results:
               #{context.results}
               """

        {:ok, context}
      end
    end
  end
end
