defmodule CodeMySpecSpex.Story1004.Criterion1977Spex do
  @moduledoc """
  Story 1004 — Notifications inbox lists Claude's questions and approvals.
  Criterion 1977 — Question missed by push still appears in the inbox.

  The inbox exists because Web Push is best-effort. A browser that was closed,
  a permission never granted, a service worker evicted — each loses the
  notification silently, and an agent blocked on `ask_user` waits on an answer
  the user was never shown.

  So listing cannot depend on delivery. This drives the page with no push
  subscription registered at all, which is the strongest form of "the push
  never arrived": there was nowhere to send it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "The inbox is the fallback when a push notification never lands" do
    scenario "Question missed by push still appears in the inbox" do
      given_ "the user has no push subscription, so nothing can be delivered", context do
        # given: already true — `register_log_in_setup_account` creates a user
        # and nothing subscribes them to Web Push. Registering one would be the
        # work; leaving it unregistered is the condition, and it is the
        # strongest form of "the push never arrived" because there was nowhere
        # to send it.
        {:ok, context}
      end

      when_ "an agent asks a question", context do
        id =
          Fixtures.ask_question(context.scope.user.id,
            title: "Which storage backend?",
            questions: [
              %{
                "question" => "Which storage backend?",
                "options" => [%{"label" => "S3"}, %{"label" => "Disk"}]
              }
            ]
          )

        {:ok, Map.put(context, :question_id, id)}
      end

      then_ "it is listed as pending in the notifications inbox", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(
                 view,
                 "[data-test='notification'][data-id='#{context.question_id}'][data-status='pending']"
               ),
               "a question the push never reached has nowhere else to be found"

        {:ok, Map.put(context, :view, view)}
      end

      then_ "it can be opened and answered", context do
        assert has_element?(
                 context.view,
                 "[data-test='notification'][data-id='#{context.question_id}'] a[href]"
               ),
               "listing a question the user cannot open leaves them as stuck as no listing"

        {:ok, answer_view, _html} =
          live(context.conn, "/app/questions/#{context.question_id}")

        answer_view
        |> form("form", %{"q_0" => "S3"})
        |> render_submit()

        {:ok, list_view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(
                 list_view,
                 "[data-test='notification'][data-id='#{context.question_id}'][data-status='answered']"
               ),
               "the answer has to reach the record, or the agent is still waiting"

        {:ok, context}
      end
    end
  end
end
