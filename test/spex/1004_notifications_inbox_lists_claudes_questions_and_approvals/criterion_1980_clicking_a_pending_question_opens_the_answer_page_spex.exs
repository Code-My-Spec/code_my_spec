defmodule CodeMySpecSpex.Story1004.Criterion1980Spex do
  @moduledoc """
  Story 1004 — Notifications inbox lists Claude's questions and approvals.
  Criterion 1980 — Clicking a pending question opens the answer page.

  A list of things needing an answer is only useful if each one leads to
  where it can be answered. The round trip is the criterion: click through,
  answer, and find the item resolved back in the list. Any of those three
  can be built and still leave the user stuck.

  This is the case where the question was asked outside a harness — no
  session to return to — so the question's own page is the context. The
  rule's other half, a question asked by an agent leading to the conversation
  it was asked in, has no scenario yet.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A listed question leads to where it can be answered" do
    scenario "Clicking a pending question opens the answer page" do
      given_ "a pending question is listed in the inbox", context do
        id =
          Fixtures.ask_question(context.scope.user.id,
            title: "Which storage backend?",
            questions: [%{"question" => "Which storage backend?", "options" => [%{"label" => "S3"}, %{"label" => "Disk"}]}]
          )

        {:ok, Map.put(context, :question_id, id)}
      end

      when_ "the user clicks it", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        {:ok, answer_view, _html} =
          view
          |> element("[data-test='notification'][data-id='#{context.question_id}'] a")
          |> render_click()
          |> follow_redirect(context.conn)

        {:ok, Map.put(context, :answer_view, answer_view)}
      end

      then_ "they land on the question's answer page", context do
        assert has_element?(context.answer_view, "form"),
               "landing somewhere that cannot take the answer is the same as not landing"

        assert render(context.answer_view) =~ "Which storage backend?",
               "the page has to show which question is being answered"

        {:ok, context}
      end

      then_ "submitting their answer resolves the item in the inbox", context do
        context.answer_view
        |> form("form", %{"q_0" => "S3"})
        |> render_submit()

        {:ok, list_view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(
                 list_view,
                 "[data-test='notification'][data-id='#{context.question_id}'][data-status='answered']"
               ),
               "an answered question still listed as pending sends the user back to answer " <>
                 "it again"

        {:ok, context}
      end
    end
  end
end
