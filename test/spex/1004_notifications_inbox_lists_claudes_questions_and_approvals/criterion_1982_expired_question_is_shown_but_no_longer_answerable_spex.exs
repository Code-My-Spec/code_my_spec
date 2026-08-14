defmodule CodeMySpecSpex.Story1004.Criterion1982Spex do
  @moduledoc """
  Story 1004 — Notifications inbox lists Claude's questions and approvals.
  Criterion 1982 — Expired question is shown but no longer answerable.

  An agent that stopped waiting cannot be answered. Dropping the question
  from the list would be the tidy move and the wrong one: the user gets a
  push, opens the inbox, and finds nothing — which reads as a bug in the
  inbox rather than as a question that timed out.

  So it stays, saying it expired, with no way to submit. Both halves matter
  and fail separately — a form that still submits into a run nobody is
  waiting on takes an answer and does nothing with it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A question that timed out says so rather than vanishing" do
    scenario "Expired question is shown but no longer answerable" do
      given_ "a question the user was pushed about", context do
        id =
          Fixtures.ask_question(context.scope.user.id,
            title: "Which storage backend?",
            questions: [%{"question" => "Which storage backend?", "options" => [%{"label" => "S3"}, %{"label" => "Disk"}]}]
          )

        {:ok, Map.put(context, :question_id, id)}
      end

      when_ "the run stops waiting and the question expires", context do
        :ok = Fixtures.expire_question(context.question_id)

        {:ok, context}
      end

      then_ "it is still listed, marked expired", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(
                 view,
                 "[data-test='notification'][data-id='#{context.question_id}'][data-status='expired']"
               ),
               "a push followed by an empty inbox reads as the inbox being broken"

        {:ok, Map.put(context, :view, view)}
      end

      then_ "it can no longer be answered", context do
        {:ok, answer_view, _html} =
          live(context.conn, "/app/questions/#{context.question_id}")

        refute has_element?(answer_view, "form button[type='submit']"),
               "a form that submits into a run nobody is waiting on takes an answer and " <>
                 "does nothing with it"

        {:ok, context}
      end
    end
  end
end
