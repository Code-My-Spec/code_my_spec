defmodule CodeMySpecSpex.Story1004.Criterion1982Spex do
  @moduledoc """
  Story 1004 — Notifications inbox lists Claude's questions and approvals.
  Criterion 1982 — An already-answered question is shown but no longer answerable.

  A settled question stays in the inbox, saying it is settled, with no way to
  submit. Both halves matter and fail separately: dropping it would be the tidy
  move and the wrong one — the user gets a push, opens the inbox, finds nothing,
  and reads that as the inbox being broken — while a form that still submits
  takes a second answer and does nothing with it.

  ## This criterion used to be about expiry, and that was unbuildable

  It read "Expired question is shown but no longer answerable", and this spec
  drove `Fixtures.expire_question/1` to reach that state. Nothing in production
  could: `expired` was a legal status with two readers — `QuestionClient.poll/3`
  and `CheckAnswer` — and no writer anywhere. Only the fixtures manufactured it.

  Story 896's Three Amigos then decided deliberately against building the expiry
  that would have made it reachable: a question vanishing on a clock is a
  decision the user never made disappearing from the one place they would have
  seen it. Answering is the only terminal state, and in use it is enough —
  questions answered through the UI leave `list_user_questions` immediately.

  So the criterion was rewritten to a state the system actually reaches
  (`83309b2a`), and this spec was left behind asserting the old one — the same
  defect I had filed against story 894 that morning, committed by me the same
  day. The filename changed with it; the old one said "expired" and would have
  gone on saying it.

  ## Surface

  The answer is submitted through `QuestionLive.Show` — a real host, and
  "somewhere other than the inbox", which is the Given. The inbox is then read
  as the user would find it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A settled question says so rather than vanishing" do
    scenario "An already-answered question is shown but no longer answerable" do
      given_ "a question the user was pushed about", context do
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

      when_ "they answer it on the question's own page", context do
        {:ok, view, _html} = live(context.conn, "/app/questions/#{context.question_id}")

        view
        |> form("[data-test='question-form']", %{"q_0" => "S3"})
        |> render_submit()

        {:ok, context}
      end

      then_ "it is still listed, marked answered", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(
                 view,
                 "[data-test='notification'][data-id='#{context.question_id}'][data-status='answered']"
               ),
               "a push followed by an empty inbox reads as the inbox being broken"

        {:ok, Map.put(context, :view, view)}
      end

      then_ "it can no longer be answered", context do
        {:ok, answer_view, _html} =
          live(context.conn, "/app/questions/#{context.question_id}")

        refute has_element?(answer_view, "[data-test='question-form']"),
               "a form that takes a second answer to a settled question does " <>
                 "nothing with it"

        {:ok, Map.put(context, :answer_view, answer_view)}
      end

      then_ "its own page shows what was asked and what was said", context do
        # The criterion's first clause. Browser QA of the expiry version found
        # the page rendering its title and nothing else — no question, no
        # status, no reason there was nothing to do. "No submit button" is
        # satisfied by a blank page, so the refute above cannot see that.
        assert has_element?(context.answer_view, "[data-test='question-answered']"),
               "a page that only shows the title reads as broken, not as settled"

        rendered = render(context.answer_view)

        assert rendered =~ "Which storage backend?",
               "what was asked is the point of keeping the record at all"

        assert rendered =~ "S3",
               "and what was answered is what the user came back to check"

        {:ok, context}
      end
    end
  end
end
